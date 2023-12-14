#!/bin/bash

apt update
mkdir install-tmp
mv createSHR.bash install-tmp
cd install-tmp

set-PASS () {
  local passvar=1; local passvar2=2
  while [ "$passvar" != "$passvar2" ]; do echo "SMB password previously unset or input inconsistent."; \
    read -sp 'Password: ' passvar
    echo
    read -sp 'Confirm: ' passvar2
    echo
  done
  smb_password="$(iconv -f ASCII -t UTF-16LE <(printf $passvar) | openssl dgst -md4 -provider legacy | awk -F '= ' {'print $2'})"
}
set-PASS

create-TEMPLATE () {
  tpID=10001
  vmNAME=microos
  vmDESC="openSUSE MicroOS base template"
  
  qm create $tpID \
  --name $vmNAME --description "$vmDESC" --cores 1 --cpu cputype=host --memory 1024 --balloon 1024 --net0 model=virtio,bridge=vmbr0 --bios ovmf --ostype l26 \
  --machine q35 --scsihw virtio-scsi-single --onboot 0 --cdrom none --agent enabled=1 --boot order=virtio0 --efidisk0 local-btrfs:4,efitype=4m,pre-enrolled-keys=1
  
  curl -O -L https://download.opensuse.org/tumbleweed/appliances/openSUSE-MicroOS.x86_64-kvm-and-xen.qcow2
  
  qm disk import $tpID openSUSE-MicroOS.x86_64-kvm-and-xen.qcow2 local-btrfs
  qm set $tpID --virtio0 local-btrfs:$tpID/vm-$tpID-disk-1.raw,cache=writeback,discard=on,iothread=1
  qm disk resize $tpID virtio0 25G
  
  qm set $tpID --template 1
}
create-TEMPLATE
cd .. && rm -rf install-tmp

apt update && apt full-upgrade -y && apt autopurge -y
apt install -y bcache-tools duperemove parted samba snapper
systemctl enable smb

drive=$(ls /dev/sd*)
cache=( /dev/nvme0n1 /dev/nvme1n1 )

for i in ${cache[@]} ${drive[@]}; do
  parted -s -a optimal $i 'mklabel gpt mkpart primary 0% 100%'
done

for i in ${cache[@]}; do
  make-bcache -C "$i"p1
done
for i in ${drive[@]}; do
  make-bcache -B "$i"1
sleep 1

bcache-super-show /dev/nvme0n1p1 | grep cset.uuid | awk -F ' ' {'print $2'} | tee /sys/block/bcache0/bcache/attach
bcache-super-show /dev/nvme1n1p1 | grep cset.uuid | awk -F ' ' {'print $2'} | tee /sys/block/bcache1/bcache/attach
echo writeback | tee /sys/block/bcache*/bcache/cache_mode
echo 0 | tee /sys/block/bcache*/bcache/writeback_percent

mkfs.btrfs -f -L data -m raid1 -d raid1 $(find /dev/bcache* -maxdepth 0 -type b)

mkdir -p /var/share/mnt
mount /dev/bcache0 /var/share/mnt

{ echo; echo '/dev/bcache0  /var/share/mnt  btrfs  nofail  0  2'; } >> /etc/fstab
fstrim -av

btrfs subvolume create /var/share/mnt/vms
btrfs subvolume create /var/share/mnt/vms/backup
pvesm add btrfs mass-storage --path /var/share/mnt/vms --content iso,vztmpl,images,rootdir

btrfs subvolume create /var/share/mnt/net
mkdir /var/share/mnt/.duperemove

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

snapper -c data create-config /var/share/mnt/net
snapper -c data set-config "TIMELINE_CREATE=yes" "TIMELINE_CLEANUP=yes" \
"TIMELINE_LIMIT_HOURLY=24" "TIMELINE_LIMIT_DAILY=7" "TIMELINE_LIMIT_WEEKLY=6" \
"TIMELINE_LIMIT_MONTHLY=0" "TIMELINE_LIMIT_YEARLY=0"

snapper -c data setup-quota

{ crontab -l 2>/dev/null
cat <<'EOL'

#@reboot echo 0 | tee /sys/block/bcache*/bcache/sequential_cutoff
@reboot echo 0 | tee /sys/block/bcache*/bcache/writeback_percent
0 6 * * 1 duperemove -dhr --dedupe-options=same --hash=xxhash --hashfile=/var/share/mnt/.duperemove/hashfile.db /var/share/mnt
0 5 1 * * rm -rf /var/share/mnt/.duperemove/hashfile.db && btrfs balance start -musage=50 -dusage=50 /var/share/mnt
0 5 15 * * btrfs scrub start /var/share/mnt
EOL
} | crontab -
