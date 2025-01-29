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
            apt update && apt install -y curl qemu-utils grub-common ntfs-3g
            ;;
        fedora|rhel|centos|rocky)
            dnf install -y curl qemu-img grub2 ntfs-3g
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm curl qemu-base grub ntfs-3g
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

# Ask for target disk
lsblk
read -p "Enter the disk to install Windows (e.g., /dev/sda): " DISK

# Confirm installation
read -p "Are you sure you want to format $DISK and install Windows? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Installation aborted."
    exit 0
fi

# Create a Windows startup script
mkdir -p /mnt/windows
mount "$DISK" /mnt/windows

cat > /mnt/windows/Windows/System32/SetupIP.bat <<EOF
@echo off
echo Configuring network settings...

netsh interface ip set address "Ethernet" static $IP $NETMASK $GATEWAY
netsh interface ip set dns "Ethernet" static 1.1.1.1

echo Network configuration complete.
del %~f0
EOF

# Register the script in Windows Startup
echo "Adding IP configuration to Windows startup..."
REG_FILE="/mnt/windows/Windows/System32/SetupIP.reg"
cat > "$REG_FILE" <<EOF
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run]
"SetupIP"="C:\\Windows\\System32\\SetupIP.bat"
EOF

# Inject the registry settings
echo "Injecting startup script into Windows registry..."
wine regedit "$REG_FILE"

# Unmount Windows disk
umount /mnt/windows

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

# Add auto-install entry to GRUB
echo "Adding Windows auto-install to GRUB..."
cat > /etc/grub.d/40_custom <<EOF
menuentry "Auto Install Windows" {
    linux /boot/vmlinuz root=/dev/ram0 init=/root/auto-install.sh
}
EOF

# Set Windows installation as the next boot
grub-mkconfig -o /boot/grub/grub.cfg
grub-reboot "Auto Install Windows"

echo "Installation setup complete. Rebooting..."
reboot
