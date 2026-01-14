################################################################################
# Terraform Outputs
# Useful information after provisioning
################################################################################

# =============================================================================
# VPC Outputs
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC"
  value       = scaleway_vpc.main.id
}

output "vpc_name" {
  description = "Name of the VPC"
  value       = scaleway_vpc.main.name
}

output "region" {
  description = "Region of deployment"
  value       = var.region
}

# =============================================================================
# Private Network Outputs
# =============================================================================

output "public_network_id" {
  description = "ID of the public private network"
  value       = scaleway_vpc_private_network.public.id
}

output "cluster_network_id" {
  description = "ID of the cluster private network"
  value       = scaleway_vpc_private_network.cluster.id
}

output "public_network_subnet" {
  description = "Subnet of the public network"
  value       = var.public_network_subnet
}

output "cluster_network_subnet" {
  description = "Subnet of the cluster network"
  value       = var.cluster_network_subnet
}

# =============================================================================
# Server Outputs
# =============================================================================

output "server_ids" {
  description = "IDs of all Elastic Metal servers"
  value       = scaleway_baremetal_server.nodes[*].id
}

output "server_names" {
  description = "Names of all servers"
  value       = local.node_names
}

output "server_details" {
  description = "Detailed server information"
  value = {
    for i, server in scaleway_baremetal_server.nodes : local.node_names[i] => {
      id           = server.id
      name         = server.name
      offer        = server.offer
      scaleway_ip  = local.server_ssh_ips[i]
      public_ip    = local.public_ips[i]
      cluster_ip   = local.cluster_ips[i]
      public_vlan  = try(local.server_vlans[i].public_vlan[0], null)
      cluster_vlan = try(local.server_vlans[i].cluster_vlan[0], null)
    }
  }
}

output "server_private_ips" {
  description = "Private IPs assigned to each server"
  value = {
    for i in range(var.node_count) : local.node_names[i] => {
      public_network  = local.public_ips[i]
      cluster_network = local.cluster_ips[i]
    }
  }
}

# =============================================================================
# QDevice Outputs
# =============================================================================

output "qdevice_id" {
  description = "ID of the QDevice instance"
  value       = var.enable_qdevice ? scaleway_instance_server.qdevice[0].id : null
}

output "qdevice_ip" {
  description = "IP of the QDevice"
  value       = var.enable_qdevice ? var.qdevice_ip : null
}

# =============================================================================
# Connection Information
# =============================================================================

output "ssh_commands" {
  description = "SSH commands to connect to nodes"
  value = {
    for i, server in scaleway_baremetal_server.nodes :
    local.node_names[i] => "ssh root@${[for ip in server.ips : ip.address if ip.version == "IPv4"][0]}"
  }
}

output "proxmox_urls" {
  description = "Proxmox Web UI URLs"
  value = {
    for i, server in scaleway_baremetal_server.nodes :
    local.node_names[i] => "https://${[for ip in server.ips : ip.address if ip.version == "IPv4"][0]}:8006"
  }
}

# =============================================================================
# Configuration Summary
# =============================================================================

output "cluster_summary" {
  description = "Summary of the cluster configuration"
  value = {
    cluster_name    = var.cluster_name
    region          = var.region
    zone            = var.zone
    node_count      = var.node_count
    server_type     = var.server_type
    public_network  = var.public_network_subnet
    cluster_network = var.cluster_network_subnet
    qdevice_enabled = var.enable_qdevice
  }
}

# =============================================================================
# Next Steps
# =============================================================================

output "next_steps" {
  description = "Next steps after Terraform apply"
  sensitive   = true
  value       = <<-EOT

    ============================================================
    Proxmox Ceph HCI Cluster - Infrastructure Deployed!
    ============================================================

    Servers are installing. This takes 10-15 minutes.
    
    Monitor progress:
      scw baremetal server list zone=${var.zone}

    Once status is 'ready':

    OPTION A: Use Ansible (recommended)
    ------------------------------------
    cd ../ansible
    ansible-galaxy install -r requirements.yml
    ansible-playbook playbooks/site.yml

    OPTION B: Manual scripts (legacy)
    ------------------------------------
    1. For EACH node, open Proxmox Web UI:
       ${join("\n       ", [for i in range(var.node_count) : "https://${local.server_ssh_ips[i]}:8006"])}
       Login: root / ${var.service_password}
       Go to: Node > Shell
       Paste content from: cat generated/post-deploy-pve${"{"}N{"}"}.sh

    2. After all nodes are configured:
       ssh root@${local.server_ssh_ips[0]}
       pvecm create ${var.cluster_name}
       
       # On other nodes:
       pvecm add ${local.public_ips[0]}

    ============================================================
  EOT
}

# =============================================================================
# Export for Scripts
# =============================================================================

output "post_deploy_scripts" {
  description = "Generated post-deployment scripts (run via Proxmox Shell)"
  value = {
    for i in range(var.node_count) : local.node_names[i] => {
      proxmox_url = "https://${local.server_ssh_ips[i]}:8006"
      script_path = abspath("${path.root}/generated/post-deploy-pve${i + 1}.sh")
    }
  }
}

output "env_file_path" {
  description = "Path to generated .env file"
  value       = var.generate_env_file ? abspath("${path.root}/../.env.generated") : null
}

output "inventory_file_path" {
  description = "Path to generated Ansible inventory"
  value       = var.generate_inventory ? abspath("${path.root}/../inventory/hosts.ini") : null
}

# =============================================================================
# Custom Partitioning Outputs
# =============================================================================

output "custom_partitioning_enabled" {
  description = "Whether custom partitioning is enabled"
  value       = var.enable_custom_partitioning
}

output "partitioning_schema" {
  description = "Partitioning schema applied to servers"
  value       = var.enable_custom_partitioning ? local.partitioning_schema : null
}

# =============================================================================
# Network Configuration Outputs
# =============================================================================

output "vlan_ids" {
  description = <<-EOT
    VLAN IDs assigned to each server.
    
    NOTE: Scaleway Elastic Metal assigns different VLAN IDs per physical rack.
    Servers on the same Private Network may have different VLAN IDs.
    This is normal behavior and handled automatically by the Ansible playbooks.
  EOT
  value = {
    for i in range(var.node_count) : local.node_names[i] => {
      public_vlan  = try(local.server_vlans[i].public_vlan[0], null)
      cluster_vlan = try(local.server_vlans[i].cluster_vlan[0], null)
    }
  }
}

output "server_public_ips" {
  description = "Public IPv4 addresses of servers (for SSH/Web access)"
  value = {
    for i, server in scaleway_baremetal_server.nodes : local.node_names[i] => 
    try([for ip in server.ips : ip.address if ip.version == "IPv4"][0], null)
  }
}

# =============================================================================
# Ansible Integration Outputs
# =============================================================================

output "ansible_inventory_yaml" {
  description = "Ansible inventory in YAML format"
  value = yamlencode({
    all = {
      children = {
        proxmox = {
          hosts = {
            for i in range(var.node_count) : local.node_names[i] => {
              ansible_host       = local.server_ssh_ips[i]
              pve_cluster_addr0  = local.public_ips[i]
              pve_cluster_addr1  = local.cluster_ips[i]
              ceph_osd_devices   = ["/dev/nvme1n1", "/dev/nvme2n1", "/dev/nvme3n1"]
            }
          }
          vars = {
            ansible_user             = "root"
            ansible_python_interpreter = "/usr/bin/python3"
          }
        }
      }
    }
  })
}

output "ansible_group_vars" {
  description = "Ansible group_vars for proxmox group"
  value = {
    pve_cluster_clustername = var.cluster_name
    public_network          = var.public_network_subnet
    cluster_network         = var.cluster_network_subnet
    public_vlan             = try(local.server_vlans[0].public_vlan[0], "")
    cluster_vlan            = try(local.server_vlans[0].cluster_vlan[0], "")
  }
}

# =============================================================================
# Ceph Configuration Outputs
# =============================================================================

output "ceph_configuration" {
  description = "Ceph storage configuration based on server type"
  value = {
    server_type      = var.server_type
    osd_disks        = local.ceph_osd_disks
    osds_per_node    = length(local.ceph_osd_disks)
    total_osds       = local.total_osds
    pool_size        = local.ceph_pool_size
    pool_min_size    = local.ceph_pool_min_size
    recommended_pgs  = local.total_osds >= 9 ? 128 : (local.total_osds >= 6 ? 64 : 32)
  }
}

# =============================================================================
# Public Gateway Outputs
# =============================================================================

output "public_gateway" {
  description = "Public Gateway information"
  value = var.enable_public_gateway ? {
    enabled      = true
    name         = scaleway_vpc_public_gateway.main[0].name
    id           = scaleway_vpc_public_gateway.main[0].id
    public_ip    = scaleway_vpc_public_gateway_ip.gw_ip[0].address
    type         = var.public_gateway_type
    bastion = {
      enabled = var.enable_ssh_bastion
      host    = scaleway_vpc_public_gateway_ip.gw_ip[0].address
      port    = var.bastion_port
    }
    dhcp_pool = {
      low  = cidrhost(var.public_network_subnet, 100)
      high = cidrhost(var.public_network_subnet, 250)
    }
  } : {
    enabled = false
  }
}

output "bastion_ssh_command" {
  description = "SSH command to connect via bastion to a VM"
  value = var.enable_public_gateway && var.enable_ssh_bastion ? {
    example_vm     = "ssh -J bastion@${scaleway_vpc_public_gateway_ip.gw_ip[0].address}:${var.bastion_port} user@<VM_PRIVATE_IP>"
    proxmox_node_1 = "ssh -J bastion@${scaleway_vpc_public_gateway_ip.gw_ip[0].address}:${var.bastion_port} root@${local.public_ips[0]}"
  } : null
}

output "ssh_public_key" {
  description = "SSH public key that will be injected into servers"
  value       = local.ssh_public_key != "" ? substr(local.ssh_public_key, 0, 50) : "Not configured"
  sensitive   = false
}
