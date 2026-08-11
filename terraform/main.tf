terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.1"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system?socket=/var/run/libvirt/libvirt-sock"
}

# Custom KVM storage pool named pool_b
resource "libvirt_pool" "pool_b" {
  name = "pool_b"
  type = "dir"
  path = "/var/lib/libvirt/images/pool_b"
}

# Generate an SSH key
resource "tls_private_key" "ssh_key" {
  algorithm = "ED25519"
}

# Save the private key to a file
resource "local_file" "private_key" {
  content         = tls_private_key.ssh_key.private_key_openssh
  filename        = "${path.module}/id_ed25519"
  file_permission = "0600"
}


# ==============================================================================
# CLOUD-INIT: Separate ISO files for each VM (SELinux workaround)
# ==============================================================================
resource "libvirt_cloudinit_disk" "commoninit" {
  count     = 2
  name      = "commoninit-pb-node-${count.index + 1}.iso"
  pool      = libvirt_pool.pool_b.name
  user_data = <<EOF
#cloud-config
ssh_pwauth: false
users:
  - name: root
    ssh_authorized_keys:
      - ${tls_private_key.ssh_key.public_key_openssh}
  - name: sysadmin
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: wheel
    shell: /bin/bash
    ssh_authorized_keys:
      - ${tls_private_key.ssh_key.public_key_openssh}
EOF
}

# ==============================================================================
# STORAGE: 3 Disks Total (1 OS + 2 Data @ 2G on SCSI)
# ==============================================================================
resource "libvirt_volume" "os_disk" {
  count  = 2
  name   = "pb-node-${count.index + 1}-os.qcow2"
  pool   = libvirt_pool.pool_b.name
  source = "../packer/output/golden_image.qcow2"
  format = "qcow2"
}

resource "libvirt_volume" "data_disk_1" {
  count  = 2
  name   = "pb-node-${count.index + 1}-data1.qcow2"
  pool   = libvirt_pool.pool_b.name
  size   = 2147483648 # 2GB in bytes
  format = "qcow2"
}

resource "libvirt_volume" "data_disk_2" {
  count  = 2
  name   = "pb-node-${count.index + 1}-data2.qcow2"
  pool   = libvirt_pool.pool_b.name
  size   = 2147483648 # 2GB in bytes
  format = "qcow2"
}

# ==============================================================================
# COMPUTE: 2 VMs, 2 vCPU, 2G RAM, UEFI, Host CPU Passthrough
# ==============================================================================
resource "libvirt_domain" "pb_nodes" {
  count   = 2
  name    = "pb-node-${count.index + 1}"
  memory  = "3072"
  vcpu    = 2
  machine = "q35"

  cpu {
    mode = "host-passthrough"
  }

  # UEFI firmware and nvram set explicitly
  firmware = "/usr/share/edk2/ovmf/OVMF_CODE.fd"
  nvram {
    file     = "/var/lib/libvirt/images/pool_b/pb-node-${count.index + 1}_VARS.fd"
    template = "/usr/share/edk2/ovmf/OVMF_VARS.secboot.fd"
  }

  # Main OS Disk
  disk {
    volume_id = libvirt_volume.os_disk[count.index].id
  }

  # Data Disk 1 (SCSI)
  disk {
    volume_id = libvirt_volume.data_disk_1[count.index].id
    scsi      = true
  }

  # Data Disk 2 (SCSI)
  disk {
    volume_id = libvirt_volume.data_disk_2[count.index].id
    scsi      = true
  }

  # Cloud-Init Disk (Semicolon UUID bug fix)
  disk {
    volume_id = split(";", libvirt_cloudinit_disk.commoninit[count.index].id)[0]
  }

  network_interface {
    network_name   = "default"
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
}

# ==============================================================================
# OUTPUTS & ANSIBLE INVENTORY GENERATION
# ==============================================================================
# Print IP as a raw string (e.g. 192.168.122.50) not a JSON array
output "pb_node_1_ip" {
  value = libvirt_domain.pb_nodes[0].network_interface[0].addresses[0]
}

output "pb_node_2_ip" {
  value = libvirt_domain.pb_nodes[1].network_interface[0].addresses[0]
}

# Generate Ansible Inventory Dynamically
resource "local_file" "ansible_inventory" {
  content  = <<EOF
[all]
pb-node-1 ansible_host=${libvirt_domain.pb_nodes[0].network_interface[0].addresses[0]}
pb-node-2 ansible_host=${libvirt_domain.pb_nodes[1].network_interface[0].addresses[0]}
[all:vars]
ansible_user=root
ansible_ssh_private_key_file=../terraform/id_ed25519
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF
  filename = "../ansible/inventory/hosts"
}
