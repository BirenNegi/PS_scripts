$LogDirectory = 'C:\BankGhostLogs'
$LogFile      = Join-Path $LogDirectory 'GhostDefense.log'

# Attack detection thresholds
$FailedLogonThreshold     = 3        # Failed logins before activation
$FailedLogonWindowMinutes = 10         # Lookback window
$FailedLogonEventId       = 4625      # Security log failed login
$MalwareEventId           = 1116      # Defender malware detection

# Bank network settings
$InternalNetworkCIDR = '10.0.0.0/8'  # YOUR internal network
$BankDnsServers      = @('10.0.0.10') # YOUR DNS servers

# Names for firewall rules
$BlockInternetRuleName = 'BANK_GHOST_BLOCK_INTERNET'
$AllowInternalRuleName = 'BANK_GHOST_ALLOW_INTERNAL'

$PollIntervalSeconds = 3              # CPU-friendly polling

# =============================================================================
# CORE FUNCTIONS
# =============================================================================

# Logging function (audit trail)
function Write-GhostLog {
    param([string]$Message, [string]$Level = 'INFO')
    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# Sentry: Monitor event logs
function Test-FailedLogonAttack {
    $startTime = (Get-Date).AddMinutes(-$FailedLogonWindowMinutes)
    $filter = @{ LogName = 'Security'; Id = $FailedLogonEventId; StartTime = $startTime }
    $events = Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue
    return ($events | Measure-Object).Count -ge $FailedLogonThreshold
}

function Test-MalwareAttack {
    $startTime = (Get-Date).AddMinutes(-10)
    $filter = @{
        LogName   = 'Microsoft-Windows-Windows Defender/Operational'
        Id        = $MalwareEventId
        StartTime = $startTime
    }
    $events = Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue
    return ($events | Measure-Object).Count -gt 0
}

# Surgical Isolation: Firewall lockdown
function Invoke-SurgicalIsolation {
    Write-GhostLog 'SURGICAL ISOLATION: Blocking Internet, preserving internal network' 'ALERT'

    # Remove existing rules
    Get-NetFirewallRule -DisplayName $AllowInternalRuleName -ErrorAction SilentlyContinue | `
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName $BlockInternetRuleName -ErrorAction SilentlyContinue | `
        Remove-NetFirewallRule -ErrorAction SilentlyContinue

    # Allow internal bank traffic (priority 1)
    New-NetFirewallRule -DisplayName $AllowInternalRuleName -Direction Outbound -Action Allow `
    -RemoteAddress $InternalNetworkCIDR -Profile Any -Enabled True | Out-Null

    # Block Internet (priority 2)
    New-NetFirewallRule -DisplayName $BlockInternetRuleName -Direction Outbound -Action Block `
    -RemoteAddress '0.0.0.0/0' -Profile Any -Enabled True | Out-Null

    Write-GhostLog "Internal network ($InternalNetworkCIDR) preserved. Internet blocked." 'INFO'
}

# Anti-Hijack: DNS Lockdown
function Invoke-DnsLockdown {
    Write-GhostLog "DNS LOCKDOWN: Forcing bank DNS servers: $($BankDnsServers -join ', ')" 'ALERT'

    $adapters = Get-DnsClient | Where-Object {
        $_.InterfaceAlias -notlike '*isatap*' -and $_.InterfaceAlias -notlike '*Teredo*'
    }

    foreach ($adapter in $adapters) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $BankDnsServers
        Write-GhostLog "DNS locked on '$($adapter.InterfaceAlias)' -> $($BankDnsServers -join ', ')" 'INFO'
    }
}

# Hardware Stealth: Disable wireless
function Invoke-HardwareStealth {
    Write-GhostLog 'HARDWARE STEALTH: Disabling Wi-Fi/Bluetooth to stop lateral movement' 'ALERT'

    $patterns = @('*Wi-Fi*', '*Wireless*', '*WLAN*', '*Bluetooth*')
    $adapters = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' }

    foreach ($adapter in $adapters) {
        if ($patterns | Where-Object { $adapter.Name -like $_ }) {
            Disable-NetAdapter -Name $adapter.Name -Confirm:$false
            Write-GhostLog "Disabled wireless adapter: '$($adapter.Name)'" 'INFO'
        }
    }
}

# Ghost Defense Master Function
function Invoke-GhostDefense {
    param([string]$Trigger)

    Write-GhostLog '===============================================================================' 'ALERT'
    Write-GhostLog "GHOST MODE ACTIVATED! Trigger: $Trigger" 'ALERT'
    Write-GhostLog '===============================================================================' 'ALERT'

    Invoke-SurgicalIsolation
    Invoke-DnsLockdown
    Invoke-HardwareStealth

    Write-GhostLog 'FULL GHOST DEFENSE ACTIVE: Laptop isolated but internal banking functional' 'ALERT'
}

# =============================================================================
# MAIN LOOP - ETERNAL SENTRY
# =============================================================================

Write-GhostLog 'Ghost Defense starting... Monitoring Windows 11 event logs continuously'

while ($true) {
    try {
        if (Test-FailedLogonAttack) {
            Invoke-GhostDefense -Trigger "Brute force attack detected (EventID 4625)"
        }
        elseif (Test-MalwareAttack) {
            Invoke-GhostDefense -Trigger "Malware detected by Windows Defender (EventID 1116)"
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
    catch {
        Write-GhostLog "Loop error (continuing): $($_.Exception.Message)" 'ERROR'
        Start-Sleep -Seconds 5
    }
}
