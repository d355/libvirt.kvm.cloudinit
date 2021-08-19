#!/usr/bin/env bash
#
# The script creates VM using specified cloud image as base file
#   See usage below.
#
#   Refs:
#     * Partially based on:
#       * https://nbailey.ca/post/cephfs-kvm-virtual-san/
#       * https://github.com/fabianlee/local-kvm-cloudimage/blob/master/ubuntu-bionic/local-km-cloudimage.sh

# Uncomment for debug
#set -x
# No error handling, yet.
set -e

# Check input and show help
if [[ $# -lt 2 ]]; then
  echo "[!] Parameters required

[i] Usage:
      $0 VMName BaseImage [VMSize]
      Parameters:
        VMName    - Name for the new VM created
                    (also used as base for VM image naming)
        BaseImage - Base cloud image file pathname
        VMSize    - (Optional) Size for root partition of the new VM created,
                    accepted suffixes are:
                    K/M/G/T for kibibytes/mibibytes/gibibytes/tibibytes
                    (size should greater than original cloud image root
                    partition size)

    Other settings:
      * See 'Settings' section of this script
      * Contents of '~/.ssh/id_rsa.pub' file will be added to VM as trusted
        SSH public key (see 'Settings')

    Notes:
      * VM name is expected to do not contain any separator characters
        (spaces, etc.)
      * New VM image will be placed to the same directory as base one
      * Several temporary files will created at the current directory,
        write permission required (see 'Settings')
"
  exit 1
fi

# Define vars
VM_NAME="$1"
# Lowercase 
VM_NAME_LC="${VM_NAME,,}"
BASE_IMG="$2"
VM_IMG="$(dirname "$BASE_IMG")"/"$VM_NAME_LC".qcow2
VM_CC_IMG="$(dirname "$BASE_IMG")"/"$VM_NAME_LC".cloudinit.iso
CMD_CREATE_IMG_BACKING="qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$VM_IMG""
CMD_CREATE_IMG_CLONE="cp -f "$BASE_IMG" "$VM_IMG""
CMD_CREATE_IMG_CLONE_RESIZED="cp -f "$BASE_IMG" "$VM_IMG" ; resize "VM_IMG" "

## Settings
# Base image handling. Possible values:
#   1 - (Default) Use base image as backing image for VM image (create dependent clone)
#   0 - Use copy of base image for VM image (create clone)
USE_BACKING_IMAGE=1
# VM RAM size (MB)
VM_RAM=1024
# VM CPU cores count
VM_CPU=2
# VM graphics attached, possible values: vnc, spice or none
# (see 'man virt-install')
VM_GRAPHICS=none
# VM DNS domain
VM_NS_DOMAIN=local
# FQDN of VM host (local TLD by default)
VM_FQDN="$VM_NAME_LC.$VM_NS_DOMAIN"
# Use command 'osinfo-query os' to get available variants
OS_VARIANT='ubuntu20.04'
# Network adapter of the VM to use
VM_NETIF='enp1s0'
# SSH public key file to add as trusted ( ~/.ssh/id_rsa.pub by default)
SSH_PUBKEY="$([ -f ~/.ssh/id_rsa.pub ] && cat ~/.ssh/id_rsa.pub)"
# Temporary files directory
TEMP_DIR='.'

# Create image
case USE_BACKING_IMAGE in
  1)
    if [[ $# -gt 2 ]]; then
      $CMD_CREATE_IMG "$3"
    else
      $CMD_CREATE_IMG
    fi
    ;;
  0)
    if [[ $# -gt 2 ]]; then
      $CMD_CREATE_IMG_CLONE_RESIZED "$3"
    else
      $CMD_CREATE_IMG_CLONE
    fi
    ;;
esac
chown :kvm "$VM_IMG"

# Create meta-data cloud config
echo "instance-id: $(uuidgen || echo i-abcdefg)" > "$TEMP_DIR/meta-data"

# Create user-data cloud config
cat > "$TEMP_DIR/user-data" <<HEREDOC
#cloud-config
hostname: $VM_NAME_LC
fqdn: $VM_FQDN
manage_etc_hosts: true

timezone: Europe/Moscow

package_update: true
packages:
  - qemu-guest-agent

ssh_pwauth: false
chpasswd: 
  expire: False
  list: |
    root:1
users:
  - name: root
    ssh-authorized-keys:
      - $SSH_PUBKEY

growpart:
  mode: auto
  devices: ['/']

runcmd:
  - systemctl enable --now fstrim.timer
#  - apt -y purge cloud-init

power_state:
  mode: poweroff
HEREDOC

# Create network cloud config
cat > "$TEMP_DIR/network-config" <<HEREDOC
version: 2
ethernets:
  $VM_NETIF:
    dhcp4: true
     # default libvirt network
#     addresses: [ 192.168.122.158/24 ]
#     gateway4: 192.168.122.1
#     nameservers:
#       addresses: [ 192.168.122.1,8.8.8.8 ]
#       search: [ $VM_NS_DOMAIN ]
HEREDOC

# Create disk image from cloud config and remove temporary files
(
cd "$TEMP_DIR/"
mkisofs -o "$VM_CC_IMG" -V cidata -J -r meta-data user-data network-config
rm -f meta-data user-data network-config
)

# Create VM
virt-install \
  --name $VM_NAME \
  --memory $VM_RAM \
  --vcpus $VM_CPU \
  --disk "$VM_IMG,device=disk,bus=virtio,driver.discard=unmap" \
  --disk "$VM_CC_IMG,device=cdrom" \
  --os-type linux \
  --os-variant $OS_VARIANT \
  --virt-type kvm \
  --graphics $VM_GRAPHICS \
  --network network=default,model=virtio \
  --boot hd,menu=on

# Eject and remove cloud-init CD-ROM inmage after VM creation is done
virsh change-media $VM_NAME --path $( \
  virsh domblklist $VM_NAME | \
  fgrep $VM_NAME_LC.cloudinit.iso | \
  awk {' print $1 '} \
  ) --eject --force
rm -f "$VM_CC_IMG"

echo [i] VM created: $VM_NAME

