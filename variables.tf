################################################################################
# Terraform Variables
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
      "EM-L420E-NVME",  # Lithium: 12C AMD EPYC, 128GB, 4x3.84TB NVMe
    ], var.server_type)
    error_message = "Invalid server type. Check Scaleway documentation for available types."
  }
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
  description = "Enable custom disk partitioning schema"
  type        = bool
  default     = true
}

variable "system_disk" {
  description = "Disk to use for OS installation (first NVMe)"
  type        = string
  default     = "/dev/nvme0n1"
}

variable "system_disk_size_gb" {
  description = "Size of system partition in GB"
  type        = number
  default     = 100
}

variable "swap_size_gb" {
  description = "Size of swap partition in GB (0 to disable)"
  type        = number
  default     = 16
}

# =============================================================================
# QDevice Configuration
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

variable "enable_network_config" {
  description = "Automatically configure Private Network VLANs on servers after installation"
  type        = bool
  default     = true
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key for connecting to servers"
  type        = string
  default     = "~/.ssh/id_rsa"
}
