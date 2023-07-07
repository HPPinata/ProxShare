#!/bin/bash

set-PASS () {
  local passvar=1; local passvar2=2
  while [[ "$passvar" != "$passvar2" ]]; do echo "SMB password previously unset or input inconsistent."; \
    read -sp 'Password: ' passvar
    echo
    read -sp 'Confirm: ' passvar2
    echo
  done
  smb_password="$(iconv -f ASCII -t UTF-16LE <(printf $passvar) | openssl dgst -md4 -provider legacy | awk -F '= ' {'print $2'})"
}
set-PASS

apt update && apt full-upgrade -y && apt autopurge -y
apt install -y bcache-tools duperemove samba snapper

systemctl enable smb
systemctl enable nfs-server

modprobe bcache
echo 1 | tee /sys/fs/bcache/*/stop
echo 1 | tee /sys/block/bcache*/bcache/stop
sleep 1

pass=$(ls /dev/sd*)
wipefs -f -a ${pass[@]} /dev/nvme0n1

bcache make -C /dev/nvme0n1
bcache register /dev/nvme0n1
sleep 1

for blk in ${pass[@]}; do
  bcache make -B $blk
  bcache register $blk
  sleep 1
  bcache attach /dev/nvme0n1 $blk
  bcache set-cachemode $blk writeback
done

wipefs -f -a $(ls /dev/bcache*)
mkfs.btrfs -f -L data -m raid1 -d raid1 /dev/bcache*

mkdir -p /var/share/mnt
mount /dev/bcache0 /var/share/mnt

{ echo; echo '/dev/bcache0  /var/share/mnt  btrfs  nofail  0  2'; } >> /etc/fstab

btrfs subvolume create /var/share/mnt/vms
btrfs subvolume create /var/share/mnt/vms/backup
pvesm add btrfs mass-storage --path /var/share/mnt/vms

btrfs subvolume create /var/share/mnt/net

{ echo "$smb_password"; echo "$smb_password"; } | smbpasswd -a root
pdbedit -u root --set-nt-hash "$smb_password"

cat <<'EOL' > /etc/samba/smb.conf
[smb-net]
    comment = user data network share
    path = /var/share/mnt/net
    read only = no
    inherit owner = yes
    inherit permissions = yes
EOL

mkdir /var/share/mnt/.duperemove

snapper -c data create-config /var/share/mnt/net
snapper -c data set-config "TIMELINE_CREATE=yes" "TIMELINE_CLEANUP=yes" \
"TIMELINE_LIMIT_HOURLY=24" "TIMELINE_LIMIT_DAILY=7" "TIMELINE_LIMIT_WEEKLY=6" \
"TIMELINE_LIMIT_MONTHLY=0" "TIMELINE_LIMIT_YEARLY=0"

snapper -c data setup-quota

{ crontab -l 2>/dev/null
cat <<'EOL'

#@reboot echo 0 | tee /sys/block/bcache*/bcache/sequential_cutoff
0 6 * * 1 duperemove -dhr -b 64K --dedupe-options=same --hash=xxhash --hashfile=/var/share/mnt/.duperemove/hashfile.db /var/share/mnt
0 5 1 * * rm -rf /var/share/mnt/.duperemove/hashfile.db && btrfs filesystem defragment -r /var/share/mnt
0 5 20 * * btrfs scrub start /var/share/mnt
EOL
} | crontab -
