# Pair B - Automated Infrastructure Pipeline

This repository contains the Infrastructure as Code (IaC) pipeline for **Pair B**, which automates the provisioning, creation, and security hardening of AlmaLinux 10 virtual machines.

## Key Takeaways & Lessons Learned

If you need to revisit this project later, here are the core concepts and fixes we implemented across the pipeline:

### 1. Packer & Kickstart (The Build)
*   **The OS:** We used `AlmaLinux 10`.
*   **UEFI & Kickstart:** Since RHEL 10 mandates UEFI, we had to ensure Packer's QEMU builder booted with UEFI (`machine_type = "q35"` and `efi_boot = true`). The Kickstart file dynamically handles LVM partitioning (putting everything in `vg_sys_b`).
*   **Kernel Panic Bug:** The default QEMU CPU emulation caused a kernel panic in AlmaLinux 10. We fixed this by forcing the host CPU type in Packer: `qemuargs = [["-cpu", "host"]]`.

### 2. Terraform (The Infrastructure)
*   **Dynamic Inventory:** We used the `local_file` resource in Terraform to automatically write the generated IP addresses into `ansible/inventory/hosts`.
*   **Escaping Variables:** *Crucial Lesson:* When writing Terraform templates, you must use a single `$` for interpolation. Using `$$` causes Terraform to literally escape the string instead of evaluating it, which broke our Ansible inventory!
*   **Automated SSH Password:** Since we are using passwords instead of SSH keys for this lab, we injected `ansible_password=Buns123#` directly into the generated inventory via Terraform so Ansible can connect without `--ask-pass`.
*   **Disk Naming:** When attaching additional SCSI data disks to a KVM VM using `libvirt`, they map to `/dev/sda` and `/dev/sdb` (since the virtio OS disk takes `/dev/vda`). 

### 3. Ansible (The Hardening)
*   **Host Key Checking:** Because Terraform spins up VMs with brand new IP addresses, SSH will reject the connection because the Host Keys are unknown. We fixed this by creating `ansible.cfg` and setting `host_key_checking = False`.
*   **Variable Precedence:** We demonstrated three levels of precedence:
    *   *Lowest:* `group_vars/all.yml`
    *   *Medium:* `playbook.yml` vars block
    *   *Highest:* `--extra-vars` via CLI (`-e`)
*   **Authselect Fix:** The RHEL10-CIS role fails if you use the default `cis_example_profile` name. We fixed this by setting `rhel10cis_authselect_custom_profile_name` in our variables.
*   **Ansible Vault:** All sensitive mock passwords were encrypted using `ansible-vault`. (Password used: `vaultpass123`).

## Git Ignore Strategy
We have deliberately excluded the following from version control using `.gitignore`:
*   Terraform state files (`*.tfstate`) - These contain raw secrets and should never be pushed!
*   The generated `ansible/inventory/hosts` file - Because IPs are ephemeral.
*   Packer `output/` directories - Because ISOs and golden images are too large for git.
