# ProxShare
This script creates a BtrFS-SR and SMB share with bcache on the Proxmox host.

## Usage:
```
curl -O https://raw.githubusercontent.com/HPPinata/ProxShare/main/createSHR.bash
cat createSHR.bash #look at the things you download
bash createSHR.bash
```

The script asks for the smb password to use, but is currently hardcoded to format nvme0n1 and all sd* drives.

### SEQ_cutoff:
Set bcache sequential cutoff to different value (4M) temporarily
```
echo $(( 1024 * 4096 )) | tee /sys/block/bcache*/bcache/sequential_cutoff
cat /sys/block/bcache*/bcache/sequential_cutoff
```
