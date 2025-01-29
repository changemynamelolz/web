#!/bin/bash

# Prompt for Windows VHDX download link
read -p "Enter the direct link to the Windows VHDX file: " VHDX_URL
VHDX_PATH="/root/windows.vhdx"

# Download the VHDX file
echo "Downloading Windows VHDX..."
curl -o "$VHDX_PATH" "$VHDX_URL" || { echo "Download failed!"; exit 1; }

# Ask for network details
read -p "Enter static IP (or type 'dhcp' for automatic config): " IP
read -p "Enter Netmask (if using static IP): " NETMASK
read -p "Enter Gateway (or type 'dhcp' if using automatic config): " GATEWAY

# Network interface (change if needed)
IFACE=$(ip route | awk '/default/ {print $5; exit}')

# Configure networking
if [[ "$IP" == "dhcp" && "$GATEWAY" == "dhcp" ]]; then
    echo "Using DHCP..."
    cat > /etc/network/interfaces <<EOF
auto $IFACE
iface $IFACE inet dhcp
dns-nameservers 1.1.1.1
EOF
else
    echo "Setting static IP..."
    cat > /etc/network/interfaces <<EOF
auto $IFACE
iface $IFACE inet static
address $IP
netmask $NETMASK
gateway $GATEWAY
dns-nameservers 1.1.1.1
EOF
fi

# Restart networking
echo "Applying network settings..."
systemctl restart networking || service networking restart

# Ask for disk to install Windows
lsblk
read -p "Enter the disk to install Windows (e.g., /dev/sda): " DISK

# Confirm before proceeding
read -p "Are you sure you want to wipe $DISK and install Windows? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Installation aborted."
    exit 0
fi

# Create the auto-install script
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

# Get disk UUID for GRUB entry
DISK_UUID=\$(blkid -s UUID -o value "$DISK")

echo "Configuring GRUB for Windows..."
cat > /boot/grub/grub.cfg <<GRUBEOF
set timeout=1
menuentry "Windows" {
    insmod ntfs
    search --no-floppy --fs-uuid --set=root \$DISK_UUID
    chainloader +1
}
GRUBEOF

echo "Windows installation complete. Rebooting..."
reboot
EOF

chmod +x /root/auto-install.sh

# Modify GRUB to boot into the install script
echo "Setting up GRUB for installation..."
cat > /etc/grub.d/40_custom <<EOF
menuentry "Auto Install Windows" {
    linux /boot/vmlinuz root=/dev/ram0 init=/root/auto-install.sh
}
EOF

# Set GRUB default to the install script
sed -i 's/GRUB_DEFAULT=.*/GRUB_DEFAULT="Auto Install Windows"/' /etc/default/grub

update-grub

echo "Installation setup complete. Rebooting..."
reboot
