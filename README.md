# Pair B - Automated Infrastructure Pipeline (Manual Runbook)

This repository contains the Infrastructure as Code (IaC) pipeline for **Pair B**, which automates the provisioning, creation, and security hardening of AlmaLinux 10 virtual machines.

While this repository is fully automated via the `Jenkinsfile`, this guide provides step-by-step instructions on how to run the pipeline manually from your terminal for learning, testing, and debugging purposes.

*(Note: For conceptual explanations, architectural decisions, and key takeaways, please read the `packer-info.md` study guide).*

## Prerequisites
Ensure your hypervisor is clean before starting. If you have orphaned volumes from previous runs, clean them up:
```bash
virsh pool-destroy pool_b
virsh pool-undefine pool_b
```

## Phase 1: Packer (The Golden Image)
Packer will download the AlmaLinux ISO, boot it, and use our `kickstart.cfg` to format the LVM partitions and install the base OS.

```bash
cd packer/
packer init .
# We use -force to overwrite any existing output directory
packer build -force almalinux.pkr.hcl
```
*Expected Result:* A `golden_image.qcow2` file will be generated inside `packer/output/`.

## Phase 2: Terraform (The Infrastructure)
Terraform will take the golden image, copy it into a libvirt storage pool, spin up 2 VMs with 2 additional data disks each, and dynamically generate our Ansible inventory.

```bash
cd ../terraform/
terraform init
terraform apply -auto-approve
```
*Expected Result:* Two running VMs (`virsh list --all`) and a dynamically generated inventory file at `ansible/inventory/hosts` containing the VMs' new IP addresses.

## Phase 3: Ansible (The CIS Hardening)
Ansible will SSH into the running VMs and apply the strict Center for Internet Security (CIS) Level 1 rules, tailoring them to Pair B's specific constraints.

```bash
cd ../ansible/

# 1. Download the RHEL10-CIS hardening role
ansible-galaxy install -r requirements.yml

# 2. Setup the vault password (mock password used: vaultpass123)
echo "vaultpass123" > vaultpass.txt

# 3. Run the playbook, overriding password aging to 30 days, and strictly enforcing Level 1
ansible-playbook playbook.yml --vault-password-file vaultpass.txt -e "rhel10cis_pass_max_days=30" --skip-tags "level2-server,level2-workstation"

# 4. Clean up the password file
rm vaultpass.txt
```
*Expected Result:* The Ansible playbook will execute successfully, leaving the VMs fully hardened. A Goss audit will run at the end, outputting a JSON compliance report.
