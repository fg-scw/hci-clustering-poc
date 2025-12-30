# Terraform Configuration

This directory contains Terraform configuration to automatically provision the Scaleway infrastructure for Proxmox + Ceph HCI cluster.

## What Gets Created

| Resource | Count | Description |
|----------|-------|-------------|
| VPC | 1 | Virtual Private Cloud for network isolation |
| Private Networks | 2 | Public (client) and Cluster (replication) networks |
| Elastic Metal Servers | 3+ | EM-L220E-NVME by default |
| Instance | 1 | QDevice for HA quorum (optional) |

## Prerequisites

### Required

1. **Terraform** >= 1.5.0
   ```bash
   # macOS
   brew install terraform
   
   # Linux
   curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
   sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
   sudo apt-get update && sudo apt-get install terraform
   ```

2. **Scaleway Account** with:
   - API credentials (Access Key + Secret Key)
   - Elastic Metal quota (contact support if needed)
   - SSH key uploaded

3. **sshpass** (required for initial SSH setup)
   ```bash
   # macOS
   brew install hudochenkov/sshpass/sshpass
   
   # Ubuntu/Debian
   sudo apt install sshpass
   
   # RHEL/CentOS
   sudo yum install sshpass
   ```

### Recommended

4. **Scaleway CLI** for helper commands
   ```bash
   # macOS
   brew install scw
   
   # Linux
   curl -s https://raw.githubusercontent.com/scaleway/scaleway-cli/master/scripts/get.sh | sh
   
   # Configure
   scw init
   ```

## Quick Start

### 1. Configure Credentials

```bash
# Option 1: Scaleway CLI config (recommended)
scw init

# Option 2: Environment variables
export SCW_ACCESS_KEY="your-access-key"
export SCW_SECRET_KEY="your-secret-key"
export SCW_DEFAULT_PROJECT_ID="your-project-id"
```

### 2. Get SSH Key ID

```bash
scw iam ssh-key list
```

### 3. Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
```

Key variables:
```hcl
# Required
ssh_key_ids      = ["xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"]
service_password = "YourSecurePassword123!"  # For Proxmox web UI

# Optional
cluster_name = "proxmox-hci"
node_count   = 3
server_type  = "EM-L220E-NVME"
```

### 4. Deploy Infrastructure

```bash
# Initialize
terraform init

# Preview
terraform plan

# Deploy (creates servers with custom partitioning)
terraform apply
```

### 5. Setup SSH Access

Proxmox VE doesn't allow SSH key auth by default. Run the setup script:

```bash
# This uses sshpass with service_password to enable SSH key auth
./setup-ssh.sh
```

### 6. Configure Network (Automatic)

If `enable_network_config = true`, Terraform will automatically:
- Retrieve VLAN IDs from Scaleway API
- Get auto-assigned IPAM IPs
- Configure network interfaces on each node

```bash
# Re-apply to trigger network configuration
terraform apply
```

### 7. Access Proxmox

```bash
# Get server IPs and URLs
terraform output server_public_ips
terraform output proxmox_urls

# SSH to nodes
ssh root@<server-ip>

# Web UI
https://<server-ip>:8006
# Username: root
# Password: <service_password from terraform.tfvars>
```

## Deployment Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│                    terraform apply                               │
├─────────────────────────────────────────────────────────────────┤
│ 1. Create VPC + Private Networks                                │
│ 2. Create Elastic Metal servers with custom partitioning        │
│ 3. Wait for OS installation (~15 min)                           │
│ 4. Fetch IPAM-assigned IPs                                      │
│ 5. Generate network config scripts                              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    ./setup-ssh.sh                                │
├─────────────────────────────────────────────────────────────────┤
│ Uses sshpass + service_password to:                             │
│ - Enable PermitRootLogin prohibit-password                      │
│ - Install SSH public key                                        │
│ - Restart sshd                                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              terraform apply (re-run)                            │
├─────────────────────────────────────────────────────────────────┤
│ Now with SSH key working:                                       │
│ - Upload network config scripts                                  │
│ - Configure VLANs, bridges, IPs                                 │
│ - Update /etc/hosts                                             │
└─────────────────────────────────────────────────────────────────┘
```

## Configuration Options

### Server Types

| Type | CPU | RAM | Storage | Use Case |
|------|-----|-----|---------|----------|
| `EM-L220E-NVME` | 8C AMD EPYC | 64 GB | 4×1.92TB NVMe | **Recommended** |
| `EM-A315X-SSD` | 8C | 64 GB | 2×1TB SSD | Budget |
| `EM-A410X-SSD` | 16C | 128 GB | 2×1TB SSD | High compute |

### Partitioning Modes

| Mode | Root | Swap | OSD Disks | Description |
|------|------|------|-----------|-------------|
| `standard` | All nvme0 | 16 GB | nvme1-3 | OS uses full first disk |
| `minimal` | 100 GB | 8 GB | nvme0p5 + nvme1-3 | More space for OSDs |
| `with_local_lvm` | 100 GB | 16 GB | nvme1-3 | Extra partition for local-lvm |
| `ceph_only` | 50 GB | 8 GB | nvme0p5 + nvme1-3 | Maximum OSD space |

### Network Configuration

IPs are auto-assigned by Scaleway IPAM. View assigned IPs:

```bash
terraform output server_private_ips
```

Output example:
```
server_private_ips = {
  "proxmox-hci-pve1" = {
    "cluster_network" = "172.16.36.5"
    "public_network" = "172.16.28.12"
  }
  ...
}
```

## File Structure

```
terraform/
├── main.tf                   # Main resources (VPC, servers, network config)
├── variables.tf              # Input variables
├── outputs.tf                # Output values
├── data.tf                   # Data sources
├── versions.tf               # Provider versions
├── partitioning-schemas.json # Disk partitioning definitions
├── terraform.tfvars.example  # Example configuration
├── setup-ssh.sh              # SSH initial setup script (sshpass)
├── templates/
│   └── configure-network.sh.tpl  # Network config template
└── generated/                # Generated scripts (gitignored)
```

## Outputs

```bash
# All outputs
terraform output

# Specific outputs
terraform output server_public_ips     # Scaleway public IPs (for SSH)
terraform output server_private_ips    # IPAM-assigned private IPs
terraform output vlan_ids              # VLAN IDs per server
terraform output proxmox_urls          # Web UI URLs
```

## Troubleshooting

### SSH Connection Failed

```bash
# 1. Check if servers are ready
scw baremetal server list zone=fr-par-2

# 2. Run SSH setup script
./setup-ssh.sh

# 3. Test SSH
ssh root@<server-ip>
```

### Network Configuration Failed

```bash
# Check if sshpass is installed
which sshpass

# Manual configuration
ssh root@<server-ip>
cat /tmp/configure-network.sh  # Script uploaded by Terraform
/tmp/configure-network.sh      # Run manually
```

### IPAM IPs Not Retrieved

```bash
# Check IPAM IPs via API
scw ipam ip list region=fr-par

# Or via Terraform
terraform refresh
terraform output server_private_ips
```

## Cost Estimation

| Resource | Quantity | Est. Monthly (EUR) |
|----------|----------|-------------------|
| EM-L220E-NVME | 3 | ~1,350 |
| Private Networks | 2 | Free |
| QDevice (DEV1-S) | 1 | ~3 |
| **Total** | | **~1,353** |

## Next Steps

After Terraform completes:

1. [Create Proxmox cluster](../scripts/proxmox/02-create-cluster.sh)
2. [Install Ceph](../scripts/proxmox/03-install-ceph.sh)
3. [Configure QDevice](../scripts/proxmox/04-configure-qdevice.sh) (optional)
4. [Setup iSCSI](../scripts/iscsi/setup-target.sh) (optional)
