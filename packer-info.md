# Packer and Kickstart Demystified

This document serves as a comprehensive Q&A guide to understanding how Packer, Kickstart, UEFI, and LVM work together to build Enterprise Linux images.

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

---

## 1. What is a Kickstart file and how does it relate to Packer?

**Question:** Is the kickstart basically a clean instruction manual without the actual OS inside it? Since we run `clearpart --all`, does it wipe the disk? Does the storage setting here affect the disk size I give in the Packer build?

**Answer:**
Yes! A Kickstart file (`kickstart.cfg`) is literally just an instruction manual for the Red Hat/AlmaLinux installer (Anaconda). When the installer boots up, it reads this file to automate the installation instead of asking a human to click through a GUI.

- `clearpart --all --initlabel`: This command tells the installer to wipe whatever disk it finds completely clean, destroy existing data/partitions, and prepare it for a fresh installation.
- **Where is the OS?** The OS is **not** in the kickstart file. The kickstart file points the installer to internet URLs (using `url --url=...`) to download the actual OS packages.
- **Disk Size Relationship:** The disk size defined in Packer (e.g., `disk_size = "20G"`) is the physical boundary (the "lot size"). The kickstart file is the blueprint that carves up that lot into rooms (`/var`, `/boot`, `/`). If your kickstart requests more space than Packer provides, the installation fails.

## 2. Why does Packer need an ISO if Kickstart downloads the OS?

**Question:** What is the purpose of `iso_url` and `iso_checksum` in the Packer build if the VM gets the OS from the URL inside the kickstart?

**Answer:**
A brand new, empty virtual machine doesn't know how to do anything—it can't connect to the internet, format a drive, or read a kickstart file. 

The `iso_url` points to a tiny **boot ISO** (netinstall). Its only job is to boot the VM and start the Anaconda installer program. Once Anaconda is running from RAM, Packer types a boot command to tell it: *"Read my kickstart file."* Anaconda then reads the kickstart, connects to the internet URLs, downloads the heavy OS packages, and installs them to the final `.qcow2` virtual hard drive.

- **The ISO** is a temporary tool just to run the installer.
- **The `.qcow2`** is the final built image containing the full downloaded OS.
- **`iso_checksum`** ensures the downloaded boot ISO is neither corrupted during download nor compromised by a malicious actor.

## 3. Why are `/boot/efi` and `/boot` separated? What is EFI?

**Question:** Explain in simple terms how `/boot/efi` and `/boot` are separated, and why we need EFI if `/boot` is already used to start the device.

**Answer:**
Think of starting your computer like starting a massive factory.

- **UEFI (The Night Watchman):** When you press the power button, the motherboard firmware (UEFI) wakes up. It is very simple and only knows how to read basic, universally understood filesystems (FAT32).
- **`/boot/efi` (The Lobby Desk):** The motherboard looks here first. It is formatted simply (`fat32`) so the motherboard can read it. It contains a specialized manager called the **Bootloader (GRUB)**.
- **GRUB (The Factory Manager):** GRUB is smart and knows how to read complex Linux filesystems (like XFS or LVM).
- **`/boot` (The Technical Blueprint Room):** This partition holds the Linux Kernel (the core of the OS). It uses a fast, native Linux filesystem (`xfs`). 

**Why separate them?** 
The motherboard is too "dumb" to read the complex `/boot` partition directly. It needs the simple `/boot/efi` partition just to find the GRUB manager. GRUB then reads `/boot` to start the actual Linux OS.

## 4. Why is the fstype `efi` instead of `fat32` in the kickstart?

**Question:** If `/boot/efi` is just FAT32 under the hood, why does the kickstart say `--fstype="efi"`?

**Answer:**
The keyword `efi` is a shortcut for the installer that does **two** things at once:
1. **Formats it as FAT32:** Just as the motherboard expects.
2. **Raises the "EFI Flag":** It attaches a special hidden label (EFI System Partition GUID) to the partition table. 

Without this flag, the motherboard might look at the FAT32 partition and think it's just a regular USB thumb drive with photos on it. The `efi` flag is a giant neon sign telling the motherboard: *"Look here! I contain the critical boot files you need!"*

## 5. Laptop Defaults vs. Server Kickstarts

**Question:** I checked my physical laptop with `lsblk -f` and it has the same EFI -> Boot -> LVM setup. Is this the default? Why do we manually write this in Kickstart if it's the automatic default?

**Answer:**
Yes, your laptop's layout is the picture-perfect Enterprise Linux automatic default! 

If the automatic layout works, why manually define partitions in Kickstart? **Separation of blast radius (Security & Stability).**

- **Laptops (Automatic):** Lumps almost everything into the root (`/`) and `/home` partitions. If an application goes crazy and fills the root partition with logs, the whole laptop crashes.
- **Servers (Manual Kickstart):** We manually carve out boundaries like `/var/log` (1000 MB) and `/var/tmp` (1000 MB). If an application writes massive amounts of logs, only the `/var/log` partition fills up. The application might stop logging, but the root partition remains safe, meaning the server stays online. 

Additionally, servers rarely have a `/home` partition because humans aren't saving personal files on them. Instead, they use `/srv` or `/var` for databases and applications.

## 6. How can a 1000 MB Physical Volume hold 15 GB of Logical Volumes?

**Question:** In the kickstart, the LVM PV has `--size=1000`, but the Logical Volumes inside it exceed 15 GB. How can 1000 MB handle that?

**Answer:**
The secret is the keyword at the end of the line: `part pv.01 --size=1000 --grow`

- `--size=1000` is only the **minimum starting request** (1 GB).
- `--grow` tells the installer: *"Once you have your 1 GB, look around. If there is any unassigned free space left on this hard drive, eat all of it."*

Since Packer provided a 20 GB disk, and the boot partitions only took ~1.5 GB, there was 18.5 GB of empty space left. The `--grow` command caused the Physical Volume (`pv.01`) to instantly expand from 1 GB to swallow the remaining 18.5 GB. 

Because the resulting Volume Group (`vg_sys_b`) now has 18.5 GB of capacity, it can easily hand out the 15 GB requested by the Logical Volumes inside it.

## 7. What are `@core`, `cloud-init`, and `qemu-guest-agent`?

**Question:** What are the `@core` packages, what is inside it? What do `cloud-init` and `qemu-guest-agent` do in the kickstart, and how do they affect the VM?

**Answer:**
When the kickstart reaches the `%packages` section, it stops building the "house" (partitions) and starts moving the "furniture" (software) in.

1. **`@core` (The Bare Minimum OS):** 
   The `@` symbol means it is a "Package Group" (a pre-defined bundle). It contains the absolute bare-minimum software required for a functional, command-line Linux system (e.g., `bash`, `systemd`, `dnf`, basic networking tools). It intentionally excludes heavy, useless things like a graphical desktop (GUI) to keep the server lean and secure.
2. **`cloud-init` (The Cloud Architect):**
   When you deploy multiple VMs from a single Packer "Golden Image", they are identical clones. `cloud-init` runs on the **very first boot** of the deployed VM. It reaches out to the cloud provider (AWS, Proxmox, OpenStack), asks for metadata, and automatically injects unique SSH keys, sets a unique hostname, and configures the IP address. It turns a generic clone into a unique, ready-to-use server.
3. **`qemu-guest-agent` (The Host-to-Guest Telephone):**
   Because Packer is building a QEMU/KVM virtual machine, this agent runs inside the AlmaLinux VM. It opens a secret communication channel to the hypervisor (the physical host server). This allows the hypervisor to send graceful shutdown commands to the VM and safely "freeze" the filesystem to take corruption-free backups.

## 8. Kickstart Passwords vs. Packer Passwords

**Question:** In kickstart we have `rootpw --plaintext --allow-ssh "Buns123#"`. In Packer we have `ssh_password = "Buns123#"`. Are these used by Packer? Are they separate?

**Answer:**
They are two separate configurations for two different tools, but they **must match** for the build to succeed. They act like a lock and a key.

- **The Lock (Kickstart):** `rootpw --plaintext "Buns123#"` tells the Anaconda installer: *"When you build this OS, permanently set the root user's password to Buns123#."* This bakes the password into the `.qcow2` hard drive.
- **The Key (Packer):** `ssh_password = "Buns123#"` tells Packer: *"After the OS finishes installing and reboots, use this password to try and log into it."*

**The Workflow:**
1. Kickstart installs the OS and sets the root password.
2. The VM reboots into the fresh OS.
3. Packer patiently waits, pinging the VM on port 22 (SSH).
4. When SSH starts, Packer attempts to log in using the `ssh_password` you provided.
5. Because it matches the Kickstart password, Packer gets in! 
6. Once inside, Packer can run any final setup scripts (provisioners) and then issues the `shutdown_command` to cleanly turn the VM off and finalize the image. If the passwords didn't match, Packer would get locked out and the build would time out and fail!

## 9. Code Order in Packer (Declarative vs. Procedural)

**Question:** If the `boot_command` is at the bottom of the `.pkr.hcl` file, and `ssh_password` is at the top, how does Packer know to run the boot command first and do the SSH part later? Shouldn't it read top to bottom?

**Answer:**
In a standard script like Bash or Python (which are **Procedural**), the computer reads and executes strictly top to bottom. Line 1 runs, then line 2 runs.

Packer's configuration language (HCL) is **Declarative**. Think of it as a blueprint or a character sheet, not a script. 
When you run `packer build`, Packer does **not** execute the file top-to-bottom. Instead, it reads the *entire file all at once* and memorizes all the facts into its internal memory (e.g., *"I see `ssh_password`, I'll put that in my pocket for later"*).

Once Packer has memorized your entire blueprint, its internal engine follows a strict, pre-programmed lifecycle order, regardless of how you ordered the text in your file:
1. Create the virtual machine.
2. Boot from the ISO.
3. Wait for `boot_wait`.
4. Type out the `boot_command` on the virtual keyboard.
5. Wait for the Kickstart installation to finish.
6. Try to log in using the `ssh_password` it memorized earlier.
7. Run any final provisioner scripts.
8. Run the `shutdown_command`.

Because of this declarative nature, you could put `boot_command` at the very top of the file and `ssh_password` at the very bottom, and Packer would behave exactly the same way!

## 10. Terraform, Cloud-Init, and SSH Keys

**Question:** In our Terraform code, we generate an SSH key and use `cloud-init` to set `ssh_pwauth: false`. How does this connect to the password we set in Kickstart, and how exactly does Terraform inject this key?

**Answer:**
When Terraform boots up the "Golden Image" `.qcow2` file created by Packer, the VM still has the `Buns123#` password baked into it. However, Terraform uses `cloud-init` to dynamically secure the VM on its very first boot.

1. **Key Generation:** Terraform uses a `tls_private_key` resource to generate a brand new, highly secure public/private SSH key pair on the fly. It saves the private key to your local machine (e.g., `id_ed25519`).
2. **Cloud-Init Injection:** Terraform creates a tiny virtual CD-ROM (`libvirt_cloudinit_disk`) containing `user_data` (YAML configuration) and attaches it to the VM.
3. **The Lock Down:** When the VM boots, the `cloud-init` service inside the VM reads this CD-ROM. It takes the `${tls_private_key.ssh_key.public_key_openssh}` string and pastes it directly into the root user's `authorized_keys` file. 
4. **Disabling Passwords:** Crucially, the `cloud-init` YAML also contains `ssh_pwauth: false`. This tells the SSH service to permanently reject all password login attempts over the network. 

Now, Ansible can securely log into the VM using the private key, and hackers cannot brute-force the `Buns123#` password because passwords are no longer allowed over SSH!

## 11. Defending the Kickstart Password

**Question:** If Terraform just disables the password and uses SSH keys anyway, why do we bother setting a `Buns123#` password in the Kickstart file? Why not just disable passwords from the beginning?

**Answer:**
Setting a password in Kickstart but disabling it over the network in Terraform is an industry best practice known as "Defense in Depth". Here are the three reasons why:

1. **Break-Glass Emergency Access (The Console):** When `cloud-init` sets `ssh_pwauth: false`, it *only* disables passwords over the network (SSH). It **does not** delete the root password. If the server's network crashes, or the firewall blocks port 22, you will be locked out because SSH keys require a network connection. To fix the server, you must log in through the hypervisor's "Virtual Console" (acting like a physical monitor and keyboard). The virtual console **does not support SSH keys**. You absolutely *must* have a root password to type on the keyboard to fix a broken server.
2. **Packer's Build Requirement:** Packer needs a way to log into the fresh VM to finish the build process (like running provisioners and issuing the final shutdown command). Setting a standard build password in Kickstart and telling Packer to use it is the most reliable way to guarantee Packer doesn't get locked out of its own build.
3. **Best of Both Worlds:** By setting a complex password during the build (Kickstart), but explicitly turning off password access for the network during deployment (Terraform), we get perfect network security (SSH Keys only) while retaining an emergency backdoor (the password) if we are physically sitting at the hypervisor terminal.

## 12. The Terraform to Ansible Handoff (Dynamic IPs)

**Question:** How does Terraform use the Golden Image to provision VMs, and how does it know the IP addresses to give to Ansible?

**Answer:**
Terraform acts as the bridge between your Packer image and your Ansible configuration.

1. **Cloning the Image:** Terraform never boots the `golden_image.qcow2` directly. Instead, it creates exact clones of it (e.g., `os_disk`) for every VM it needs to build.
2. **Waiting for the IP:** In the network configuration, Terraform uses `wait_for_lease = true`. When the VM boots up, it asks the virtual router (DHCP) for an IP address. Terraform pauses the build and waits patiently. As soon as the router assigns an IP (e.g., `192.168.122.50`), Terraform grabs that IP and saves it into its internal memory.
3. **The Handoff:** Because the router hands out random IP addresses, you can't hardcode an Ansible `hosts` file (it would break every time the IPs change). Instead, Terraform uses a `local_file` resource to dynamically write the Ansible inventory file *for* you, pasting in the exact random IP addresses it just learned!

## 13. Understanding the Ansible Inventory Format

**Question:** In the Terraform code that generates the Ansible inventory, what do `[all]` and `[all:vars]` mean? Do the `root` user and `StrictHostKeyChecking=no` get stored in the `hosts` file too?

**Answer:**
Yes! Everything between the `<<EOF` and `EOF` markers gets written directly into the `../ansible/inventory/hosts` file. It uses a format called **INI**.

Here is how the INI format works for Ansible:

1. **`[all]` (The Group):** Anything inside brackets is a "Group". `[all]` is a special group that includes every server listed below it. This is where Terraform pastes the dynamic IPs.
2. **`[all:vars]` (The Group Variables):** Adding `:vars` to a group name means: *"Apply these settings to every single server inside the group above."* This saves you from typing the SSH key and user on every single line.

**What do the variables do?**
- `ansible_user=root`: Tells Ansible to log into the servers as the root user.
- `ansible_ssh_private_key_file=...`: Tells Ansible to use the private key that Terraform generated, completing the lock-and-key setup.
- **`StrictHostKeyChecking=no`:** This is crucial for automation! When you SSH into a new server for the first time, your computer asks, *"The authenticity of host... can't be established. Are you sure you want to continue connecting (yes/no)?"* Because Ansible is a robot, it doesn't know how to type "yes", so it would freeze forever. Furthermore, because Terraform destroys and recreates these VMs often, their internal "fingerprints" change constantly. This setting tells the SSH client to completely ignore the fingerprint check and automatically say "yes", allowing the automation to run smoothly.

## 14. What is CIS and the Ansible CIS Role?

**Question:** What exactly is the CIS repository doing? Are we applying all 500+ rules from the benchmark, and why do we change some of them in `all.yml` and `playbook.yml`?

**Answer:**
Out of the box, a fresh installation of Linux is inherently insecure. The **Center for Internet Security (CIS)** publishes massive, 500-page "Benchmarks" that list hundreds of specific rules on how to lock down an operating system to enterprise-grade security.

- **The Ansible CIS Role (The Robot):** Instead of you manually typing 500 commands to fix permissions and disable services, the open-source CIS role automates the entire PDF. By default, when you include this role in your playbook, it attempts to forcefully apply **every single rule**.
- **Tailoring (The Steering Wheel):** Not every rigid security rule fits every business. For example, CIS Rule 5.4.2 says to permanently lock an account after 3 failed password attempts. However, Pair B constraints dictate *no account lockouts* because it breaks automated pipelines. 
- By setting `rhel10cis_rule_5_4_2: false` in your playbook, you are **Tailoring**. You are telling the automated robot: *"Stop! Do not run this specific rule. I am intentionally overriding it because of my business needs."*

## 15. Ansible Variable Precedence & `group_vars/all.yml`

**Question:** Why is `all.yml` separate from `playbook.yml`? What do the three precedence levels mean in the task brief?

**Answer:**
Your pipeline task requires you to prove you understand how Ansible decides which variable "wins" when there is a conflict, using three precedence levels. You successfully mapped this out:

1. **Level 1 (Lowest Precedence - `group_vars/all.yml`):**
   - **Why separate?** Separation of concerns. Think of `playbook.yml` as your **action verbs** (run this role, format this disk) and `all.yml` as your **data nouns** (settings). If you put 150 CIS overrides in the playbook, it becomes unreadable. `group_vars/all.yml` applies settings automatically to every server in the `[all]` group.
   - **What's inside?** Pair B settings like `rhel10cis_syslog: journald` and running the Goss audit.
2. **Level 2 (Medium Precedence - `playbook.yml` `vars:`):**
   - Variables placed directly in the playbook override `group_vars`. This is where you smartly disabled `rhel10cis_rule_5_4_2` to prevent account lockouts.
3. **Level 3 (Highest Precedence - Command Line `-e`):**
   - Variables passed via `-e` in the Jenkinsfile override everything else. This is where you put the password aging requirement (`-e "rhel10cis_pass_max_days=90"`).

**Critical Jenkinsfile Bug Note:** If you ever pass a file using `-e "@group_vars/all.yml"`, Ansible treats every variable in that file as Level 3 (Highest). This would accidentally promote your `all.yml` and destroy your 3-tier precedence setup! Ansible automatically reads `group_vars` if the inventory is set correctly, so you don't need to pass it manually with `-e`.

## 16. What is the fundamental purpose of the RHEL10-CIS role?

**Question:** What exactly is the CIS repository doing? What is its core purpose and how does it actually apply security to the VM?

**Answer:**
Out of the box, a fresh installation of Linux is built for convenience, not security. It has unnecessary features turned on and weak default permissions. The Center for Internet Security (CIS) publishes massive, 500-page "Benchmark" PDFs detailing hundreds of strict rules on how to lock down an OS for enterprise or military use.

Instead of a human reading that 500-page PDF and manually typing hundreds of commands to secure a server (which takes days and causes human error), a community wrote the **RHEL10-CIS Ansible Role**. 
This role is simply a massive automated script that translates every PDF rule into code. When Ansible connects to your VM, it acts like a lightning-fast security robot. It scans your system, edits config files (like disabling root login over SSH), changes file permissions, and disables insecure services, transforming an insecure base OS into a hardened server in just a few minutes.

## 17. CIS Level 1 vs Level 2 Security Profiles

**Question:** What does "Level 1 - Server only" mean in the task? What is the difference between Level 1 and Level 2?

**Answer:**
When CIS publishes their 500-page PDF, they divide their security rules into two distinct profiles:
*   **CIS Level 1 (L1) - "The Corporate Default":** Practical, base-level security hygiene that should be applied to almost every VM. It enforces password complexity, ensures firewalls are running, and sets safe permissions. It significantly improves security *without* breaking your applications.
*   **CIS Level 2 (L2) - "Defense-in-Depth":** Extreme lockdown intended only for highly sensitive environments (military, banking). It will break things. It disables USB ports, strictly limits network protocols, and turns on extreme logging that degrades performance.

The task explicitly asks for **Level 1 Server only**, meaning you must not apply Level 2 rules because they will break the pipeline's automation.

## 18. How to explicitly filter Level 1 tasks (Ansible Tags)

**Question:** If we only want Level 1, how do we make sure Ansible doesn't apply the Level 2 rules? Does it apply all 500 by default?

**Answer:**
By default, the open-source RHEL10-CIS role aggressively defaults to applying *both* Level 1 and Level 2 rules!
To fix this, we do two things:
1. **Set `rhel10cis_level_2: false` in `all.yml`:** This tells the internal logic of the role and the final Goss Auditor that we do not care about Level 2 compliance, so we don't get penalized in our final score.
2. **Use Ansible Tags:** Even with the variable set to `false`, the Ansible Engine would still stubbornly evaluate every single one of the 500 tasks, wasting time. To force Ansible to skip them entirely, we append `--tags "level1-server"` to the `ansible-playbook` command in our Jenkinsfile. This physically forces the engine to ignore any task tagged with `level2-server`, perfectly fulfilling the assignment constraint.

## 19. Virsh Pools & Volumes vs LVM VGs & LVs

**Question:** Is a Virsh Pool and Volume the same concept as an LVM Physical Volume (PV) and Logical Volume (LV)?

**Answer:**
Yes, they are conceptually identical! They just operate at two different layers (The Hypervisor vs The OS).
*   **The "Big Container" (VG vs Pool):** An LVM Volume Group (`vg_sys_b`) and a Virsh Storage Pool (`pool_b`) act like a giant, empty warehouse. They don't store data directly; their only job is to provide raw capacity. In Virsh, a Pool is literally just a dedicated folder on your laptop (e.g., `/var/lib/libvirt/images/pool_b/`).
*   **The "Carved Out Piece" (LV vs Vol):** An LVM Logical Volume (`/var`) and a Virsh Storage Volume (`pb-node-1-os.qcow2`) are the actual usable boundaries. In Virsh, a Volume is just the `.qcow2` file (the virtual hard drive) sitting inside that Pool folder.

**The Workflow:** Virsh creates a Folder (Pool), creates a File inside it (Volume), and plugs that file into the VM as a hard drive. Inside the VM, LVM looks at that hard drive (PV), turns it into a Volume Group (VG), and carves it up into smaller partitions (LVs).

## 20. SCSI vs Virtio Data Disks

**Question:** Why did we put `scsi` for the data disk instead of `virtio`? Is `virtio` the default?

**Answer:**
Yes, **`virtio`** is the standard, highly-optimized default for KVM/QEMU virtual machines. It uses "paravirtualization," meaning the VM knows it is virtual and talks directly to the hypervisor for blazing-fast disk speeds. Virtio disks are named `/dev/vda`, `/dev/vdb`, etc.

We explicitly used **`scsi`** solely because of the **PDF Assignment Constraints**. 
The instructors assigned Pair A the default (`virtio`) and assigned Pair B the override (`scsi`) to prove that you know how to customize Terraform beyond the defaults. By using `scsi`, the hypervisor emulates an old-school physical hardware controller, causing the disks to show up inside the VM as traditional `/dev/sda` and `/dev/sdb` drives instead.

## 21. Ansible Vault & Password Encryption

**Question:** Why did we create and encrypt `vault.yml`? How does Ansible even know to use it during the pipeline run?

**Answer:**
One of the CIS rules requires you to set a highly secure GRUB bootloader/root password. However, pushing a plaintext password (like `rhel10cis_root_password: "MySuperSecretPassword"`) directly into a Git repository is a massive security violation—anyone on the internet could steal it.

**How we solved it:**
1. We created a file inside `group_vars` (named `vault.yml`) and put the secret password inside it.
2. We ran `ansible-vault encrypt group_vars/vault.yml`. This encrypted the file with a master password (e.g., `vaultpass123`), turning it into unreadable gibberish. Because it is gibberish, it is now 100% safe to commit and push to GitHub!

**How Ansible uses it:**
Because `vault.yml` is sitting inside the `group_vars` directory, the Ansible engine automatically tries to read it when the playbook starts. 
When Ansible sees the file is encrypted, it looks at the command you ran (`--vault-password-file vaultpass.txt`). It opens `vaultpass.txt`, reads the master password inside, and uses it to seamlessly decrypt `vault.yml` in memory. This allows the CIS script to securely access the root password without it ever being exposed in your source code!
