#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Monitors Hyper-V VMs for excessive IOPS using a percentage-based threshold.

.DESCRIPTION
    Instead of a fixed IOPS number, this script learns each VM's peak IOPS during
    a configurable baseline window, then alerts when any VM exceeds X% of its own
    learned peak. This makes the threshold fair across small and large VMs alike.

    Baseline learning phase:
      - Runs for BaselineDurationMinutes at startup
      - Records the highest IOPS seen per VM
      - After learning, switches to monitoring mode

    Monitoring phase:
      - Alerts when: currentIOPS >= (peakIOPS * ThresholdPercent / 100)
      - Cooldown between repeat alerts is enforced per VM

.PARAMETER DiscordWebhookUrl
    Your Discord channel webhook URL.

.PARAMETER ThresholdPercent
    Percentage of each VM's learned peak IOPS that triggers an alert. Default: 80.

.PARAMETER BaselineDurationMinutes
    How many minutes to spend learning each VM's peak IOPS before monitoring. Default: 10.

.PARAMETER SampleIntervalSeconds
    How often (in seconds) to poll counters. Default: 30.

.PARAMETER AlertCooldownMinutes
    Minimum minutes between repeat alerts for the same VM. Default: 1.

.PARAMETER LogPath
    Path to write the rolling log file.

.EXAMPLE
    .\Watch-HyperVIOPS.ps1 -DiscordWebhookUrl "https://discord.com/api/webhooks/..." -ThresholdPercent 80 -BaselineDurationMinutes 10
#>

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

# Force TLS 1.2 and IPv4 for all outbound web requests
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::DnsRefreshTimeout = 0

function Resolve-IPv4 {
    param([string]$Hostname)
    try {
        $ipv4 = [System.Net.Dns]::GetHostAddresses($Hostname) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                Select-Object -First 1
        if ($ipv4) { return $ipv4.ToString() }
    }
    catch {}
    return $null
}

# --- Helpers ------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red    }
        default { Write-Host $line -ForegroundColor Cyan   }
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

    $totalMBps      = [math]::Round($ReadMBps + $WriteMBps, 2)
    $totalIOPSStr   = [math]::Round($TotalIOPS, 0).ToString()
    $readIOPSStr    = [math]::Round($ReadIOPS, 0).ToString()
    $writeIOPSStr   = [math]::Round($WriteIOPS, 0).ToString()
    $peakIOPSStr    = [math]::Round($PeakIOPS, 0).ToString()
    $usagePctStr    = [math]::Round($UsagePercent, 1).ToString()
    $detectedAt     = Get-Date -Format 'dd MMM yyyy HH:mm:ss'
    $utcTimestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    $json = @"
{
  "username": "Hyper-V IOPS Monitor",
  "embeds": [
    {
      "title": "High IOPS Usage Detected",
      "description": "VM **$VMName** is using **$usagePctStr%** of its peak IOPS capacity on node **$NodeName**.",
      "color": 15158332,
      "fields": [
        { "name": "VM Name",        "value": "$VMName",             "inline": true  },
        { "name": "Node",           "value": "$NodeName",           "inline": true  },
        { "name": "Usage %",        "value": "$usagePctStr%",       "inline": true  },
        { "name": "Current IOPS",   "value": "$totalIOPSStr",       "inline": true  },
        { "name": "Peak IOPS",      "value": "$peakIOPSStr",        "inline": true  },
        { "name": "Threshold",      "value": "$ThresholdPercent%",  "inline": true  },
        { "name": "Read IOPS",      "value": "$readIOPSStr",        "inline": true  },
        { "name": "Write IOPS",     "value": "$writeIOPSStr",       "inline": true  },
        { "name": "Throughput",     "value": "$totalMBps MB/s",     "inline": true  },
        { "name": "Detected At",    "value": "$detectedAt",         "inline": false }
      ],
      "footer": { "text": "Hyper-V IOPS Monitor - $NodeName" },
      "timestamp": "$utcTimestamp"
    }
  ]
}
"@

    try {
        $ipv4 = Resolve-IPv4 -Hostname "discord.com"
        if ($ipv4) {
            $targetUrl = $DiscordWebhookUrl -replace "discord\.com", $ipv4
            Write-Log "Resolved discord.com to IPv4: $ipv4"
        }
        else {
            $targetUrl = $DiscordWebhookUrl
            Write-Log "IPv4 resolution failed, using original URL" -Level WARN
        }

        $response = Invoke-RestMethod -Uri $targetUrl `
                                      -Method Post `
                                      -Body $json `
                                      -ContentType 'application/json; charset=utf-8' `
                                      -Headers @{ Host = "discord.com" } `
                                      -TimeoutSec 15
        Write-Log "Discord alert sent for VM: $VMName ($usagePctStr% of peak, $totalIOPSStr IOPS)"
    }
    catch {
        $statusCode = $null
        $errBody    = $null
        try { $statusCode = $_.Exception.Response.StatusCode.value__ } catch {}
        try {
            $stream  = $_.Exception.Response.GetResponseStream()
            $errBody = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
        } catch {}
        Write-Log "Failed to send Discord alert. HTTP $statusCode | $errBody | $_" -Level ERROR
    }
}

function Get-VMIOPSCounters {
    $vmMap = @{}
    try {
        Get-VM | ForEach-Object { $vmMap[$_.VMId.ToString().ToUpper()] = $_.Name }
    }
    catch {
        Write-Log "Get-VM failed - is Hyper-V role installed? Error: $_" -Level ERROR
        return $null
    }

    if ($vmMap.Count -eq 0) {
        Write-Log "No VMs found on this node." -Level WARN
        return $null
    }

    $counterPaths = @(
        '\Hyper-V Virtual Storage Device(*)\Read Operations/Sec'
        '\Hyper-V Virtual Storage Device(*)\Write Operations/Sec'
        '\Hyper-V Virtual Storage Device(*)\Read Bytes/Sec'
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
        Write-Log "Get-Counter returned no samples." -Level WARN
        return $null
    }

    $lastTs     = $samples.CounterSamples.Timestamp | Sort-Object | Select-Object -Last 1
    $lastSample = $samples.CounterSamples | Where-Object { $_.Timestamp -eq $lastTs }

    if ($lastSample.Count -eq 0) {
        Write-Log "No latest counter samples found." -Level WARN
        return $null
    }

    $vmStats = @{}

    foreach ($s in $lastSample) {
        $rawInstance = $s.InstanceName
        $vmName      = $null

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

# --- Main ---------------------------------------------------------------------

Write-Log "============================================="
Write-Log " Hyper-V IOPS Monitor starting"
Write-Log " Node              : $env:COMPUTERNAME"
Write-Log " Threshold         : $ThresholdPercent% of each VM peak"
Write-Log " Baseline window   : $BaselineDurationMinutes minutes"
Write-Log " Poll Interval     : ${SampleIntervalSeconds}s"
Write-Log " Alert Cooldown    : ${AlertCooldownMinutes}m"
Write-Log " Log File          : $LogPath"
Write-Log "============================================="

$nodeName      = $env:COMPUTERNAME
$lastAlertTime = @{}

# Per-VM learned peak IOPS (populated during baseline phase)
$vmPeakIOPS    = @{}

# --- Phase 1: Baseline learning ----------------------------------------------

$baselineEnd = (Get-Date).AddMinutes($BaselineDurationMinutes)
Write-Log "BASELINE PHASE started - learning peak IOPS for $BaselineDurationMinutes minutes..."

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

            Write-Log "BASELINE | VM: $vmName | IOPS: $([math]::Round($totalIOPS,0)) | Peak so far: $([math]::Round($vmPeakIOPS[$vmName],0))"
        }
    }
    Start-Sleep -Seconds $SampleIntervalSeconds
}

# Ensure every VM has a minimum peak of 100 IOPS to avoid divide-by-zero
# or false alerts on VMs that were idle during baseline
foreach ($vmName in $vmPeakIOPS.Keys) {
    if ($vmPeakIOPS[$vmName] -lt 100) {
        Write-Log "VM: $vmName had very low baseline peak ($([math]::Round($vmPeakIOPS[$vmName],0)) IOPS) - setting floor to 100 IOPS"
        $vmPeakIOPS[$vmName] = 100
    }
}

Write-Log "============================================="
Write-Log " BASELINE COMPLETE - learned peaks:"
foreach ($vmName in $vmPeakIOPS.Keys) {
    Write-Log "   $vmName -> peak $([math]::Round($vmPeakIOPS[$vmName],0)) IOPS | alert at $ThresholdPercent% = $([math]::Round($vmPeakIOPS[$vmName] * $ThresholdPercent / 100, 0)) IOPS"
}
Write-Log " Switching to MONITORING mode"
Write-Log "============================================="

# --- Phase 2: Monitoring -----------------------------------------------------

while ($true) {
    try {
        $vmStats = Get-VMIOPSCounters

        if ($null -ne $vmStats) {
            foreach ($vmName in $vmStats.Keys) {
                $stats     = $vmStats[$vmName]
                $totalIOPS = $stats.ReadIOPS + $stats.WriteIOPS
                $readMBps  = [math]::Round($stats.ReadBps  / 1MB, 2)
                $writeMBps = [math]::Round($stats.WriteBps / 1MB, 2)

                # If this VM wasn't seen during baseline, add it now with current IOPS as peak
                if (-not $vmPeakIOPS.ContainsKey($vmName)) {
                    $vmPeakIOPS[$vmName] = [math]::Max($totalIOPS, 100)
                    Write-Log "New VM detected: $vmName - setting initial peak to $([math]::Round($vmPeakIOPS[$vmName],0)) IOPS"
                }

                # Update peak if current exceeds it (VMs can grow over time)
                if ($totalIOPS -gt $vmPeakIOPS[$vmName]) {
                    Write-Log "VM: $vmName - peak updated $([math]::Round($vmPeakIOPS[$vmName],0)) -> $([math]::Round($totalIOPS,0)) IOPS"
                    $vmPeakIOPS[$vmName] = $totalIOPS
                }

                $peakIOPS      = $vmPeakIOPS[$vmName]
                $usagePercent  = ($totalIOPS / $peakIOPS) * 100
                $alertThreshold = $peakIOPS * $ThresholdPercent / 100

                Write-Log "VM: $vmName | IOPS: $([math]::Round($totalIOPS,0)) | Peak: $([math]::Round($peakIOPS,0)) | Usage: $([math]::Round($usagePercent,1))% | Threshold: $ThresholdPercent% ($([math]::Round($alertThreshold,0)) IOPS) | $readMBps MB/s R / $writeMBps MB/s W"

                if ($usagePercent -ge $ThresholdPercent) {
                    $now            = Get-Date
                    $lastAlert      = if ($lastAlertTime.ContainsKey($vmName)) { $lastAlertTime[$vmName] } else { [datetime]::MinValue }
                    $cooldownPassed = ($now - $lastAlert).TotalMinutes -ge $AlertCooldownMinutes

                    if ($cooldownPassed) {
                        Write-Log "THRESHOLD EXCEEDED - VM: $vmName | $([math]::Round($usagePercent,1))% of peak - Sending Discord alert" -Level WARN
                        Send-DiscordAlert -VMName        $vmName `
                                          -NodeName      $nodeName `
                                          -ReadIOPS      $stats.ReadIOPS `
                                          -WriteIOPS     $stats.WriteIOPS `
                                          -TotalIOPS     $totalIOPS `
                                          -ReadMBps      $readMBps `
                                          -WriteMBps     $writeMBps `
                                          -PeakIOPS      $peakIOPS `
                                          -UsagePercent  $usagePercent
                        $lastAlertTime[$vmName] = $now
                    }
                    else {
                        $nextAlert = [math]::Round($AlertCooldownMinutes - ($now - $lastAlert).TotalMinutes, 1)
                        Write-Log "THRESHOLD EXCEEDED - VM: $vmName | Alert suppressed (cooldown, next alert in ${nextAlert}m)" -Level WARN
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
