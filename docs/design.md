# Pair B - Official Infrastructure Documentation

This document serves as the definitive engineering guide for the Pair B infrastructure pipeline. It details exactly **What** we built, **Why** we built it that way (theory and justifications), and the exact **Commands/Code** used.

## 1. Packer & Kickstart (The Golden Image)

### The Partition Layout (Kickstart)
*   **What we did:** We strictly defined a custom LVM volume group (`vg_sys_b`) during the OS installation and separated critical directories into isolated logical volumes.
*   **Why we did it (Justification):** 
    *   `/var/log` and `/var/log/audit`: Separated to prevent log exhaustion. If a service spams logs or the server suffers a DDoS attack, the logs will only fill up their isolated 2GB partition rather than consuming the entire root OS drive, preventing a catastrophic system crash.
    *   `/var/tmp` and `/srv`: Placed on separate logical volumes so they can later be secured via Ansible (mounted with `nodev`, `nosuid`, `noexec` flags to prevent hackers from executing scripts uploaded to temporary directories).
*   **Code Implementation:**
    ```text
    volgroup vg_sys_b pv.01
    logvol /var/log --vgname=vg_sys_b --size=2048 --name=lv_var_log
    logvol /var/tmp --vgname=vg_sys_b --size=1024 --name=lv_var_tmp
    ```

### Headless CPU Emulation (Packer)
*   **What we did:** We forced the QEMU builder to pass the host CPU to the VM and run silently in the background.
*   **Why we did it (Justification):** AlmaLinux 10 is a modern kernel that panics if booted on QEMU's generic legacy CPU emulator; it requires `-cpu host`. Additionally, because Jenkins is a background service with no desktop interface, Packer will instantly crash if it tries to open a graphical installation window. `headless = true` solves this.
*   **Code Implementation:**
    ```hcl
    qemuargs = [["-cpu", "host"]]
    headless = true
    ```
*   **Execution Command:**
    ```bash
    packer build -force almalinux.pkr.hcl
    ```

## 2. Terraform (Dynamic Provisioning)

### Physical Storage Emulation
*   **What we did:** We provisioned two virtual machines, each with an OS disk (cloned from Packer) and two 2GB data disks attached via the `scsi` bus.
*   **Why we did it (Justification):** We explicitly used `scsi` because of our assignment constraints. By overriding the KVM default (`virtio`), the hypervisor emulates an old-school physical hardware controller. This causes the extra disks to show up inside the Linux VM as traditional `/dev/sda` and `/dev/sdb` drives instead of virtual `/dev/vda` drives, proving we can customize hypervisor hardware layers.
*   **Code Implementation:**
    ```terraform
    resource "libvirt_volume" "data_disk_1" {
      name   = "pb-node-1-data1.qcow2"
      size   = 2 * 1024 * 1024 * 1024 # 2GB
    }
    ```

### Passwordless SSH (Cloud-Init)
*   **What we did:** We used `libvirt_cloudinit_disk` to inject a dynamically generated ED25519 SSH private key into the `root` user during first boot.
*   **Why we did it (Justification):** Automated pipelines cannot interactively type passwords. By injecting the SSH public key into the VM's `authorized_keys` file before it even boots, Ansible can instantly connect to the newly spawned IPs securely.
*   **Code Implementation:**
    ```terraform
    ssh_pwauth: false
    users:
      - name: root
        ssh_authorized_keys:
          - ${tls_private_key.ssh_key.public_key_openssh}
    ```
*   **Execution Command:**
    ```bash
    terraform apply -auto-approve
    ```

## 3. Ansible & CIS Hardening (The Security Layer)

### Ansible Vault (Password Encryption)
*   **What we did:** We encrypted a file containing the highly secure root/GRUB password required by the CIS benchmarks.
*   **Why we did it (Justification):** Pushing a plaintext password (like `rhel10cis_root_password: "SuperSecret"`) directly into a Git repository is a massive security violation. We used `ansible-vault` to scramble the file into unreadable AES256 gibberish, allowing us to safely commit it to GitHub. Ansible seamlessly decrypts it in memory using a master password file during the run.
*   **Execution Command:**
    ```bash
    echo "vaultpass123" > vaultpass.txt
    ansible-vault encrypt group_vars/vault.yml --vault-password-file vaultpass.txt
    ```

### 3-Tier Variable Precedence & CIS Overrides
*   **What we did:** We dynamically overrode the default settings of the open-source CIS hardening script.
*   **Why we did it (Justification):** We used three distinct levels of precedence to prove mastery of Ansible configuration management:
    1.  **Lowest Precedence (`group_vars/all.yml`):** Universal settings. We explicitly disabled rule `1.2.1.1` (GPG Keys) here because our offline Kickstart build never imported internet GPG keys. We also set our required custom authselect profile here.
    2.  **Medium Precedence (`playbook.yml` vars block):** Play-specific settings. We disabled the `5.3.2.1.x` account lockout rules here so the CIS script wouldn't accidentally lock out our root user and break the pipeline.
    3.  **Highest Precedence (Command Line `-e` flag):** Runtime overrides. We injected `rhel10cis_pass_max_days=30` directly via CLI to force maximum password expiration priority.

### Target Validation (The 92.8% Compliance Score)
*   **What we did:** We audited the VMs using the Goss testing framework.
*   **Why we did it (Justification):** Goss physically inspects the Linux kernel parameters, file permissions, and running services. Out of 711 CIS enterprise security checks, our raw AlmaLinux image failed 236. After Ansible applied our overrides and hardening rules, the failures plummeted to just 51 (mostly Level 2 rules we intentionally skipped).
    *   **Math:** 660 passed / 711 total = **92.82%**
    *   This successfully beats the strict **90% compliance target** assigned to Pair B.
*   **Execution Command:**
    ```bash
    ansible-playbook playbook.yml --vault-password-file vaultpass.txt -e "rhel10cis_pass_max_days=30" --skip-tags "level2-server,level2-workstation"
    ```

## 4. Lab Cleanup & Reset (Nuke Commands)

In immutable infrastructure, if a VM breaks or you lock yourself out, you do not fix the VM—you destroy it and deploy a fresh one. 

Run the following commands on your host laptop to completely nuke the environment and reset Terraform's memory to a blank slate:

```bash
# 1. Force turn off (destroy) and delete the VMs from the hypervisor
virsh destroy pb-node-1
virsh undefine pb-node-1
virsh destroy pb-node-2
virsh undefine pb-node-2

# 2. (Optional) Manually delete the volumes using pure Virsh commands
# If you prefer not to use 'rm -rf', you must manually delete every volume before deleting the pool.
# virsh vol-delete --pool pool_b pb-node-1-os.qcow2
# virsh vol-delete --pool pool_b pb-node-2-os.qcow2
# (Repeat for all data disks and commoninit ISOs)

# 3. Stop and undefine the Virsh storage pool
# Note: 'pool-delete' will fail if the directory is not empty, which is why we use 'undefine' + 'rm -rf'
virsh pool-destroy pool_b
virsh pool-undefine pool_b

# 4. Delete the physical leftover files on the host disk (The fastest method)
sudo rm -rf /var/lib/libvirt/images/pool_b

# 5. Wipe Terraform's memory of the old infrastructure
cd ~/pipeline-pair-b/terraform
rm terraform.tfstate terraform.tfstate.backup

# 4. (Optional) Re-deploy perfectly clean VMs
terraform apply -auto-approve
```
