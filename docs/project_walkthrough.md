# Pair B Pipeline - Complete Step-by-Step Walkthrough

This document serves as a comprehensive history of the Pair B project, detailing every step taken from the initial repository setup to the final Jenkins orchestration, including all code, commands, and the bugs encountered along the way.

---

## Phase 1: Environment Setup
We started by establishing the project repository and folder structure. We needed isolated directories for each tool to ensure a clean separation of concerns.

**Commands Used:**
```bash
git clone https://github.com/bunnywkwk/pipeline-pair-b.git
cd pipeline-pair-b
mkdir packer terraform ansible docs
```

---

## Phase 2: Packer & Kickstart (The Golden Image)
Our goal was to dynamically build an AlmaLinux 10 KVM image. We used Packer to orchestrate the build and a Kickstart file to strictly define the partition layout to meet security requirements.
V
### 1. The Code
*   **`packer/kickstart.cfg`**: We explicitly defined a Logical Volume Manager (LVM) group named `vg_sys_b` and separated critical directories (`/var`, `/var/log`, `/var/tmp`, `/srv`) into isolated partitions to prevent malicious scripts or log exhaustion from crashing the root OS.
*   **`packer/almalinux.pkr.hcl`**: We configured the QEMU builder to download the AlmaLinux ISO, use UEFI boot (`OVMF_CODE.fd`), and utilize CPU passthrough (`-cpu host`).

### 2. Commands Used
```bash
cd packer
packer init .
packer build -force almalinux.pkr.hcl
```

### 3. Bug Encountered (Later in Jenkins)
Initially, we ran Packer manually and watched the QEMU window pop up. However, when we transitioned to Jenkins, Packer crashed instantly. 
*   **The Fix:** Jenkins is a headless background service with no desktop interface. We had to add `headless = true` to `almalinux.pkr.hcl` so QEMU would run silently without attempting to open a GUI window.

---

## Phase 3: Terraform (Infrastructure Provisioning)
We used Terraform with the `dmacvicar/libvirt` provider to dynamically spawn two identical virtual machines using the Golden Image we just built.

### 1. The Code
*   **`terraform/main.tf`**: 
    *   We created a custom Libvirt storage pool (`pool_b`).
    *   We provisioned 2 VMs (`pb-node-1` and `pb-node-2`).
    *   Each VM was attached to **3 Disks**: 1 OS Disk (cloned from Packer) and 2 empty 2GB Data Disks (attached via SCSI).
    *   We used `libvirt_cloudinit_disk` to automatically inject a dynamically generated SSH key (`id_ed25519`) into the `root` user of both VMs.
    *   We dynamically generated an Ansible inventory (`hosts` file) containing the newly assigned IPs.

### 2. Commands Used
```bash
cd terraform
terraform init
terraform apply -auto-approve
```

---

## Phase 4: Ansible (Configuration & Hardening)
With the VMs running, we used Ansible to format the data disks and harden the OS using the CIS (Center for Internet Security) standards.

### 1. Setup & Credentials
Because the CIS script requires root access, we securely encrypted our vault password.
**Commands Used:**
```bash
cd ansible
ansible-galaxy install -r requirements.yml    # Download the CIS role
echo "your_password" > vaultpass.txt          # Create a password file
ansible-vault encrypt group_vars/vault.yml --vault-password-file vaultpass.txt # Encrypt our sensitive variables
```

### 2. The Code
*   **`group_vars/all.yml`**: We set global variables to dictate that we use `journald` for logging and enabled Goss auditing (`setup_audit: true`).
*   **`playbook.yml`**: We wrote the main execution script to format the `/dev/sda` and `/dev/sdb` data disks as `ext4`. We also disabled rule `5.1.20` so the hardening script wouldn't block root SSH access (which would break our pipeline).

### 3. Commands Used
```bash
ansible-playbook playbook.yml --vault-password-file vaultpass.txt -e "rhel10cis_pass_max_days=30" --skip-tags "level2-server,level2-workstation"
```
*   **The Result:** The playbook succeeded, and the Goss audit ran 942 security checks, generating massive JSON reports inside the `/opt/` folder of the VMs proving the hardening was successful.

---

## Phase 5: Jenkins (Orchestration & Edge-Case Bugs)
The final phase was automating the entire process using a parameterized Jenkins pipeline. This is where we encountered the most complex system bugs.

### 1. The Code
*   **`Jenkinsfile`**: We built a Declarative Pipeline with a `choice` parameter allowing us to run `ALL`, `SKIP_PACKER`, `TERRAFORM_ONLY`, or `ANSIBLE_ONLY`. We safely pulled our Ansible vault password from the Jenkins Credential Manager.

### 2. The Bugs & Fixes
*   **Bug 1: Jenkins Permission Denied (KVM)**
    *   *Issue:* Packer failed to start the VM because the `jenkins` user didn't have access to the physical hypervisor.
    *   *Fix:* We ran `sudo usermod -aG kvm jenkins` and `sudo usermod -aG libvirt jenkins` to grant hardware permissions.
*   **Bug 2: Terraform Polkit Error (PID 81439)**
    *   *Issue:* Terraform crashed with `internal error: Cannot find start time for pid`. The Jenkins service didn't have an active Desktop `dbus` session, causing the Linux `Polkit` security layer to panic when Jenkins tried to connect to `qemu:///system`.
    *   *Fix:* We modified `main.tf` to explicitly connect to the raw socket (`uri = "qemu:///system?socket=/var/run/libvirt/libvirt-sock"`), completely bypassing the broken Polkit layer!
*   **Bug 3: Lost Terraform State**
    *   *Issue:* Terraform crashed with `storage pool pool_b already exists`. Jenkins's `cleanWs()` command was aggressively deleting the `terraform.tfstate` memory file at the start of every run. Terraform forgot it created the resources, assumed it was a blank slate, and collided with orphaned files on the hypervisor.
    *   *Fix:* We ran `rm -rf /var/lib/libvirt/images/pool_b/*` to manually wipe the orphaned files, and we updated the Jenkinsfile to exclude state files during cleanup: `cleanWs(deleteDirs: true, patterns: [[pattern: 'terraform/*.tfstate*', type: 'EXCLUDE']])`.

By thoroughly resolving these pipeline bugs, the entire end-to-end architecture is now flawlessly orchestrated by Jenkins!

---

## Phase 6: Post-Deployment Operations (Accessing the VMs)
Now that Jenkins has completely finished provisioning and securing the virtual machines, they are running in the background on your local hypervisor. You can securely SSH into them to poke around and verify the hardening.

### 1. How to SSH into the VMs
Because Jenkins built the infrastructure in an isolated workspace, it dynamically generated the secure SSH key (`id_ed25519`) and placed it inside its own `terraform/` directory.

To access the VMs, open your standard laptop terminal and run:

**For pb-node-1:**
```bash
sudo ssh -i /var/lib/jenkins/workspace/Pair-B-Pipeline/terraform/id_ed25519 sysadmin@192.168.122.74
```

**For pb-node-2:**
```bash
sudo ssh -i /var/lib/jenkins/workspace/Pair-B-Pipeline/terraform/id_ed25519 sysadmin@192.168.122.13
```

*(Note: If the IPs change on your next build, you can check the new IPs by running `virsh net-dhcp-leases default` in your terminal).*

### 2. Why is the command so long?
*   **`sudo`**: The SSH key file was generated by the `jenkins` background service during the automated pipeline run. Because you are logged in as your normal laptop user, you must use `sudo` to gain the permissions necessary to read Jenkins's private key file.
*   **`-i /var/lib/...`**: The `-i` flag stands for "Identity File". Because we are not using a password, this long path tells the SSH client exactly where to find the private key that Jenkins generated so it can cryptographically prove your identity to the VM.
*   **`sysadmin@192.168...`**: You are logging in as the `sysadmin` user. We intentionally use this instead of `root` because the CIS Hardening script strictly prohibits `root` from logging in directly over SSH.
