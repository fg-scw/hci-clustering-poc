#!/bin/bash
################################################################################
# SSH Initial Setup Script for Proxmox VE on Scaleway Elastic Metal
# 
# This script uses sshpass to connect with the service password and:
# - Enable PermitRootLogin with public key
# - Install your SSH public key
# - Restart sshd
#
# Prerequisites:
# - sshpass installed locally (brew install sshpass / apt install sshpass)
# - Terraform outputs available
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    if ! command -v sshpass &> /dev/null; then
        log_error "sshpass is not installed"
        echo "Install with:"
        echo "  macOS:  brew install hudochenkov/sshpass/sshpass"
        echo "  Ubuntu: sudo apt install sshpass"
        echo "  RHEL:   sudo yum install sshpass"
        exit 1
    fi

    if ! command -v terraform &> /dev/null; then
        log_error "terraform is not installed"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed"
        exit 1
    fi
}

# Get values from Terraform
get_terraform_outputs() {
    log_info "Getting Terraform outputs..."
    
    if [ ! -f "terraform.tfstate" ] && [ ! -d ".terraform" ]; then
        log_error "Terraform state not found. Run 'terraform apply' first."
        exit 1
    fi

    # Get server public IPs (Scaleway public IPs, not private network IPs)
    SERVER_PUBLIC_IPS=$(terraform output -json server_public_ips 2>/dev/null | jq -r 'to_entries[] | .value' | tr '\n' ' ')
    
    if [ -z "$SERVER_PUBLIC_IPS" ] || [ "$SERVER_PUBLIC_IPS" == "null " ]; then
        log_error "Could not get server public IPs from Terraform"
        exit 1
    fi

    # Get service password from tfvars
    if [ -f "terraform.tfvars" ]; then
        SERVICE_PASSWORD=$(grep -E '^service_password\s*=' terraform.tfvars | sed 's/.*=\s*"\(.*\)"/\1/' | tr -d '"')
    fi

    if [ -z "$SERVICE_PASSWORD" ]; then
        log_warn "Could not read service_password from terraform.tfvars"
        read -sp "Enter Proxmox service password: " SERVICE_PASSWORD
        echo
    fi

    # Get SSH public key path
    SSH_PRIVATE_KEY=$(grep -E '^ssh_private_key_path\s*=' terraform.tfvars 2>/dev/null | sed 's/.*=\s*"\(.*\)"/\1/' | tr -d '"')
    SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-~/.ssh/id_rsa}"
    SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY/#\~/$HOME}"
    SSH_PUBLIC_KEY="${SSH_PRIVATE_KEY}.pub"

    if [ ! -f "$SSH_PUBLIC_KEY" ]; then
        log_error "SSH public key not found: $SSH_PUBLIC_KEY"
        exit 1
    fi

    PUBLIC_KEY_CONTENT=$(cat "$SSH_PUBLIC_KEY")
    
    log_info "Found ${#SERVER_PUBLIC_IPS[@]} servers"
    log_info "SSH public key: $SSH_PUBLIC_KEY"
}

# Configure SSH on a single server
configure_ssh_on_server() {
    local ip="$1"
    local password="$2"
    local pubkey="$3"

    log_info "Configuring SSH on $ip..."

    # SSH options to skip host key checking
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    # Commands to run on the server
    REMOTE_COMMANDS=$(cat << 'EOFCMD'
# Enable root login with public key
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# Ensure PubkeyAuthentication is enabled
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Ensure AuthorizedKeysFile is set
grep -q "^AuthorizedKeysFile" /etc/ssh/sshd_config || echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config

# Create .ssh directory
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Add public key (avoid duplicates)
PUBKEY="__PUBKEY__"
if ! grep -qF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
    echo "$PUBKEY" >> /root/.ssh/authorized_keys
fi
chmod 600 /root/.ssh/authorized_keys

# Restart SSH
systemctl restart sshd

echo "SSH configured successfully"
EOFCMD
)

    # Replace placeholder with actual public key
    REMOTE_COMMANDS="${REMOTE_COMMANDS//__PUBKEY__/$pubkey}"

    # Execute via sshpass
    if sshpass -p "$password" ssh $SSH_OPTS root@"$ip" "$REMOTE_COMMANDS" 2>&1; then
        log_info "✓ SSH configured on $ip"
        return 0
    else
        log_error "✗ Failed to configure SSH on $ip"
        return 1
    fi
}

# Test SSH key authentication
test_ssh_key_auth() {
    local ip="$1"
    local key="$2"

    log_info "Testing SSH key authentication on $ip..."

    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no -o BatchMode=yes"

    if ssh $SSH_OPTS -i "$key" root@"$ip" "echo 'SSH key auth works'" 2>/dev/null; then
        log_info "✓ SSH key authentication working on $ip"
        return 0
    else
        log_warn "✗ SSH key authentication failed on $ip"
        return 1
    fi
}

# Main
main() {
    echo "========================================"
    echo "Proxmox SSH Initial Setup"
    echo "========================================"
    echo

    check_prerequisites
    get_terraform_outputs

    echo
    log_info "Servers to configure: $SERVER_PUBLIC_IPS"
    echo

    FAILED=0
    for ip in $SERVER_PUBLIC_IPS; do
        [ -z "$ip" ] && continue
        
        echo "----------------------------------------"
        if configure_ssh_on_server "$ip" "$SERVICE_PASSWORD" "$PUBLIC_KEY_CONTENT"; then
            sleep 2
            test_ssh_key_auth "$ip" "$SSH_PRIVATE_KEY" || ((FAILED++))
        else
            ((FAILED++))
        fi
    done

    echo
    echo "========================================"
    if [ $FAILED -eq 0 ]; then
        log_info "All servers configured successfully!"
        echo
        echo "You can now run:"
        echo "  terraform apply  # To configure network (if enable_network_config=true)"
        echo
        echo "Or connect manually:"
        for ip in $SERVER_PUBLIC_IPS; do
            [ -z "$ip" ] && continue
            echo "  ssh root@$ip"
        done
    else
        log_error "$FAILED server(s) failed to configure"
        exit 1
    fi
    echo "========================================"
}

main "$@"
