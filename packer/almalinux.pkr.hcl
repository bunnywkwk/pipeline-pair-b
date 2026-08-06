packer {
  required_plugins {
    qemu = {
      version = "~> 1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "almalinux10" {
  iso_url      = "https://repo.almalinux.org/almalinux/10/isos/x86_64/AlmaLinux-10-latest-x86_64-boot.iso"
  iso_checksum = "file:https://repo.almalinux.org/almalinux/10/isos/x86_64/CHECKSUM"

  accelerator = "kvm"
  disk_size   = "20G"
  format      = "qcow2"
  memory      = 4096
  cpus        = 2
  headless    = true

  # CPU Passthrough and UEFI settings (Pair B constraints)
  machine_type      = "q35"
  efi_boot          = true
  efi_firmware_code = "/usr/share/edk2/ovmf/OVMF_CODE.fd"
  efi_firmware_vars = "/usr/share/edk2/ovmf/OVMF_VARS.secboot.fd"
  qemuargs = [
    ["-cpu", "host"]
  ]

  vm_name          = "golden_image.qcow2"
  output_directory = "output"

  ssh_username     = "root"
  ssh_password     = "Buns123#"
  ssh_timeout      = "20m"
  shutdown_command = "shutdown -P now"

  http_directory = "."
  boot_wait      = "10s"

  # UEFI GRUB Boot Command
  boot_command = [
    "e<wait>",
    "<down><down><end><wait>",
    " inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/kickstart.cfg<wait>",
    "<leftCtrlOn>x<leftCtrlOff>"
  ]
}

build {
  sources = ["source.qemu.almalinux10"]
}
