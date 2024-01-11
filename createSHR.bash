#!/bin/bash

apt update
mkdir install-tmp
mv createSHR.bash install-tmp
cd install-tmp

scp ceph:/etc/ceph/ceph.client.admin.keyring /etc/ceph/ceph.client.admin.keyring
cp /etc/ceph/ceph.client.admin.keyring /root/admin.keyring
scp ceph:/etc/ceph/ceph.conf /etc/ceph/ceph.conf

pvesm add rbd proxblock --monhost "192.168.8.44" --pool proxblock --content images,rootdir --username admin --keyring /root/admin.keyring
mkdir /mnt/cephfs
{ echo; echo ':/prox  /mnt/cephfs  ceph  name=admin,fs=cephfs  0  0'; } >> /etc/fstab
mount -a
rm -rf /mnt/cephfs/*

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
