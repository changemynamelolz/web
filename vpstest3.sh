#!/bin/bash

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    echo "Unsupported OS"
    exit 1
fi

# Install required packages
install_packages() {
    case "$OS" in
        ubuntu|debian)
            apt update && apt install -y curl qemu-utils grub-common
            ;;
        fedora|rhel|centos|rocky)
            dnf install -y curl qemu-img grub2
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm curl qemu-base grub
            ;;
        *)
            echo "Unsupported OS: $OS"
            exit 1
            ;;
    esac
}

install_packages

# Get Windows VHDX download link
read -p "Enter the direct link to the Windows VHDX file: " VHDX_URL
FILENAME=$(basename "$VHDX_URL")
VHDX_PATH="/root/$FILENAME"

# Download VHDX
if [[ -f "$VHDX_PATH" ]]; then
    echo "File already exists: $VHDX_PATH"
else
    echo "Downloading Windows VHDX..."
    curl -o "$VHDX_PATH" "$VHDX_URL" || { echo "Download failed!"; exit 1; }
fi

# Handle .gz files
if [[ "$FILENAME" == *.gz ]]; then
    echo "Extracting GZ file..."
    GZ_EXTRACTED="/root/$(basename "$FILENAME" .gz)"
    cp "$VHDX_PATH" "$GZ_EXTRACTED"
    gunzip "$GZ_EXTRACTED"
    VHDX_PATH="$GZ_EXTRACTED"
fi

# Ask for network configuration
read -p "Enter static IP (or type 'dhcp' for auto-config): " IP
read -p "Enter Netmask (if using static IP): " NETMASK
read -p "Enter Gateway (or type 'dhcp' for auto-config): " GATEWAY

# Detect network interface
IFACE=$(ip route | awk '/default/ {print $5; exit}')

# Configure networking
if [[ "$IP" == "dhcp" && "$GATEWAY" == "dhcp" ]]; then
    echo "Using DHCP..."
    echo -e "[Match]\nName=$IFACE\n[Network]\nDHCP=ipv4\nDNS=1.1.1.1" > /etc/systemd/network/20-dhcp.network
else
    echo "Setting static IP..."
    echo -e "[Match]\nName=$IFACE\n[Network]\nAddress=$IP/$NETMASK\nGateway=$GATEWAY\nDNS=1.1.1.1" > /etc/systemd/network/20-static.network
fi
systemctl restart systemd-networkd

# Ask for target disk
lsblk
read -p "Enter the disk to install Windows (e.g., /dev/sda): " DISK

# Confirm installation
read -p "Are you sure you want to format $DISK and install Windows? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Installation aborted."
    exit 0
fi

# Create auto-install script inside the Windows OS image
cat > /root/auto-install.sh <<EOF
#!/bin/bash
echo "Formatting $DISK..."
mkfs.ntfs -f "$DISK"

echo "Mounting $DISK..."
mkdir -p /mnt/windows
mount "$DISK" /mnt/windows

echo "Extracting Windows VHDX to $DISK..."
qemu-img convert -p -O raw "$VHDX_PATH" "$DISK"

umount /mnt/windows

# Get disk UUID
DISK_UUID=\$(blkid -s UUID -o value "$DISK")

echo "Configuring GRUB for Windows..."
cat > /etc/grub.d/40_custom <<GRUBEOF
menuentry "Windows" {
    insmod ntfs
    search --no-floppy --fs-uuid --set=root \$DISK_UUID
    chainloader +1
}
GRUBEOF

grub-mkconfig -o /boot/grub/grub.cfg

echo "Restoring normal boot..."
grub-set-default 0

echo "Windows installation complete. Rebooting..."
reboot
EOF

chmod +x /root/auto-install.sh

# Modify GRUB to show the special entry for the extraction process
cat > /etc/grub.d/40_custom <<EOF
menuentry "Auto Install Windows" {
    linux /boot/vmlinuz root=/dev/ram0 init=/root/auto-install.sh
}
EOF

# Set Windows installation as the next boot (temporary)
grub-mkconfig -o /boot/grub/grub.cfg
grub-reboot "Auto Install Windows"

echo "Windows extraction setup complete. Rebooting..."
reboot
