################################################################################
# Network Configuration
# VPC, Private Networks, and IPAM IP Reservations
################################################################################

# =============================================================================
# VPC
# =============================================================================

resource "scaleway_vpc" "main" {
  name   = "${var.cluster_name}-vpc"
  region = var.region
  tags   = local.common_tags
}

# =============================================================================
# Private Networks
# =============================================================================

# Public Network (Ceph client traffic, MON communication, VM network)
resource "scaleway_vpc_private_network" "public" {
  name   = "${var.cluster_name}-public"
  vpc_id = scaleway_vpc.main.id
  region = var.region
  tags   = concat(local.common_tags, ["network:public"])

  ipv4_subnet {
    subnet = var.public_network_subnet
  }
}

# Cluster Network (OSD replication, recovery - isolated)
resource "scaleway_vpc_private_network" "cluster" {
  name   = "${var.cluster_name}-cluster"
  vpc_id = scaleway_vpc.main.id
  region = var.region
  tags   = concat(local.common_tags, ["network:cluster"])

  ipv4_subnet {
    subnet = var.cluster_network_subnet
  }
}

# =============================================================================
# IPAM IP Reservations
# Reserve IPs before server creation for predictable addressing
# =============================================================================

resource "scaleway_ipam_ip" "public_ips" {
  count = var.node_count

  address = cidrhost(var.public_network_subnet, 10 + count.index)
  
  source {
    private_network_id = scaleway_vpc_private_network.public.id
  }
  
  tags = ["node:${count.index + 1}", "network:public"]
}

resource "scaleway_ipam_ip" "cluster_ips" {
  count = var.node_count

  address = cidrhost(var.cluster_network_subnet, 10 + count.index)
  
  source {
    private_network_id = scaleway_vpc_private_network.cluster.id
  }
  
  tags = ["node:${count.index + 1}", "network:cluster"]
}
