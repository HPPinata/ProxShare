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
  
  wget https://download.opensuse.org/tumbleweed/appliances/openSUSE-MicroOS.x86_64-kvm-and-xen.qcow2
  
  qm disk import $tpID openSUSE-MicroOS.x86_64-kvm-and-xen.qcow2 local-btrfs
  qm set $tpID --virtio0 local-btrfs:$tpID/vm-$tpID-disk-1.raw,cache=writeback,discard=on,iothread=1
  qm disk resize $tpID virtio0 25G
  
  qm set $tpID --template 1
}
create-TEMPLATE

apt update && apt full-upgrade -y && apt autopurge -y
apt install -y duperemove samba snapper

systemctl enable smb

pass=$(ls /dev/sd*)
wipefs -f -a /dev/nvme0n1 ${pass[@]}

pvcreate /dev/nvme0n1 ${pass[@]}
vgcreate data /dev/nvme0n1 ${pass[@]}

lvcreate -n cache -l 100%PV data /dev/nvme0n1
lvcreate -n main -l 96%FREE --type raid1 --raidintegrity y data ${pass[@]}
#lvconvert --type cache --cachevol cache data/main

wipefs -f -a /dev/data/main
mkfs.btrfs -f -L data /dev/data/main

mkdir -p /var/share/mnt
mount /dev/data/main /var/share/mnt

{ echo; echo '/dev/data/main  /var/share/mnt  btrfs  nofail  0  2'; } >> /etc/fstab

btrfs subvolume create /var/share/mnt/vms
btrfs subvolume create /var/share/mnt/vms/backup
pvesm add btrfs mass-storage --path /var/share/mnt/vms --content iso,vztmpl,images,rootdir

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

0 6 * * 1 duperemove -dhr -b 64K --dedupe-options=same --hash=xxhash --hashfile=/var/share/mnt/.duperemove/hashfile.db /var/share/mnt
0 5 1 * * rm -rf /var/share/mnt/.duperemove/hashfile.db && btrfs filesystem defragment -r /var/share/mnt
0 5 20 * * btrfs scrub start /var/share/mnt
EOL
} | crontab -
