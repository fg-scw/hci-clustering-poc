# Terraform - Proxmox Ceph HCI on Scaleway

Deploy a 3-node Proxmox + Ceph HCI cluster on Scaleway Elastic Metal.

## Quick Start

```bash
# 1. Configure
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars

# 2. Deploy
terraform init
terraform apply

# 3. Wait for servers (~10-15 min)
scw baremetal server list zone=fr-par-2

# 4. Configure each node via Proxmox Shell
# Open each URL, login, go to Node > Shell, paste script
terraform output post_deploy_scripts

# 5. Create cluster (on pve1)
ssh root@<pve1-scaleway-ip>
pvecm create <cluster-name>

# 6. Join other nodes (on pve2, pve3)
pvecm add <pve1-private-ip>
```

## What Gets Created

| Resource | Count | Description |
|----------|-------|-------------|
| VPC | 1 | Isolated network |
| Private Networks | 2 | Public (vmbr1) + Cluster (vmbr2) |
| IPAM IPs | 6 | 3 public + 3 cluster (reserved) |
| Elastic Metal | 3 | EM-L220E-NVME with Proxmox VE 8 |

## Network Layout

```
┌─────────────────────────────────────────────────────────────┐
│                         VPC                                  │
├─────────────────────────────┬───────────────────────────────┤
│  Public Network (vmbr1)     │  Cluster Network (vmbr2)      │
│  172.16.28.0/22             │  172.16.36.0/22               │
│  VLAN: auto-assigned        │  VLAN: auto-assigned          │
├─────────────────────────────┼───────────────────────────────┤
│  pve1: 172.16.28.10         │  pve1: 172.16.36.10           │
│  pve2: 172.16.28.11         │  pve2: 172.16.36.11           │
│  pve3: 172.16.28.12         │  pve3: 172.16.36.12           │
└─────────────────────────────┴───────────────────────────────┘
```

## Key Outputs

```bash
terraform output server_details      # All server info
terraform output server_private_ips  # IPAM IPs
terraform output proxmox_urls        # Web UI URLs
terraform output post_deploy_scripts # Script paths
terraform output next_steps          # Instructions
```

## Files

```
terraform/
├── main.tf              # Resources
├── variables.tf         # Variables  
├── outputs.tf           # Outputs
├── data.tf              # Data sources
├── versions.tf          # Providers
├── terraform.tfvars.example
└── generated/           # Post-deploy scripts (after apply)
    ├── post-deploy-pve1.sh
    ├── post-deploy-pve2.sh
    └── post-deploy-pve3.sh
```
