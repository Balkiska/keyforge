# Key Forge

A **script** shell to create, open and close a secure encrypted environment, automatically manage GPG keys and pre-configure your SSH access.

## Objectives

1. **Create an encrypted** LUKS volume in ext4 format
2. **Automated management of GPG keys** (generation, import/export)
3. **SSH** configuration template and aliases for simplified connection
4. **Import of existing SSH configurations and keys**.
5. **Permission management** on the safe and its contents
6. **Simple interface** :
    - `install`: environment initialization (LUKS creation/formatting, mounting, GPG pair generation)
    - open": mount (open) the encrypted safe
    - close: unmount and lock the vault
    - `status`: display current status (mounted or not, mount point, LUKS info)
    - `gen-gpg`: generate a new GPG key pair in the vault
    - gpg-export`: export your GPG keys to the vault
    - `gpg-import`: import your GPG keys from the vault
    - `setup-ssh`: prepare the SSH configuration template and create the `evsh` alias
    - `import-ssh`: import a section of your existing `~/.ssh/config` into the SSH template
    - quit`: exit the menu

---

## Prerequisites

- GNU/Linux (Debian/Ubuntu recommended)
- `bash`
- To be a sudoer

---

## Installation

 **Run or copy** `s_menu2.sh` 
 Make executable:
 ```bash
 chmod +x ~/bin/script.sh
 ```
 Use script: 
 ```bash
 ./script.sh
 ````

---

## 📄 License

Creative Commons Zero v1.0 Universal
