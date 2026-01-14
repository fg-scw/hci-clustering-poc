################################################################################
# Terraform Variables
# All configurable parameters for the Proxmox Ceph HCI infrastructure
################################################################################

# =============================================================================
# Scaleway Configuration
# =============================================================================

variable "region" {
  description = "Scaleway region for resources"
  type        = string
  default     = "fr-par"
}

variable "zone" {
  description = "Scaleway zone for Elastic Metal servers"
  type        = string
  default     = "fr-par-2"
}

variable "project_id" {
  description = "Scaleway project ID (optional, uses default if not set)"
  type        = string
  default     = null
}

# =============================================================================
# Cluster Configuration
# =============================================================================

variable "cluster_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "proxmox-hci"
}

variable "node_count" {
  description = "Number of Elastic Metal nodes (minimum 3 for Ceph)"
  type        = number
  default     = 3

  validation {
    condition     = var.node_count >= 3
    error_message = "Minimum 3 nodes required for Ceph cluster."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = list(string)
  default     = ["proxmox", "ceph", "hci", "terraform"]
}

# =============================================================================
# Elastic Metal Configuration
# =============================================================================

variable "server_type" {
  description = "Elastic Metal server type"
  type        = string
  default     = "EM-L220E-NVME"

  validation {
    condition = contains([
      "EM-L220E-NVME",  # Lithium: 8C AMD EPYC, 64GB, 4x1.92TB NVMe
      "EM-I120E-NVME",  # Iridium: 8C/16T, 64GB, 2x960GB NVMe
      "EM-A315X-SSD",   # Aluminium: 8C, 64GB, 2x1TB SSD
      "EM-A410X-SSD",   # Aluminium: 16C, 128GB, 2x1TB SSD
      "EM-B111X-SATA",  # Beryllium: Entry level
      "EM-B211X-SATA",  # Beryllium: Mid range
      "EM-B311X-SATA",  # Beryllium: High capacity
    ], var.server_type)
    error_message = "Invalid server type. Check Scaleway documentation for available types."
  }
}

# Disk configuration based on server type
# nvme0n1 = OS disk (always)
# Additional disks = Ceph OSDs
variable "ceph_osd_disks" {
  description = "List of disks to use for Ceph OSDs. Auto-detected if empty based on server_type."
  type        = list(string)
  default     = []
}

locals {
  # Auto-detect OSD disks based on server type if not explicitly set
  default_osd_disks = {
    "EM-L220E-NVME"  = ["/dev/nvme1n1", "/dev/nvme2n1", "/dev/nvme3n1"]  # 4 disks: 1 OS + 3 OSD
    "EM-I120E-NVME"  = ["/dev/nvme1n1"]                                   # 2 disks: 1 OS + 1 OSD
    "EM-A315X-SSD"   = ["/dev/sdb"]                                       # 2 disks: 1 OS + 1 OSD
    "EM-A410X-SSD"   = ["/dev/sdb"]                                       # 2 disks: 1 OS + 1 OSD
    "EM-B111X-SATA"  = ["/dev/sdb"]                                       # Varies
    "EM-B211X-SATA"  = ["/dev/sdb", "/dev/sdc"]                          # Varies
    "EM-B311X-SATA"  = ["/dev/sdb", "/dev/sdc", "/dev/sdd"]              # Varies
  }
  
  # Use provided disks or auto-detect
  ceph_osd_disks = length(var.ceph_osd_disks) > 0 ? var.ceph_osd_disks : local.default_osd_disks[var.server_type]
  
  # Calculate total OSDs for Ceph pool sizing
  total_osds = var.node_count * length(local.ceph_osd_disks)
  
  # Determine appropriate Ceph replica settings
  # With 3 nodes × 1 OSD = 3 total OSDs, we can do size=3, min_size=2
  # With 3 nodes × 3 OSDs = 9 total OSDs, same settings work fine
  ceph_pool_size     = min(3, local.total_osds)
  ceph_pool_min_size = local.ceph_pool_size >= 3 ? 2 : 1
}

variable "os_id" {
  description = "Operating system ID for Proxmox VE 8"
  type        = string
  default     = "a5c00c1b-95b1-4c08-8a33-79cc079f9dac"  # Proxmox VE 8 | Debian 12
}

variable "ssh_key_ids" {
  description = "List of SSH key IDs to install on servers"
  type        = list(string)
}

variable "service_password" {
  description = "Password for Proxmox web UI (root user). Must be 8+ chars with uppercase, lowercase, numbers."
  type        = string
  sensitive   = true
  
  validation {
    condition     = length(var.service_password) >= 8
    error_message = "Service password must be at least 8 characters long."
  }
}

# =============================================================================
# Network Configuration
# =============================================================================

variable "public_network_subnet" {
  description = "CIDR for public/client network (Ceph MON, client traffic, iSCSI)"
  type        = string
  default     = "172.16.28.0/22"
}

variable "cluster_network_subnet" {
  description = "CIDR for cluster network (OSD replication)"
  type        = string
  default     = "172.16.36.0/22"
}

variable "public_network_ips" {
  description = "Static IPs for nodes on public network (auto-generated if empty)"
  type        = list(string)
  default     = []
}

variable "cluster_network_ips" {
  description = "Static IPs for nodes on cluster network (auto-generated if empty)"
  type        = list(string)
  default     = []
}

# =============================================================================
# Partitioning Configuration
# =============================================================================

variable "enable_custom_partitioning" {
  description = "Enable custom disk partitioning (OS on nvme0n1, nvme1-3 free for Ceph)"
  type        = bool
  default     = true
}

# =============================================================================
# QDevice Configuration (Optional)
# =============================================================================

variable "enable_qdevice" {
  description = "Deploy a QDevice instance for improved HA quorum"
  type        = bool
  default     = true
}

variable "qdevice_type" {
  description = "Instance type for QDevice"
  type        = string
  default     = "DEV1-S"
}

variable "qdevice_ip" {
  description = "Static IP for QDevice on public network"
  type        = string
  default     = "172.16.28.10"
}

# =============================================================================
# Output Configuration
# =============================================================================

variable "generate_inventory" {
  description = "Generate Ansible inventory file"
  type        = bool
  default     = true
}

variable "generate_env_file" {
  description = "Generate .env file for scripts"
  type        = bool
  default     = true
}

# =============================================================================
# Network Auto-Configuration
# =============================================================================

variable "ssh_private_key_path" {
  description = "Path to SSH private key for Ansible connections (after manual SSH setup)"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "enable_public_gateway" {
  description = "Enable Public Gateway for VMs internet access and SSH bastion"
  type        = bool
  default     = true
}

variable "public_gateway_type" {
  description = "Public Gateway type (VPC-GW-S or VPC-GW-M)"
  type        = string
  default     = "VPC-GW-S"

  validation {
    condition     = contains(["VPC-GW-S", "VPC-GW-M"], var.public_gateway_type)
    error_message = "Gateway type must be VPC-GW-S or VPC-GW-M."
  }
}

variable "enable_ssh_bastion" {
  description = "Enable SSH bastion on Public Gateway"
  type        = bool
  default     = true
}

variable "bastion_port" {
  description = "SSH bastion port"
  type        = number
  default     = 61000
}
