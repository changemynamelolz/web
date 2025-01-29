#!/bin/bash

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    echo "Unsupported OS"
    exit 1
fi

# Function to install required packages
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

# Ensure required packages are installed
install_packages

# Prompt for Windows image link
read -p "Enter the direct link to the Windows VHDX file: " VHDX_URL
FILENAME=$(basename "$VHDX_URL")
VHDX_PATH="/root/$FILENAME"

# Download the file if not already present
if [[ -f "$VHDX_PATH" ]]; then
    echo "File already exists: $VHDX_PATH"
else
    echo "Downloading Windows VHDX..."
    curl -o "$VHDX_PATH" "$VHDX_URL" || { echo "Download failed!"; exit 1; }
fi

# Handle .gz files
if [[ "$FILENAME" == *.gz ]]; then
    echo "Detected gzip-compressed file. Extracting..."
    GZ_EXTRACTED="/root/$(basename "$FILENAME" .gz)"
    cp "$VHDX_PATH" "$GZ_EXTRACTED"
    gunzip "$GZ_EXTRACTED"
    VHDX_PATH="$GZ_EXTRACTED"
fi

# Network Configuration
read -p "Enter static IP (or type 'dhcp' for automatic config): " IP
read -p "Enter Netmask (if using static IP): " NETMASK
read -p "Enter Gateway (or type 'dhcp' if using automatic config): " GATEWAY

# Detect network interface
IFACE=$(ip route | awk '/default/ {print $5; exit}')

# Configure networking
if [[ "$IP" == "dhcp" && "$GATEWAY" == "dhcp" ]]; then
    echo "Using DHCP..."
    case "$OS" in
        ubuntu|debian)
            cat > /etc/network/interfaces <<EOF
auto $IFACE
iface $IFACE inet dhcp
dns-nameservers 1.1.1.1
EOF
            ;;
        fedora|rhel|centos|rocky)
            nmcli con mod $IFACE ipv4.method auto
            nmcli con mod $IFACE ipv4.dns "1.1.1.1"
            ;;
        arch|manjaro)
            cat > /etc/systemd/network/20-wired.network <<EOF
[Match]
Name=$IFACE

[Network]
DHCP=ipv4
DNS=1.1.1.1
EOF
            systemctl restart systemd-networkd
            ;;
    esac
else
    echo "Setting static IP..."
    case "$OS" in
        ubuntu|debian)
            cat > /etc/network/interfaces <<EOF
auto $IFACE
iface $IFACE inet static
address $IP
netmask $NETMASK
gateway $GATEWAY
dns-nameservers 1.1.1.1
EOF
            ;;
        fedora|rhel|centos|rocky)
            nmcli con mod $IFACE ipv4.method manual ipv4.addresses $IP/$NETMASK ipv4.gateway $GATEWAY ipv4.dns "1.1.1.1"
            ;;
        arch|manjaro)
            cat > /etc/systemd/network/20-static.network <<EOF
[Match]
Name=$IFACE

[Network]
Address=$IP/$NETMASK
Gateway=$GATEWAY
DNS=1.1.1.1
EOF
            systemctl restart systemd-networkd
            ;;
    esac
fi

# Restart networking
echo "Applying network settings..."
case "$OS" in
    ubuntu|debian)
        systemctl restart networking || service networking restart
        ;;
    fedora|rhel|centos|rocky)
        nmcli con up $IFACE
        ;;
    arch|manjaro)
        systemctl restart systemd-networkd
        ;;
esac

# Ask for target disk
lsblk
read -p "Enter the disk to install Windows (e.g., /dev/sda): " DISK

# Confirm installation
read -p "Are you sure you want to format $DISK and install Windows? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Installation aborted."
    exit 0
fi

# Create auto-install script
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
case "$OS" in
    ubuntu|debian|arch|manjaro)
        cat > /boot/grub/grub.cfg <<GRUBEOF
set timeout=1
menuentry "Windows" {
    insmod ntfs
    search --no-floppy --fs-uuid --set=root \$DISK_UUID
    chainloader +1
}
GRUBEOF
        grub-mkconfig -o /boot/grub/grub.cfg
        ;;
    fedora|rhel|centos|rocky)
        cat > /boot/grub2/grub.cfg <<GRUBEOF
set timeout=1
menuentry "Windows" {
    insmod ntfs
    search --no-floppy --fs-uuid --set=root \$DISK_UUID
    chainloader +1
}
GRUBEOF
        grub2-mkconfig -o /boot/grub2/grub.cfg
        ;;
esac

echo "Windows installation complete. Rebooting..."
reboot
EOF

chmod +x /root/auto-install.sh

# Modify GRUB for auto-install
echo "Setting up GRUB for installation..."
case "$OS" in
    ubuntu|debian|arch|manjaro)
        cat > /etc/grub.d/40_custom <<EOF
menuentry "Auto Install Windows" {
    linux /boot/vmlinuz root=/dev/ram0 init=/root/auto-install.sh
}
EOF
        grub-mkconfig -o /boot/grub/grub.cfg
        ;;
    fedora|rhel|centos|rocky)
        cat > /etc/grub.d/40_custom <<EOF
menuentry "Auto Install Windows" {
    linux /boot/vmlinuz root=/dev/ram0 init=/root/auto-install.sh
}
EOF
        grub2-mkconfig -o /boot/grub2/grub.cfg
        ;;
esac

echo "Installation setup complete. Rebooting..."
reboot
