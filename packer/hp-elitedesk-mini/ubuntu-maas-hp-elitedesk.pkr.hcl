packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "ubuntu_release" {
  type    = string
  default = "24.04"
}

source "qemu" "ubuntu" {
  disk_image         = true
  iso_url            = "https://cloud-images.ubuntu.com/releases/server/${var.ubuntu_release}/release/ubuntu-${var.ubuntu_release}-server-cloudimg-amd64.img"
  iso_checksum       = "file:https://cloud-images.ubuntu.com/releases/server/${var.ubuntu_release}/release/SHA256SUMS"
  disk_size          = "20000"
  format             = "qcow2"
  memory             = 2048
  ssh_username       = "ubuntu"
  ssh_private_key_file = "../../ssh-key/packer_id_rsa"
  ssh_timeout        = "20m"
  ssh_clear_authorized_keys = true
  floppy_files          = ["seed.img"]
  qemuargs              = [ ["-fda", "seed.img"] ]
  shutdown_command   = "sudo shutdown -P now"
  boot_wait          = "5s"
  headless           = true
  output_directory = "output-qemu"
  #output_filename = "ubuntu-${var.ubuntu_release}.qcow2"
}

build {
  sources = ["source.qemu.ubuntu"]

  # Apply tg3 fix (runs inside the image as root)
  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "apt-get update && apt-get install -y linux-image-generic",
      #"apt-get update && apt-get install -y ethtool",
      "mkdir -p /etc/udev/rules.d",
      "echo 'ACTION==\"add\", SUBSYSTEM==\"net\", ATTRS{vendor}==\"0x14e4\", ATTRS{device}==\"0x1687\", RUN+=\"/sbin/ethtool -K %k highdma off\"' > /etc/udev/rules.d/80-tg3-highdma-fix.rules",
      "udevadm control --reload-rules",
      "echo 'tg3 PXE fix applied for HP EliteDesk Mini'"
    ]
  }

  # Extract boot files and package MAAS-ready .tar.gz (runs on host)
post-processor "shell-local" {
    environment_vars = ["VERSION=${var.ubuntu_release}"]
    inline = [
      "echo 'Looking for QCOW2 file...' && ls -la output-qemu/",
      #"QCOW2=$(find output-qemu -name '*.qcow2' | head -1)",
      "QCOW2=output-qemu/packer-ubuntu",
      "echo \"Found QCOW2: $QCOW2\"",
      "OUTDIR=maas-ubuntu-$VERSION-hp-elitedesk-mini",
      "mkdir -p $OUTDIR",
      "cp \"$QCOW2\" $OUTDIR/disk1.img",

      "sudo apt-get update && sudo apt-get install -y qemu-utils qemu-system qemu-kvm",

      # attach qcow2 via nbd
      "sudo modprobe nbd max_part=8",
      "sudo qemu-nbd --connect=/dev/nbd0 \"$QCOW2\"",
      "sudo lsblk -nrpo NAME,FSTYPE /dev/nbd0",

      # detect ext4 partition
      #"PART=$(lsblk -nrpo NAME,FSTYPE /dev/nbd0 | awk '$2==\"ext4\" {print $1; exit}')",
      #"echo \"Mounting partition: $PART\"",
      #"sudo mount \"$PART\" /mnt",
      "sudo mount /dev/nbd0p1 /mnt",

      # fetch kernel/initrd from cloud-images release directory
      "wget -O \"$OUTDIR/boot-kernel\" https://cloud-images.ubuntu.com/releases/${var.ubuntu_release}/release/ubuntu-${var.ubuntu_release}-server-cloudimg-amd64-vmlinuz-generic",
      "wget -O \"$OUTDIR/boot-initrd\" https://cloud-images.ubuntu.com/releases/${var.ubuntu_release}/release/ubuntu-${var.ubuntu_release}-server-cloudimg-amd64-initrd-generic",

      # cleanup
      "sudo umount /mnt",
      "sudo qemu-nbd --disconnect /dev/nbd0",

      "tar -czf $OUTDIR.tar.gz -C $OUTDIR .",
      "rm -rf $OUTDIR",
      "echo 'SUCCESS: MAAS image created → $OUTDIR.tar.gz'"
    ]
  }
}
