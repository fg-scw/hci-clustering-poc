################################################################################
# Elastic Metal Servers
# Proxmox VE nodes for hyperconverged infrastructure
################################################################################

# =============================================================================
# Elastic Metal Server Option - Private Network
# =============================================================================

data "scaleway_baremetal_option" "private_network" {
  zone = var.zone
  name = "Private Network"
}

# =============================================================================
# Elastic Metal Servers
# =============================================================================

resource "scaleway_baremetal_server" "nodes" {
  count = var.node_count

  name        = local.node_names[count.index]
  zone        = var.zone
  offer       = data.scaleway_baremetal_offer.selected.offer_id
  os          = var.os_id
  ssh_key_ids = var.ssh_key_ids
  tags        = concat(local.common_tags, ["node:${count.index + 1}"])

  # NOTE: cloud_init is NOT supported on Proxmox VE images for Elastic Metal.
  # The user-data is visible in Scaleway console but never delivered to the server.
  # Manual SSH configuration is required after deployment (see README.md).

  # Custom partitioning - uses JSON schema directly
  partitioning = var.enable_custom_partitioning ? jsonencode(local.partitioning_schema) : null

  # Service password for Proxmox web UI (root user)
  service_password = var.service_password

  # Enable Private Network option
  options {
    id = data.scaleway_baremetal_option.private_network.option_id
  }

  # Private network attachments with reserved IPAM IPs
  private_network {
    id          = scaleway_vpc_private_network.public.id
    ipam_ip_ids = [scaleway_ipam_ip.public_ips[count.index].id]
  }

  private_network {
    id          = scaleway_vpc_private_network.cluster.id
    ipam_ip_ids = [scaleway_ipam_ip.cluster_ips[count.index].id]
  }

  # Timeouts for bare metal provisioning
  timeouts {
    create = "45m"
    delete = "15m"
  }

  depends_on = [
    scaleway_vpc_private_network.public,
    scaleway_vpc_private_network.cluster,
    scaleway_ipam_ip.public_ips,
    scaleway_ipam_ip.cluster_ips,
  ]
}

# =============================================================================
# QDevice Instance (Optional - for 2-node clusters)
# =============================================================================

resource "scaleway_instance_server" "qdevice" {
  count = var.enable_qdevice ? 1 : 0

  name  = "${var.cluster_name}-qdevice"
  type  = var.qdevice_type
  image = "debian_bookworm"
  zone  = var.zone
  tags  = concat(local.common_tags, ["role:qdevice"])

  # Attach to public network only
  private_network {
    pn_id = scaleway_vpc_private_network.public.id
  }

  # Cloud-init for QDevice setup
  user_data = {
    cloud-init = <<-EOF
      #cloud-config
      package_update: true
      packages:
        - corosync-qnetd
      runcmd:
        - systemctl enable corosync-qnetd
        - systemctl start corosync-qnetd
    EOF
  }
}
