################################################################################
# Public Gateway Configuration (IPAM Mode - v2 API)
# NAT for VM internet access + SSH Bastion
#
# Note: DHCP is now managed by Scaleway IPAM via the Private Network.
# The legacy scaleway_vpc_public_gateway_dhcp resource is deprecated.
################################################################################

# =============================================================================
# Public Gateway IP
# =============================================================================

resource "scaleway_vpc_public_gateway_ip" "main" {
  count = var.enable_public_gateway ? 1 : 0
  
  zone = var.zone
  tags = concat(local.common_tags, ["role:gateway"])
}

# =============================================================================
# Public Gateway
# =============================================================================

resource "scaleway_vpc_public_gateway" "main" {
  count = var.enable_public_gateway ? 1 : 0

  name            = "${var.cluster_name}-gateway"
  type            = var.public_gateway_type
  zone            = var.zone
  ip_id           = scaleway_vpc_public_gateway_ip.main[0].id
  bastion_enabled = var.enable_ssh_bastion
  bastion_port    = var.bastion_port
  tags            = concat(local.common_tags, ["role:gateway"])
}

# =============================================================================
# Gateway Network Attachment (IPAM Mode)
# Connects gateway to public network with NAT (masquerade)
#
# DHCP is automatically provided by Scaleway IPAM on the Private Network.
# VMs attached to the Private Network will receive IPs via DHCP from IPAM.
# =============================================================================

resource "scaleway_vpc_gateway_network" "main" {
  count = var.enable_public_gateway ? 1 : 0

  gateway_id         = scaleway_vpc_public_gateway.main[0].id
  private_network_id = scaleway_vpc_private_network.public.id
  enable_masquerade  = true  # NAT for internet access
  zone               = var.zone

  # IPAM configuration (replaces legacy DHCP resource)
  ipam_config {
    push_default_route = true  # VMs get default route via gateway
  }

  depends_on = [
    scaleway_vpc_public_gateway.main,
    scaleway_vpc_private_network.public
  ]
}
