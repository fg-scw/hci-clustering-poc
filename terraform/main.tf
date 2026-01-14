################################################################################
# Main Terraform Configuration
# Proxmox Ceph HCI on Scaleway Elastic Metal
#
# File structure:
#   - main.tf       : Locals and computed values
#   - variables.tf  : Input variables
#   - network.tf    : VPC, Private Networks, IPAM
#   - servers.tf    : Elastic Metal servers
#   - gateway.tf    : Public Gateway and SSH Bastion
#   - inventory.tf  : Ansible inventory generation
#   - outputs.tf    : Output values
#   - data.tf       : Data sources
#   - versions.tf   : Provider requirements
################################################################################

# =============================================================================
# Local Values
# =============================================================================

locals {
  # Generate node names
  node_names = [for i in range(var.node_count) : "${var.cluster_name}-pve${i + 1}"]

  # Common tags for all resources
  common_tags = concat(var.tags, ["cluster:${var.cluster_name}"])
  
  # Load partitioning schema from JSON file
  partitioning_schema = jsondecode(file("${path.module}/partitioning-schemas.json"))["standard"]
}

# =============================================================================
# Ceph Configuration Locals (defined in variables.tf)
# =============================================================================
# The following locals are defined in variables.tf alongside the ceph_osd_disks variable:
#   - local.default_osd_disks : Default OSD disks per server type
#   - local.ceph_osd_disks    : Final list of OSD disks to use
#   - local.total_osds        : Total number of OSDs across all nodes
#   - local.ceph_pool_size    : Ceph pool replication size
#   - local.ceph_pool_min_size: Ceph pool minimum replication size
