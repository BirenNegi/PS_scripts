#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://discord(app)?\.com/api/webhooks/.+')]
    [string]$DiscordWebhookUrl,

    [Parameter(Mandatory = $false)]
    [ValidateRange(10, 99)]
    [int]$ThresholdPercent = 80,

    [Parameter(Mandatory = $false)]
    [int]$BaselineDurationMinutes = 10,

    [Parameter(Mandatory = $false)]
    [int]$SampleIntervalSeconds = 30,

    [Parameter(Mandatory = $false)]
    [int]$AlertCooldownMinutes = 1,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\Scripts\HyperV-IOPS-Monitor.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::DnsRefreshTimeout = 0

function Resolve-IPv4 {
    param([string]$Hostname)
    try {
        $ipv4 = [System.Net.Dns]::GetHostAddresses($Hostname) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
        if ($ipv4) { return $ipv4.ToString() }
    }
    catch {}
    return $null
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line -ForegroundColor Cyan }
    }
}

function Send-DiscordAlert {
    param(
        [string]$VMName,
        [string]$NodeName,
        [double]$ReadIOPS,
        [double]$WriteIOPS,
        [double]$TotalIOPS,
        [double]$ReadMBps,
        [double]$WriteMBps,
        [double]$PeakIOPS,
        [double]$UsagePercent
    )
    $totalMBps = [math]::Round($ReadMBps + $WriteMBps, 2)
    $json = @"
{
  "username": "Hyper-V IOPS Monitor",
  "embeds": [{
    "title": "High IOPS Usage Detected",
    "description": "VM **$VMName** using **$([math]::Round($UsagePercent,1))%** of peak IOPS on **$NodeName**.",
    "color": 15158332,
    "fields": [
      {"name": "VM Name", "value": "$VMName", "inline": true},
      {"name": "Node", "value": "$NodeName", "inline": true},
      {"name": "Usage %", "value": "$([math]::Round($UsagePercent,1))%", "inline": true},
      {"name": "Current IOPS", "value": "$([math]::Round($TotalIOPS,0))", "inline": true},
      {"name": "Peak IOPS", "value": "$([math]::Round($PeakIOPS,0))", "inline": true},
      {"name": "Threshold", "value": "$ThresholdPercent%", "inline": true},
      {"name": "Read IOPS", "value": "$([math]::Round($ReadIOPS,0))", "inline": true},
      {"name": "Write IOPS", "value": "$([math]::Round($WriteIOPS,0))", "inline": true},
      {"name": "Throughput", "value": "$totalMBps MB/s", "inline": true},
      {"name": "Detected At", "value": "$(Get-Date -Format 'dd MMM yyyy HH:mm:ss')", "inline": false}
    ],
    "footer": {"text": "Hyper-V IOPS Monitor - $NodeName"},
    "timestamp": "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))"
  }]
}
"@
    try {
        $ipv4 = Resolve-IPv4 -Hostname "discord.com"
        $targetUrl = if ($ipv4) { $DiscordWebhookUrl -replace "discord\.com", $ipv4 } else { $DiscordWebhookUrl }
        if ($ipv4) { Write-Log "Resolved discord.com to IPv4: $ipv4" }
        $null = Invoke-RestMethod -Uri $targetUrl -Method Post -Body $json -ContentType 'application/json; charset=utf-8' -Headers @{ Host = "discord.com" } -TimeoutSec 15
        Write-Log "Discord alert sent for VM: $VMName ($([math]::Round($UsagePercent,1))% of peak, $([math]::Round($TotalIOPS,0)) IOPS)"
    }
    catch {
        Write-Log "Failed to send Discord alert: $_" -Level ERROR
    }
}

function Get-VMIOPSCounters {
    $vmMap = @{}
    try {
        Get-VM | ForEach-Object { $vmMap[$_.VMId.ToString().ToUpper()] = $_.Name }
    }
    catch {
        Write-Log "Get-VM failed - Hyper-V role missing? $_" -Level ERROR
        return $null
    }
    if ($vmMap.Count -eq 0) {
        Write-Log "No VMs found on this node." -Level WARN
        return $null
    }

    $counterPaths = @(
        '\Hyper-V Virtual Storage Device(*)\Read Operations/Sec',
        '\Hyper-V Virtual Storage Device(*)\Write Operations/Sec',
        '\Hyper-V Virtual Storage Device(*)\Read Bytes/Sec',
        '\Hyper-V Virtual Storage Device(*)\Write Bytes/Sec'
    )
    try {
        $samples = Get-Counter -Counter $counterPaths -SampleInterval 2 -MaxSamples 2 -ErrorAction Stop
    }
    catch {
        Write-Log "Get-Counter failed: $_" -Level ERROR
        return $null
    }
    if ($samples.CounterSamples.Count -eq 0) {
        Write-Log "No counter samples returned." -Level WARN
        return $null
    }

    $lastTs = $samples.CounterSamples.Timestamp | Sort-Object | Select-Object -Last 1
    $lastSample = $samples.CounterSamples | Where-Object { $_.Timestamp -eq $lastTs }
    if ($lastSample.Count -eq 0) {
        Write-Log "No latest counter samples." -Level WARN
        return $null
    }

    $vmStats = @{}
    foreach ($s in $lastSample) {
        $rawInstance = $s.InstanceName
        $vmName = $null
        if ($rawInstance -match '([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})') {
            $guidKey = $matches[1].ToUpper()
            if ($vmMap.ContainsKey($guidKey)) { $vmName = $vmMap[$guidKey] }
        }
        if (-not $vmName) {
            foreach ($possibleVM in $vmMap.Values | Sort-Object Length -Descending) {
                if ($rawInstance -like "*$possibleVM*") { $vmName = $possibleVM; break }
            }
        }
        if (-not $vmName) { continue }

        if (-not $vmStats.ContainsKey($vmName)) {
            $vmStats[$vmName] = @{ ReadIOPS=0; WriteIOPS=0; ReadBps=0; WriteBps=0 }
        }
        switch -Wildcard ($s.Path) {
            '*Read Operations/Sec'  { $vmStats[$vmName].ReadIOPS  += $s.CookedValue }
            '*Write Operations/Sec' { $vmStats[$vmName].WriteIOPS += $s.CookedValue }
            '*Read Bytes/Sec'       { $vmStats[$vmName].ReadBps   += $s.CookedValue }
            '*Write Bytes/Sec'      { $vmStats[$vmName].WriteBps  += $s.CookedValue }
        }
    }
    return $vmStats
}

# --- Main ---
Write-Log "============================================="
Write-Log " Hyper-V IOPS Monitor starting on $env:COMPUTERNAME"
Write-Log " Threshold: $ThresholdPercent% | Baseline: ${BaselineDurationMinutes}m | Interval: ${SampleIntervalSeconds}s | Cooldown: ${AlertCooldownMinutes}m"
Write-Log "============================================="

$nodeName = $env:COMPUTERNAME
$lastAlertTime = @{}
$vmPeakIOPS = @{}

# Baseline learning phase
$baselineEnd = (Get-Date).AddMinutes($BaselineDurationMinutes)
Write-Log "BASELINE: learning peaks for $BaselineDurationMinutes minutes..."
while ((Get-Date) -lt $baselineEnd) {
    $vmStats = Get-VMIOPSCounters
    if ($null -ne $vmStats) {
        foreach ($vmName in $vmStats.Keys) {
            $totalIOPS = $vmStats[$vmName].ReadIOPS + $vmStats[$vmName].WriteIOPS
            if (-not $vmPeakIOPS.ContainsKey($vmName)) {
                $vmPeakIOPS[$vmName] = $totalIOPS
            }
            elseif ($totalIOPS -gt $vmPeakIOPS[$vmName]) {
                $vmPeakIOPS[$vmName] = $totalIOPS
            }
            Write-Log "BASELINE | $vmName | IOPS: $([math]::Round($totalIOPS,0)) | Peak: $([math]::Round($vmPeakIOPS[$vmName],0))"
        }
    }
    Start-Sleep -Seconds $SampleIntervalSeconds
}

# Enforce minimum peak of 100 IOPS to avoid false alerts on idle VMs
foreach ($vmName in $vmPeakIOPS.Keys) {
    if ($vmPeakIOPS[$vmName] -lt 100) {
        Write-Log "VM $vmName peak raised from $([math]::Round($vmPeakIOPS[$vmName],0)) to 100 IOPS (floor)"
        $vmPeakIOPS[$vmName] = 100
    }
}

Write-Log "BASELINE complete. Learned peaks:"
foreach ($vmName in $vmPeakIOPS.Keys) {
    Write-Log "  $vmName -> peak $([math]::Round($vmPeakIOPS[$vmName],0)) IOPS, alert at $ThresholdPercent% = $([math]::Round($vmPeakIOPS[$vmName] * $ThresholdPercent / 100,0)) IOPS"
}
Write-Log "Switching to MONITORING mode"
Write-Log "============================================="

# Monitoring loop
while ($true) {
    try {
        $vmStats = Get-VMIOPSCounters
        if ($null -ne $vmStats) {
            foreach ($vmName in $vmStats.Keys) {
                $stats = $vmStats[$vmName]
                $totalIOPS = $stats.ReadIOPS + $stats.WriteIOPS
                $readMBps = [math]::Round($stats.ReadBps / 1MB, 2)
                $writeMBps = [math]::Round($stats.WriteBps / 1MB, 2)

                if (-not $vmPeakIOPS.ContainsKey($vmName)) {
                    $vmPeakIOPS[$vmName] = [math]::Max($totalIOPS, 100)
                    Write-Log "New VM $vmName - initial peak set to $([math]::Round($vmPeakIOPS[$vmName],0)) IOPS"
                }
                if ($totalIOPS -gt $vmPeakIOPS[$vmName]) {
                    Write-Log "VM $vmName peak updated: $([math]::Round($vmPeakIOPS[$vmName],0)) -> $([math]::Round($totalIOPS,0)) IOPS"
                    $vmPeakIOPS[$vmName] = $totalIOPS
                }

                $peakIOPS = $vmPeakIOPS[$vmName]
                $usagePercent = ($totalIOPS / $peakIOPS) * 100
                $alertThreshold = $peakIOPS * $ThresholdPercent / 100

                Write-Log "$vmName | IOPS: $([math]::Round($totalIOPS,0)) | Peak: $([math]::Round($peakIOPS,0)) | Usage: $([math]::Round($usagePercent,1))% | Threshold: $ThresholdPercent% ($([math]::Round($alertThreshold,0)) IOPS) | R: $readMBps MB/s | W: $writeMBps MB/s"

                if ($usagePercent -ge $ThresholdPercent) {
                    $now = Get-Date
                    $lastAlert = if ($lastAlertTime.ContainsKey($vmName)) { $lastAlertTime[$vmName] } else { [datetime]::MinValue }
                    if (($now - $lastAlert).TotalMinutes -ge $AlertCooldownMinutes) {
                        Write-Log "ALERT: $vmName at $([math]::Round($usagePercent,1))% of peak - sending Discord notification" -Level WARN
                        Send-DiscordAlert -VMName $vmName -NodeName $nodeName -ReadIOPS $stats.ReadIOPS -WriteIOPS $stats.WriteIOPS -TotalIOPS $totalIOPS -ReadMBps $readMBps -WriteMBps $writeMBps -PeakIOPS $peakIOPS -UsagePercent $usagePercent
                        $lastAlertTime[$vmName] = $now
                    }
                    else {
                        $nextAlert = [math]::Round($AlertCooldownMinutes - ($now - $lastAlert).TotalMinutes, 1)
                        Write-Log "ALERT suppressed: $vmName (cooldown, next in ${nextAlert}m)" -Level WARN
                    }
                }
            }
        }
    }
    catch {
        Write-Log "Unexpected error in main loop: $_" -Level ERROR
    }
    Start-Sleep -Seconds $SampleIntervalSeconds
}