#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Windows iSCSI Initiator Setup

.DESCRIPTION
    This script configures Windows to connect to the Proxmox Ceph iSCSI target:
    - Starts iSCSI service
    - Discovers target
    - Configures CHAP authentication
    - Connects and initializes disk

.PARAMETER TargetPortal
    IP address of the iSCSI target (default: 172.16.28.2)

.PARAMETER TargetPort
    Port of the iSCSI target (default: 3260)

.PARAMETER TargetIQN
    IQN of the iSCSI target

.PARAMETER ChapUsername
    CHAP authentication username

.PARAMETER ChapPassword
    CHAP authentication password (will prompt if not provided)

.PARAMETER DriveLetter
    Drive letter to assign (default: D)

.EXAMPLE
    .\windows-initiator.ps1 -TargetPortal 172.16.28.2 -ChapUsername iscsi-user
#>

param(
    [string]$TargetPortal = "172.16.28.2",
    [int]$TargetPort = 3260,
    [string]$TargetIQN = "iqn.2025-01.com.scaleway:storage",
    [string]$ChapUsername = "iscsi-user",
    [string]$ChapPassword = "",
    [string]$DriveLetter = "D"
)

# =============================================================================
# Functions
# =============================================================================

function Write-Step {
    param([string]$Step, [string]$Message)
    Write-Host "`n[$Step] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Yellow
}

function Write-Failure {
    param([string]$Message)
    Write-Host "  ✗ $Message" -ForegroundColor Red
}

# =============================================================================
# Main Script
# =============================================================================

Write-Host "=== Windows iSCSI Initiator Setup ===" -ForegroundColor Green
Write-Host ""
Write-Host "Configuration:"
Write-Host "  Target Portal: ${TargetPortal}:${TargetPort}"
Write-Host "  Target IQN:    $TargetIQN"
Write-Host "  CHAP Username: $ChapUsername"
Write-Host "  Drive Letter:  ${DriveLetter}:"
Write-Host ""

# Prompt for password if not provided
if ([string]::IsNullOrEmpty($ChapPassword)) {
    $SecurePassword = Read-Host "Enter CHAP password" -AsSecureString
    $ChapPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    )
}

# =============================================================================
# Step 1: Start iSCSI Service
# =============================================================================
Write-Step "1/6" "Starting iSCSI Initiator service..."

try {
    $service = Get-Service -Name msiscsi
    if ($service.Status -ne 'Running') {
        Start-Service msiscsi
        Set-Service msiscsi -StartupType Automatic
    }
    Write-Success "iSCSI service running"
} catch {
    Write-Failure "Failed to start iSCSI service: $_"
    exit 1
}

# Get initiator name
$InitiatorName = (Get-InitiatorPort).NodeAddress
Write-Host "  Initiator Name: $InitiatorName"

# =============================================================================
# Step 2: Clean up existing connections
# =============================================================================
Write-Step "2/6" "Cleaning up existing connections..."

try {
    # Disconnect existing sessions to this target
    Get-IscsiSession | Where-Object { $_.TargetNodeAddress -eq $TargetIQN } | 
        ForEach-Object {
            Write-Host "  Disconnecting existing session..."
            Disconnect-IscsiTarget -SessionIdentifier $_.SessionIdentifier -Confirm:$false
        }
    
    # Remove existing target portal
    Get-IscsiTargetPortal -TargetPortalAddress $TargetPortal -ErrorAction SilentlyContinue | 
        Remove-IscsiTargetPortal -Confirm:$false -ErrorAction SilentlyContinue
    
    Write-Success "Cleanup complete"
} catch {
    Write-Warning "Cleanup had issues (may be normal): $_"
}

# =============================================================================
# Step 3: Add Target Portal
# =============================================================================
Write-Step "3/6" "Adding target portal..."

try {
    New-IscsiTargetPortal -TargetPortalAddress $TargetPortal -TargetPortalPortNumber $TargetPort
    Write-Success "Portal added: ${TargetPortal}:${TargetPort}"
} catch {
    Write-Failure "Failed to add portal: $_"
    exit 1
}

Start-Sleep -Seconds 2

# =============================================================================
# Step 4: Discover and Connect
# =============================================================================
Write-Step "4/6" "Connecting to target..."

try {
    # Get discovered target
    $target = Get-IscsiTarget | Where-Object { $_.NodeAddress -eq $TargetIQN }
    
    if (-not $target) {
        Write-Failure "Target not found: $TargetIQN"
        Write-Host "`nDiscovered targets:"
        Get-IscsiTarget | Format-Table NodeAddress, IsConnected
        exit 1
    }
    
    # Connect with CHAP authentication
    Connect-IscsiTarget -NodeAddress $TargetIQN `
        -TargetPortalAddress $TargetPortal `
        -TargetPortalPortNumber $TargetPort `
        -AuthenticationType ONEWAYCHAP `
        -ChapUsername $ChapUsername `
        -ChapSecret $ChapPassword `
        -IsPersistent $true
    
    Write-Success "Connected to target"
} catch {
    Write-Failure "Failed to connect: $_"
    exit 1
}

Start-Sleep -Seconds 3

# =============================================================================
# Step 5: Initialize Disk
# =============================================================================
Write-Step "5/6" "Initializing disk..."

try {
    # Find new RAW disk
    $rawDisk = Get-Disk | Where-Object { 
        $_.PartitionStyle -eq 'RAW' -and 
        $_.BusType -eq 'iSCSI' -and
        $_.Size -gt 1GB
    } | Select-Object -First 1
    
    if ($rawDisk) {
        Write-Host "  Found disk: $($rawDisk.Number) - $([math]::Round($rawDisk.Size / 1GB, 2)) GB"
        
        # Initialize
        Initialize-Disk -Number $rawDisk.Number -PartitionStyle GPT -Confirm:$false
        Write-Success "Disk initialized"
        
        # Create partition
        $partition = New-Partition -DiskNumber $rawDisk.Number `
            -UseMaximumSize `
            -DriveLetter $DriveLetter
        Write-Success "Partition created"
        
        # Format
        Format-Volume -DriveLetter $DriveLetter `
            -FileSystem NTFS `
            -NewFileSystemLabel "CephStorage" `
            -Confirm:$false `
            -Force | Out-Null
        Write-Success "Volume formatted as NTFS"
        
    } else {
        # Check if already initialized
        $existingDisk = Get-Disk | Where-Object { $_.BusType -eq 'iSCSI' }
        if ($existingDisk) {
            Write-Warning "iSCSI disk already initialized"
            $existingDisk | Format-Table Number, @{N='Size(GB)';E={[math]::Round($_.Size/1GB,2)}}, PartitionStyle
        } else {
            Write-Warning "No iSCSI disk found"
        }
    }
} catch {
    Write-Failure "Failed to initialize disk: $_"
}

# =============================================================================
# Step 6: Verify
# =============================================================================
Write-Step "6/6" "Verifying connection..."

Write-Host ""
Write-Host "iSCSI Sessions:"
Get-IscsiSession | Where-Object { $_.TargetNodeAddress -eq $TargetIQN } | 
    Format-Table SessionIdentifier, TargetNodeAddress, IsConnected, IsPersistent

Write-Host "Disk Configuration:"
Get-Disk | Where-Object { $_.BusType -eq 'iSCSI' } | 
    Format-Table Number, @{N='Size(GB)';E={[math]::Round($_.Size/1GB,2)}}, PartitionStyle, OperationalStatus

Write-Host "Volumes:"
Get-Volume | Where-Object { $_.DriveLetter -eq $DriveLetter } |
    Format-Table DriveLetter, FileSystemLabel, @{N='Size(GB)';E={[math]::Round($_.Size/1GB,2)}}, FileSystem

# =============================================================================
# Complete
# =============================================================================
Write-Host ""
Write-Host "=== iSCSI Setup Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Drive ${DriveLetter}: is ready to use"
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Get-IscsiSession                    # Show sessions"
Write-Host "  Get-IscsiConnection                 # Show connections"
Write-Host "  Get-Disk | Where BusType -eq iSCSI  # Show iSCSI disks"
Write-Host ""
Write-Host "To disconnect:"
Write-Host "  Disconnect-IscsiTarget -NodeAddress $TargetIQN"
Write-Host ""
Write-Host "IMPORTANT: Your initiator name for ACL configuration:"
Write-Host "  $InitiatorName" -ForegroundColor Yellow
