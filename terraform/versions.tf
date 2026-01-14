################################################################################
# Terraform Configuration
# Provider versions and requirements
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = ">= 2.52.0"  # Required for IPAM mode (v2 API)
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }
}

################################################################################
# Provider Configuration
################################################################################

# Authentication via environment variables (recommended):
#   SCW_ACCESS_KEY
#   SCW_SECRET_KEY
#   SCW_DEFAULT_PROJECT_ID
#   SCW_DEFAULT_REGION
#   SCW_DEFAULT_ZONE
#
# Or configure via 'scw init' which creates ~/.config/scw/config.yaml
#
# The provider will automatically use credentials from:
# 1. Environment variables (SCW_*)
# 2. Active profile in config.yaml
#
# Note: We don't set region/zone in the provider block to avoid
# conflicts with config.yaml. Use variables in resources instead.
provider "scaleway" {}
