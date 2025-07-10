#!/usr/bin/env bash
# created by BKF
# Usage: sudo ./script.sh 
# {init|open|close|status|gpg-gen|gpg-export|gpg-import|ssh-setup|ssh-import}



###############################################################################################################
#                                            verifiyind sudo                                                  #
###############################################################################################################
if [ "$EUID" -ne 0 ]; then
  echo "You are not a sudoer ¯\_(ツ)_/¯, please reconnect as such"
  exec sudo bash "$0" "$@"
fi

# Ensure system binaries are found
export PATH="$PATH:/sbin:/usr/sbin"

###############################################################################################################
#                                          Configurable parameters                                            #
###############################################################################################################

defaults() {
  : "${CONTAINER_PATH:=$HOME/vault.img}"
  : "${CONTAINER_SIZE:=5G}"
  : "${LUKS_NAME:=vault_luks}"
  : "${MOUNT_DIR:=$HOME/vault}"
  GPG_DIR="$MOUNT_DIR/gpg"
  SSH_DIR="$MOUNT_DIR/ssh"
  SSH_ALIAS_FILE="$SSH_DIR/alias.sh"
  BASH_ALIAS_FILE="$HOME/.bash_aliases"
}
defaults

###############################################################################################################
#                                         Cleanup in case of error/exit                                       #
###############################################################################################################

cleanup() {
  # If mounted, dismantle
  if mountpoint -q "$MOUNT_DIR"; then
    umount "$MOUNT_DIR" || true
  fi
  # If open, close LUKS
  if cryptsetup status "$LUKS_NAME" &>/dev/null; then
    cryptsetup close "$LUKS_NAME" || true
  fi
  # Finds the loop device associated with the image and detaches it
  if LOOP=$(losetup -j "$CONTAINER_PATH" | cut -d: -f1); then # -d: indicates to cut that the field delimiter is the colon character :    |    -f1 asks to keep only the first field
    [ -n "$LOOP" ] && losetup -d "$LOOP" # If a loop device has been found, it is released
  fi
}
trap cleanup EXIT

###############################################################################################################
#                                                Functions                                                    #
###############################################################################################################
#LUKS
init_env() { 
  if [ -f "$CONTAINER_PATH" ]; then
    echo "[INIT] The $CONTAINER_PATH file already exists: deleting before recreating"
    rm -f "$CONTAINER_PATH"
  fi

  echo "[INIT] Creating $CONTAINER_SIZE container at $CONTAINER_PATH"
  dd if=/dev/zero of="$CONTAINER_PATH" bs=1 count=0 seek="$CONTAINER_SIZE"
  chown root:root "$CONTAINER_PATH"
  chmod 600 "$CONTAINER_PATH"

  echo "[INIT] Associating loop device"
  LOOP=$(losetup --show -f "$CONTAINER_PATH")

  echo "[INIT] Checking for cryptsetup"
  if ! command -v cryptsetup >/dev/null 2>&1; then
    echo "cryptsetup not found, installing…"
    apt update && apt install -y cryptsetup
    echo "cryptsetup installed ✔"
  fi

  echo "[INIT] Formatting as LUKS (you will be prompted for YES and your passphrase)"
  cryptsetup luksFormat "$LOOP"

  echo "[INIT] Opening encrypted volume"
  cryptsetup open "$LOOP" "$LUKS_NAME"

  echo "[INIT] Creating ext4 filesystem"
  mkfs.ext4 /dev/mapper/"$LUKS_NAME"

  echo "[INIT] Creating and securing directories"
  mkdir -p "$MOUNT_DIR"
  chmod 700 "$MOUNT_DIR"
  mount /dev/mapper/"$LUKS_NAME" "$MOUNT_DIR"
  mkdir -p "$GPG_DIR" "$SSH_DIR"
  chmod 700 "$GPG_DIR" "$SSH_DIR"

  echo "[INIT] Done: vault initialized and unmounted"
}  

open_env() {
  if mountpoint -q "$MOUNT_DIR"; then
    echo "[OPEN] Already mounted on $MOUNT_DIR"
    return
  fi

  echo "[OPEN] Opening $CONTAINER_PATH"
  LOOP=$(losetup --show -f "$CONTAINER_PATH")
  cryptsetup open "$LOOP" "$LUKS_NAME"
  mkdir -p "$MOUNT_DIR"
  mount /dev/mapper/"$LUKS_NAME" "$MOUNT_DIR"
  echo "[OPEN] Vault mounted on $MOUNT_DIR"
}  

close_env() {
  if ! mountpoint -q "$MOUNT_DIR"; then
    echo "[CLOSE] Nothing to unmount"
    return
  fi

  echo "[CLOSE] Unmounting $MOUNT_DIR"
  umount "$MOUNT_DIR"

  echo "[CLOSE] Closing the LUKS mapping"
  cryptsetup close "$LUKS_NAME"

  echo "[CLOSE] Detaching the loop device"
  LOOP=$(losetup -j "$CONTAINER_PATH" | cut -d: -f1)
  losetup -d "$LOOP"
  echo "[CLOSE] Vault closed"
}  

status_env() {
  echo "=== VAULT STATUS ==="
  echo "- Container: $CONTAINER_PATH"
  if cryptsetup status "$LUKS_NAME" &>/dev/null; then
    echo "- LUKS: open (mapping: $LUKS_NAME)"
  else
    echo "- LUKS: closed"
  fi
  if mountpoint -q "$MOUNT_DIR"; then
    echo "- Mount: active on $MOUNT_DIR"
  else
    echo "- Mount: inactive"
  fi
}  

###############################################################################################################
#                                              Cryptography                                                   #
###############################################################################################################
gen_gpg() {
  echo "[GPG-GEN] Generating keys in $GPG_DIR"
  mkdir -p "$GPG_DIR"
  chmod 700 "$GPG_DIR"
  export GNUPGHOME="$GPG_DIR"

  #non-interactive batch generation
  cat > "$GPG_DIR/gen-key-script" <<EOF
Key-Type: default
Subkey-Type: default
Name-Real: $USER forge
Name-Comment: Key Forge
Name-Email: $USER@forge.local
Expire-Date: 0
%no-protection
%commit
EOF

  gpg --batch --pinentry-mode loopback --generate-key "$GPG_DIR/gen-key-script"
  if ! gpg --list-keys >/dev/null 2>&1; then
    echo "[GPG-GEN] Error: no key generated" >&2
    rm -f "$GPG_DIR/gen-key-script"
    return 1
  fi

  # Export into the vault
  gpg --export --armor > "$GPG_DIR/public.key"
  gpg --export-secret-keys --armor > "$GPG_DIR/private.key"
  rm -f "$GPG_DIR/gen-key-script"
  echo "[GPG-GEN] Keys generated and stored"
}

export_gpg() {
  echo "[GPG-EXPORT] Exporting to ~/.gnupg"
  mkdir -p "$HOME/.gnupg"

  # Export each public key
  pub_ids=$(gpg --homedir "$GPG_DIR" --list-keys --with-colons |
            awk -F: '/^pub/ {print $5}')
  [ -z "$pub_ids" ] && {
    echo "[GPG-EXPORT] No public key detected in the vault" >&2
    return 1
  }
  for id in $pub_ids; do
    gpg --homedir "$GPG_DIR" --export --armor "$id" > "$HOME/.gnupg/${id}.pub"
  done

  # Export each private key
  sec_ids=$(gpg --homedir "$GPG_DIR" --list-secret-keys --with-colons |
             awk -F: '/^sec/ {print $5}')
  for id in $sec_ids; do
    gpg --homedir "$GPG_DIR" --export-secret-keys --armor "$id" > "$HOME/.gnupg/${id}.sec"
  done

  chmod 700 "$HOME/.gnupg" && chmod 600 "$HOME/.gnupg/"*
  echo "[GPG-EXPORT] Importing into local keyring"
  gpg --import "$HOME/.gnupg/"*.pub
  gpg --allow-secret-key-import --import "$HOME/.gnupg/"*.sec
  echo "[GPG-EXPORT] Import complete"
}

import_gpg() {
  echo "[GPG-IMPORT] Importing from ~/.gnupg to vault"
  [ -d "$HOME/.gnupg" ] || {
    echo "[GPG-IMPORT] No ~/.gnupg directory" >&2
    return 1
  }

  mkdir -p "$GPG_DIR" && chmod 700 "$GPG_DIR"
  export GNUPGHOME="$GPG_DIR"

  imported=0
  for f in "$HOME/.gnupg/"*.pub "$HOME/.gnupg/"*.sec; do
    [ -f "$f" ] && { gpg --import "$f"; ((imported++)); }
  done

  if [ "$imported" -eq 0 ]; then
    echo "[GPG-IMPORT] No keys to import" >&2
    return 1
  fi
  echo "[GPG-IMPORT] $imported key(s) imported"
}

###############################################################################################################
#                                             Configuration                                                   #
###############################################################################################################
setup_ssh() {
  mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
  key="$SSH_DIR/id_rsa"

  [ -f "$key" ] || ssh-keygen -t rsa -b 4096 -f "$key" -N ""  #generate the pair if it does not exist

  #config file
  cat > "$SSH_DIR/config" <<EOF
Host *
  AddKeysToAgent yes
  IdentityFile $key
  IdentitiesOnly yes
EOF
  # write SSH config alias file for the user and not root 
  chmod 600 "$SSH_DIR/config"
  echo "alias evsh='ssh -F $SSH_DIR/config'" > "$SSH_ALIAS_FILE"
  REAL_USER="${SUDO_USER:-$USER}"
  REAL_HOME=$(eval echo "~$REAL_USER")
  REAL_BASH_ALIASES="$REAL_HOME/.bash_aliases"
  ln -sf "$SSH_ALIAS_FILE" "$REAL_BASH_ALIASES"
  grep -qxF "source $SSH_ALIAS_FILE" "$REAL_HOME/.bashrc" \
    || echo "source $SSH_ALIAS_FILE" >> "$REAL_HOME/.bashrc"
  chown "$REAL_USER":"$REAL_USER" "$SSH_ALIAS_FILE" "$REAL_BASH_ALIASES"
  echo "[SSH-SETUP] OK: keys + config in $SSH_DIR, alias 'evsh' ready"
}

import_ssh() {
  SRC="$HOME/.ssh"
  if [ ! -d "$SRC" ]; then
    echo "[SSH-IMPORT] Error: $SRC not found" >&2
    return 1
  fi

  mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
  cp -r "$SRC/"* "$SSH_DIR"/ 2>/dev/null # Copy all .ssh content
  chmod 600 "$SSH_DIR"/*

  # We use the same config and alias
  ln -sf "$SSH_ALIAS_FILE" "$BASH_ALIAS_FILE"
  grep -qxF "source $SSH_ALIAS_FILE" "$HOME/.bashrc" || echo "source $SSH_ALIAS_FILE" >> "$HOME/.bashrc"
  echo "[SSH-IMPORT] OK: imported all SSH files into $SSH_DIR"
}

###############################################################################################################
#                                         Interactive menu loop                                               #
###############################################################################################################

LIGHT=$'\e[38;2;207;92;120m'
BLACK=$'\e[30m'
RESET=$'\e[0m'

#repeat a character N times
repeat_char() {
  local char="$1" count="$2" result=""
  for ((i=0; i<count; i++)); do
    result+="$char"
  done
  echo "$result"
}

menu_lines=(
  "init        : Creates and initializes the LUKS/ext4 container"
  "open        : Opens and mounts the container"
  "close       : Closes and unmounts the container"
  "status      : Displays the status of the vault"
  "gpg-gen     : Generates a pair of GPG keys in the vault"
  "gpg-export  : Exports and imports your GPG keys to ~/.gnupg"
  "gpg-import  : Imports your existing GPG keys into the vault"
  "ssh-setup   : Creates an SSH template and evsh alias"
  "ssh-import  : Imports a targeted SSH configuration"
  "Quit"
)

while true; do
  #determine the max width of all numbered lines
  max=0
  for i in "${!menu_lines[@]}"; do
    idx=$((i+1))
    [ "$idx" -lt 10 ] && num=" $idx" || num="$idx"
    line="${num}) ${menu_lines[i]}"
    (( ${#line} > max )) && max=${#line}
  done

  border=$(repeat_char '─' "$max") #build the horizontal border of length $max

  #display the box
  echo -e "${LIGHT}┌${border}┐${RESET}"
  title="MENU VAULT MANAGEMENT"
  tlen=${#title}
  pad_tot=$((max - tlen))
  pad_left=$((pad_tot / 2))
  pad_right=$((pad_tot - pad_left))
  left=$(repeat_char ' ' "$pad_left")
  right=$(repeat_char ' ' "$pad_right")
  echo -e "${LIGHT}│${RESET}${BLACK}${left}${title}${right}${RESET}${LIGHT}│${RESET}"
  echo -e "${LIGHT}├${border}┤${RESET}"
  for i in "${!menu_lines[@]}"; do
    idx=$((i+1))
    [ "$idx" -lt 10 ] && num=" $idx" || num="$idx"
    line="${num}) ${menu_lines[i]}"
    pad_len=$((max - ${#line}))
    pad=$(repeat_char ' ' "$pad_len")
    echo -e "${LIGHT}│${RESET}${BLACK}${line}${pad}${RESET}${LIGHT}│${RESET}"
  done
  echo -e "${LIGHT}└${border}┘${RESET}"

  # prompt
  read -rp $'\n'"${BLACK}Select an action: ${RESET}" choice
  case $choice in
    1) init_env   ;;
    2) open_env   ;;
    3) close_env  ;;
    4) status_env ;;
    5) gen_gpg    ;;
    6) export_gpg ;;
    7) import_gpg ;;
    8) setup_ssh  ;;
    9) import_ssh ;;
    10) echo -e "${BLACK}Goodbye!${RESET}" ; exit 0 ;;
    *) echo -e "${BLACK}Invalid option, try again.${RESET}" ;;
  esac

  echo 
done
