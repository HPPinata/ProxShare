# ProxShare
This script creates a BtrFS-SR and SMB share with bcache on the Proxmox host Proxmox.

## Usage:
```
wget https://raw.githubusercontent.com/HPPinata/ProxShare/main/share.bash
cat share.bash #look at the things you download
bash share.bash
```

The script asks for the smb password to use, but is currently hardcoded to format nvme0n1 and all sd* drives.

### SEQ_cutoff:
Set bcache sequential cutoff to different value (4M) temporarily
```
echo $(( 1024 * 4096 )) | tee /sys/block/bcache*/bcache/sequential_cutoff
cat /sys/block/bcache*/bcache/sequential_cutoff
```
