# VMware ESXi iSCSI Initiator Configuration

This guide covers connecting VMware ESXi to the Proxmox Ceph iSCSI target.

## Prerequisites

- ESXi 7.0+ or vSphere
- Network connectivity to iSCSI target (172.16.28.0/22)
- iSCSI target configured on Proxmox
- Initiator IQN added to target ACL

## Configuration via vSphere Client

### Step 1: Get Initiator IQN

1. Navigate to **Host → Configure → Storage Adapters**
2. If no iSCSI adapter exists, click **Add Software Adapter** → **Add iSCSI Software Adapter**
3. Click on the iSCSI adapter (vmhba64 or similar)
4. Note the **iSCSI Name** (e.g., `iqn.1998-01.com.vmware:esxi-hostname-abc123`)

### Step 2: Add Initiator to Target ACL

On the Proxmox node:

```bash
INITIATOR="iqn.1998-01.com.vmware:esxi-hostname-abc123"
TARGET="iqn.2025-01.com.scaleway:storage"
CHAP_USER="iscsi-user"
CHAP_PASS="your-secure-password"

# Add ACL entry
targetcli /iscsi/${TARGET}/tpg1/acls create ${INITIATOR}
targetcli /iscsi/${TARGET}/tpg1/acls/${INITIATOR} set auth userid=${CHAP_USER}
targetcli /iscsi/${TARGET}/tpg1/acls/${INITIATOR} set auth password=${CHAP_PASS}

# Save
targetcli saveconfig
```

### Step 3: Configure CHAP Authentication

1. In vSphere, select the iSCSI adapter
2. Click **Properties** or **Edit Settings**
3. Go to **Authentication** section
4. Set:
   - **CHAP**: Use unidirectional CHAP
   - **Name**: `iscsi-user`
   - **Secret**: `your-secure-password`

### Step 4: Add Target Portal

1. Select the iSCSI adapter
2. Go to **Dynamic Discovery** tab
3. Click **Add**
4. Enter:
   - **iSCSI Server**: `172.16.28.2`
   - **Port**: `3260`
5. Click **OK**

### Step 5: Rescan Adapter

1. Click **Rescan Storage**
2. Wait for discovery to complete
3. Verify target appears under **Static Discovery** or **Targets**

### Step 6: Create VMFS Datastore

1. Navigate to **Host → Configure → Storage → Datastores**
2. Click **New Datastore**
3. Select **VMFS**
4. Choose the iSCSI LUN from the list
5. Configure:
   - **Name**: `ceph-iscsi`
   - **VMFS Version**: VMFS 6
   - **Partition Configuration**: Use full disk
6. Complete the wizard

## Configuration via ESXi CLI

```bash
# SSH to ESXi host

# Enable iSCSI software adapter
esxcli iscsi software set --enabled=true

# Get adapter name
esxcli iscsi adapter list
# Note: Usually vmhba64

# Configure CHAP
esxcli iscsi adapter auth chap set \
    --adapter=vmhba64 \
    --direction=uni \
    --authname=iscsi-user \
    --secret=your-secure-password \
    --level=required

# Add target portal
esxcli iscsi adapter discovery sendtarget add \
    --adapter=vmhba64 \
    --address=172.16.28.2:3260

# Rescan
esxcli storage core adapter rescan --adapter=vmhba64

# List discovered targets
esxcli iscsi adapter target list --adapter=vmhba64

# Verify LUN
esxcli storage core device list | grep -A 10 "naa."
```

## Configuration via PowerCLI

```powershell
# Connect to vCenter/ESXi
Connect-VIServer -Server esxi.local -User root -Password xxx

# Get host
$vmhost = Get-VMHost -Name "esxi.local"

# Get iSCSI HBA
$hba = Get-VMHostHba -VMHost $vmhost -Type iScsi | 
    Where-Object { $_.Model -eq "iSCSI Software Adapter" }

# If no adapter, enable it
if (-not $hba) {
    Get-VMHostStorage -VMHost $vmhost | Set-VMHostStorage -SoftwareIScsiEnabled $true
    $hba = Get-VMHostHba -VMHost $vmhost -Type iScsi | 
        Where-Object { $_.Model -eq "iSCSI Software Adapter" }
}

# Configure CHAP authentication
$authSpec = New-Object VMware.Vim.HostInternetScsiHbaAuthenticationProperties
$authSpec.ChapAuthEnabled = $true
$authSpec.ChapName = "iscsi-user"
$authSpec.ChapSecret = "your-secure-password"
$authSpec.ChapAuthenticationType = "chapRequired"

$storageSystem = Get-View $vmhost.ExtensionData.ConfigManager.StorageSystem
$storageSystem.UpdateInternetScsiAuthenticationProperties($hba.Device, $authSpec)

# Add target portal
$target = New-Object VMware.Vim.HostInternetScsiHbaSendTarget
$target.Address = "172.16.28.2"
$target.Port = 3260
$storageSystem.AddInternetScsiSendTargets($hba.Device, @($target))

# Rescan
Get-VMHostStorage -VMHost $vmhost -RescanAllHba -RescanVmfs

# Create datastore
$lunId = (Get-ScsiLun -VMHost $vmhost | Where-Object { $_.CanonicalName -like "naa.*" } | 
    Select-Object -First 1).CanonicalName

New-Datastore -VMHost $vmhost -Name "ceph-iscsi" -Path $lunId -Vmfs -FileSystemVersion 6
```

## Multipathing Configuration

For high availability, connect to all target portals:

### Add Multiple Portals

```bash
# Add all three Proxmox nodes as portals
esxcli iscsi adapter discovery sendtarget add --adapter=vmhba64 --address=172.16.28.2:3260
esxcli iscsi adapter discovery sendtarget add --adapter=vmhba64 --address=172.16.28.3:3260
esxcli iscsi adapter discovery sendtarget add --adapter=vmhba64 --address=172.16.28.4:3260

# Rescan
esxcli storage core adapter rescan --adapter=vmhba64
```

### Configure Path Selection Policy

```bash
# List devices
esxcli storage nmp device list

# Set Round Robin for the iSCSI device
esxcli storage nmp device set --device=naa.xxx --psp=VMW_PSP_RR

# Set I/O operations per path before switching (default 1000)
esxcli storage nmp psp roundrobin deviceconfig set \
    --device=naa.xxx \
    --type=iops \
    --iops=1000
```

### Verify Multipathing

```bash
# Check paths
esxcli storage nmp path list --device=naa.xxx

# Should show multiple paths to the same device
# Each path through different target portal
```

## Performance Tuning

### Queue Depth

```bash
# Increase queue depth for better IOPS
esxcli system module parameters set -m iscsi_vmk -p iscsivmk_LunQDepth=64
```

### Jumbo Frames

1. Ensure VMkernel port for iSCSI traffic has MTU 9000
2. Verify switch and target support jumbo frames

```bash
# Set MTU on VMkernel adapter
esxcli network ip interface set --interface-name=vmk1 --mtu=9000
```

### Delayed ACK

```bash
# Disable delayed ACK for lower latency
esxcli iscsi adapter param set --adapter=vmhba64 --key=DelayedAck --value=false
```

## Troubleshooting

### Check iSCSI Status

```bash
# Adapter status
esxcli iscsi adapter list

# Session status
esxcli iscsi session list

# Connection status
esxcli iscsi session connection list
```

### Common Issues

#### Target Not Discovered

```bash
# Check network connectivity
vmkping 172.16.28.2

# Check firewall
esxcli network firewall ruleset list | grep iscsi
esxcli network firewall ruleset set --ruleset-id=iSCSI --enabled=true

# Check CHAP credentials match target configuration
```

#### Authentication Failed

- Verify CHAP username/password match target ACL
- Check initiator IQN is in target ACL
- Try removing and re-adding portal

#### LUN Not Visible

```bash
# Force rescan
esxcli storage core adapter rescan --adapter=vmhba64

# Check for errors
tail -100 /var/log/vmkernel.log | grep -i iscsi
```

#### Slow Performance

- Enable jumbo frames (MTU 9000)
- Increase queue depth
- Disable delayed ACK
- Use multiple paths with Round Robin

## Best Practices

1. **Dedicated Network**: Use separate VMkernel port for iSCSI traffic
2. **Multipathing**: Configure multiple target portals for HA
3. **Jumbo Frames**: Enable MTU 9000 end-to-end
4. **CHAP**: Always use authentication
5. **Monitoring**: Set up alarms for path failures
6. **Regular Rescans**: After any target-side changes

## References

- [VMware iSCSI SAN Configuration Guide](https://docs.vmware.com/en/VMware-vSphere/7.0/com.vmware.vsphere.storage.doc/GUID-E48A5CD3-B6BD-4D00-BED6-4B8D59D22BE3.html)
- [VMware KB: Configuring iSCSI Multipathing](https://kb.vmware.com/s/article/2038869)
