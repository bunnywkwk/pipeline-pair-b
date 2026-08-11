# Pair B - Centralized Troubleshooting & Bug Tracker

This document centralizes all bugs, unexpected behaviors, and troubleshooting steps encountered during the development of the Pair B automated infrastructure pipeline. For every issue, we provide the exact code or command used to fix it and a deep justification of *why* it works.

## 1. Packer & Kickstart

### Packer Kernel Panic (AlmaLinux 10)
*   **The Problem:** During the `packer build` phase, AlmaLinux 10 crashed immediately on boot with a kernel panic.
*   **Why we needed to fix it:** The VM could not boot, halting the entire pipeline.
*   **The Fix:** 
    ```hcl
    qemuargs = [["-cpu", "host"]]
    ```
*   **Justification:** The default CPU emulation provided by QEMU is highly generic (to support older machines) and lacks specific modern CPU instructions required by AlmaLinux 10. By injecting `-cpu host`, we force QEMU to pass the physical host's exact CPU architecture and instruction set directly through to the VM, allowing the modern kernel to boot successfully.

### Jenkins Headless Crash
*   **The Problem:** Packer built the image successfully when run manually by a developer, but instantly crashed when triggered via the Jenkins automated pipeline.
*   **Why we needed to fix it:** Jenkins runs as a headless background service with no graphical desktop. 
*   **The Fix:** 
    ```hcl
    headless = true
    ```
*   **Justification:** By default, Packer's QEMU builder attempts to open a visible SDL/VNC graphical window so the developer can watch the OS install. When Jenkins runs, there is no display attached, causing QEMU to crash. Setting `headless = true` forces QEMU to run silently in the background.

## 2. Terraform

### Dynamic Inventory Variable Escaping
*   **The Problem:** Terraform successfully generated the `ansible/inventory/hosts` file, but the variables inside it were literally written as `${...}` instead of their actual evaluated IP values.
*   **Why we needed to fix it:** Ansible needs the actual IP addresses to connect.
*   **The Fix:** 
    ```terraform
    # BAD:
    ansible_host=$${ip_address}
    
    # GOOD:
    ansible_host=${ip_address}
    ```
*   **Justification:** In Terraform's `templatefile()` function, a double dollar sign (`$$`) is the official syntax used to *escape* interpolation. It tells Terraform, "Do not evaluate this variable, just print the literal string." By switching to a single `$`, Terraform properly evaluated the variable and injected the real IP address.

### Terraform State Corruption (Orphaned Pool)
*   **The Problem:** Running `terraform apply` crashed with the error `Storage pool not found: no storage pool with matching name 'pool_b'`.
*   **Why we needed to fix it:** We had manually deleted the physical pool and VMs using Virsh, but Terraform still remembered them in its `.tfstate` file, causing a desync between Terraform's brain and physical reality.
*   **The Fix:**
    ```bash
    virsh pool-destroy pool_b
    virsh pool-undefine pool_b
    sudo rm -rf /var/lib/libvirt/images/pool_b
    rm terraform.tfstate terraform.tfstate.backup
    ```
*   **Justification:** `pool-destroy` stops the pool, `pool-undefine` removes it from Virsh's config, and `rm -rf` deletes the physical leftovers. Finally, deleting `terraform.tfstate` completely wipes Terraform's memory. When run again, Terraform treats the directory as a brand new project and rebuilds everything cleanly from scratch.

## 3. Ansible & CIS Hardening

### SSH Host Key Rejections
*   **The Problem:** When Ansible attempted to connect to the newly provisioned VMs, the SSH connection was immediately rejected.
*   **Why we needed to fix it:** Terraform spins up brand new VMs with fresh IP addresses and new cryptographic Host Keys. The Ansible control node did not recognize these new keys, prompting a strict security rejection.
*   **The Fix:** In `ansible.cfg`:
    ```ini
    host_key_checking = False
    ```
*   **Justification:** Disabling host key checking prevents Ansible from interactively prompting the user to type "yes" to accept the new SSH fingerprint. This is absolutely mandatory for fully automated CI/CD pipelines where IPs are ephemeral.

### CIS Authselect Profile Failure
*   **The Problem:** The RHEL10-CIS role failed on an authselect task, stating "You still have the default name for your authselect profile".
*   **Why we needed to fix it:** The open-source CIS script deliberately fails if you leave the default variable `cis_example_profile` unchanged.
*   **The Fix:** In `group_vars/all.yml`:
    ```yaml
    rhel10cis_authselect_custom_profile_name: custom_pair_b_profile
    ```
*   **Justification:** The CIS benchmark requires administrators to explicitly create and name a custom authentication profile rather than relying on defaults. By overriding this variable, we prove to the script that we are intentionally configuring the profile.

### The Variable Precedence Promotion Bug
*   **The Problem:** Changes made in `group_vars/all.yml` were unexpectedly overriding variables explicitly set in the `playbook.yml`, breaking our intended 3-tier precedence structure.
*   **Why we needed to fix it:** We manually passed the file in the CLI command using `-e "@group_vars/all.yml"`. 
*   **The Fix:** 
    ```bash
    # BAD:
    ansible-playbook playbook.yml -e "@group_vars/all.yml"
    
    # GOOD:
    ansible-playbook playbook.yml
    ```
*   **Justification:** The `@` symbol in Ansible's command line tells the engine to read the file and inject every variable inside it as an "Extra Var" (Level 3 - Highest Precedence). By simply removing that flag, Ansible naturally discovers the `group_vars` directory and correctly loads them at Level 1 (Lowest Precedence), restoring our 3-tier design.

### CIS GPG Key Failure (Rule 1.2.1.1)
*   **The Problem:** The playbook failed with `Installed GPG Keys do not meet expected values`.
*   **Why we needed to fix it:** CIS benchmarks strictly require OS provider GPG keys to be present to verify package signatures. 
*   **The Fix:** In `group_vars/all.yml`:
    ```yaml
    rhel10cis_rule_1_2_1_1: false
    ```
*   **Justification:** Because we provisioned the OS completely offline from an ISO (via Kickstart) and haven't downloaded any packages from the internet yet, the official AlmaLinux GPG keys were never imported into the VM's RPM database. Since this is an expected behavior of our offline build process, we safely bypassed the rule.

### Undefined Variable Crash (`audit_log_dir`) due to Tagging
*   **The Problem:** When executing the playbook with `--tags "level1-server"`, the script failed at the very end with `Task failed: 'audit_log_dir' is undefined`.
*   **Why we needed to fix it:** The `audit_log_dir` variable is loaded during the `prelim_tasks` phase of the CIS script. 
*   **The Fix:**
    ```bash
    # BAD:
    ansible-playbook playbook.yml --tags "level1-server"
    
    # GOOD:
    ansible-playbook playbook.yml --skip-tags "level2-server,level2-workstation"
    ```
*   **Justification:** When using `--tags`, Ansible *only* executes tasks that explicitly match that tag. Because the `prelim_tasks` setup block does not have the `level1-server` tag, Ansible skipped it entirely, causing all variables to be undefined. By switching to `--skip-tags`, we tell Ansible to run everything (including the mandatory setup/teardown tasks) while exclusively ignoring the prohibited Level 2 rules.

### Re-running Ansible Causes "Permission Denied" Lockout
*   **The Problem:** Running the `ansible-playbook` command a second time on the same VMs immediately fails with `Permission denied (publickey,gssapi-keyex,gssapi-with-mic)`.
*   **Why we needed to fix it:** During the very first Ansible run, the CIS hardening script did its job perfectly—it disabled SSH Password Authentication. 
*   **The Fix:** 
    ```bash
    terraform destroy -auto-approve
    terraform apply -auto-approve
    ```
*   **Justification:** Because our dynamic inventory relies on `ansible_password=Buns123#` to connect, Ansible permanently locked itself out of the VMs after the first run secured the SSH daemon. This is a core concept of immutable infrastructure: if a configuration run fails halfway through, you cannot re-run it because the VM's state has mutated. You must destroy the VMs and provision fresh ones.

### Goss Audit Fails with `rc: 137`
*   **The Problem:** At the very end of the Ansible playbook, the `Post Audit` failed randomly on one of the nodes with the message: `Module result deserialization failed... rc: 137`.
*   **Why we needed to fix it:** The pipeline failed at the very finish line. Return code `137` in Linux means the process was terminated by the OOM (Out Of Memory) killer (`128 + 9 = SIGKILL`). The massive 711-test Goss audit spiked the RAM usage, causing the 2GB VM to run out of memory and the kernel to kill the SSH/Ansible python process.
*   **The Fix:** In `terraform/main.tf`, we increased the VM memory allocation:
    ```hcl
    memory = "3072"
    ```
*   **Justification:** Bumping the RAM from 2GB to 3GB gives the VM enough headroom to comfortably compile the massive JSON audit report without triggering the Linux OOM killer.

## 4. Jenkins Pipeline

### The "Split Brain" Terraform State Mismatch
*   **The Problem:** Running the Jenkins pipeline crashed during the Terraform Apply phase with `Error: storage pool 'pool_b' already exists`.
*   **Why we needed to fix it:** We manually executed the `virsh pool-destroy` and `pool-undefine` commands on our local laptop terminal to delete the infrastructure. However, the Jenkins workspace still retained a corrupted/out-of-sync `terraform.tfstate` file. 
*   **The Fix:**
    ```bash
    # Wipe the corrupted memory from Jenkins' isolated workspace
    sudo rm -f /var/lib/jenkins/workspace/Pair-B-Pipeline/terraform/*.tfstate*
    ```
*   **Justification:** When we deleted the physical VMs manually, Jenkins' local state file didn't know about it. Because Jenkins bypassed `terraform destroy` but the physical resources were gone, Terraform suffered a "split brain" mismatch between its memory and physical reality. By forcefully deleting Jenkins' local `.tfstate` files, we wipe its corrupted memory. This forces Jenkins to properly treat the environment as a completely blank slate. 
*   **Prevention Loop:** *Never* mix manual laptop terminal commands with automated Jenkins pipelines on the same hypervisor! If you build infrastructure via Jenkins, you **must** destroy it via Jenkins (using your new `DESTROY_AND_REBUILD` parameter checkbox) so the `.tfstate` files remain perfectly synchronized!
