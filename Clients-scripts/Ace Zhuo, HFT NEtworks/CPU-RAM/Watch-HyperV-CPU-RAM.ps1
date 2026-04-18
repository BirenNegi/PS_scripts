#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://discord(app)?\.com/api/webhooks/.+')]
    [string]$DiscordWebhookUrl,

    [Parameter(Mandatory = $false)]
    [ValidateRange(10, 99)]
    [int]$CpuThresholdPercent = 80,

    [Parameter(Mandatory = $false)]
    [ValidateRange(10, 99)]
    [int]$RamThresholdPercent = 80,

    [Parameter(Mandatory = $false)]
    [int]$BaselineDurationMinutes = 10,

    [Parameter(Mandatory = $false)]
    [int]$SampleIntervalSeconds = 30,

    [Parameter(Mandatory = $false)]
    [int]$AlertCooldownMinutes = 5,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\Scripts\HyperV-CPU-RAM-Monitor.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

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
        [string]$MetricType,
        [double]$CurrentValue,
        [double]$PeakValue,
        [double]$UsagePercent
    )
    $color = if ($MetricType -eq 'CPU') { 15158332 } else { 15844367 }
    $json = @"
{
  "username": "Hyper-V CPU/RAM Monitor",
  "embeds": [{
    "title": "High $MetricType Usage Detected",
    "description": "VM **$VMName** using **$([math]::Round($UsagePercent,1))%** of its $MetricType peak on **$NodeName**.",
    "color": $color,
    "fields": [
      {"name": "VM Name", "value": "$VMName", "inline": true},
      {"name": "Node", "value": "$NodeName", "inline": true},
      {"name": "Metric", "value": "$MetricType", "inline": true},
      {"name": "Current", "value": "$([math]::Round($CurrentValue,1))%", "inline": true},
      {"name": "Peak", "value": "$([math]::Round($PeakValue,1))%", "inline": true},
      {"name": "Threshold", "value": "$(if ($MetricType -eq 'CPU') {$CpuThresholdPercent} else {$RamThresholdPercent})%", "inline": true},
      {"name": "Detected At", "value": "$(Get-Date -Format 'dd MMM yyyy HH:mm:ss')", "inline": false}
    ],
    "footer": {"text": "Hyper-V Monitor - $NodeName"},
    "timestamp": "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))"
  }]
}
"@
    try {
        $null = Invoke-RestMethod -Uri $DiscordWebhookUrl -Method Post -Body $json -ContentType 'application/json' -TimeoutSec 15
        Write-Log "Discord alert sent: $VMName $MetricType at $([math]::Round($UsagePercent,1))% of peak"
    }
    catch {
        Write-Log "Failed to send Discord alert: $_" -Level ERROR
    }
}

function Get-VMCPUAndRAM {
    $vmMap = @{}
    $vmCPUCount = @{}
    try {
        $vms = Get-VM
        foreach ($vm in $vms) {
            $vmMap[$vm.VMId.ToString().ToUpper()] = $vm.Name
            $vmCPUCount[$vm.Name] = (Get-VMProcessor -VMName $vm.Name).Count
        }
    }
    catch {
        Write-Log "Get-VM failed: $_" -Level ERROR
        return $null
    }
    if ($vmMap.Count -eq 0) {
        Write-Log "No VMs found." -Level WARN
        return $null
    }

    # CPU counters
    $cpuSet = Get-Counter -ListSet "Hyper-V Hypervisor Virtual Processor" -ErrorAction SilentlyContinue
    if (-not $cpuSet) {
        Write-Log "CPU counter set missing. CPU monitoring disabled." -Level WARN
        $cpuCounterPath = $null
    } else {
        $cpuCounterPath = $cpuSet.Paths | Where-Object { $_ -like "*% Total Run Time*" } | Select-Object -First 1
        if (-not $cpuCounterPath) {
            $cpuCounterPath = $cpuSet.Paths | Where-Object { $_ -like "*% Guest Run Time*" } | Select-Object -First 1
        }
        if ($cpuCounterPath) {
            Write-Log "Using CPU counter: $cpuCounterPath"
        } else {
            Write-Log "No suitable CPU counter found." -Level WARN
            $cpuCounterPath = $null
        }
    }

    # RAM counters – try to find either Physical/Total or Pressure
    $ramSet = Get-Counter -ListSet "Hyper-V Dynamic Memory VM" -ErrorAction SilentlyContinue
    if (-not $ramSet) {
        $ramSet = Get-Counter -ListSet "Hyper-V Virtual Machine Memory" -ErrorAction SilentlyContinue
    }
    if (-not $ramSet) {
        Write-Log "RAM counter set missing. RAM monitoring disabled." -Level WARN
        $ramPhysPath = $null
        $ramTotalPath = $null
        $ramPressurePath = $null
    } else {
        $ramPhysPath = $ramSet.Paths | Where-Object { $_ -like "*Physical Memory*" } | Select-Object -First 1
        $ramTotalPath = $ramSet.Paths | Where-Object { $_ -like "*Total Visible Memory*" -or $_ -like "*Maximum Memory*" } | Select-Object -First 1
        $ramPressurePath = $ramSet.Paths | Where-Object { $_ -like "*Pressure*" } | Select-Object -First 1

        if ($ramPhysPath -and $ramTotalPath) {
            Write-Log "Using RAM physical: $ramPhysPath"
            Write-Log "Using RAM total: $ramTotalPath"
            $ramMode = "Percent"
        } elseif ($ramPressurePath) {
            Write-Log "Using RAM pressure counter: $ramPressurePath (direct percentage)"
            $ramMode = "Pressure"
        } else {
            Write-Log "No usable RAM counters found. RAM monitoring disabled." -Level WARN
            $ramPhysPath = $null
            $ramTotalPath = $null
            $ramPressurePath = $null
        }
    }

    if (-not $cpuCounterPath -and (-not $ramPhysPath -and -not $ramPressurePath)) {
        Write-Log "No usable counters. Exiting." -Level ERROR
        exit 1
    }

    $counters = @()
    if ($cpuCounterPath) { $counters += $cpuCounterPath }
    if ($ramPhysPath) { $counters += $ramPhysPath; $counters += $ramTotalPath }
    if ($ramPressurePath) { $counters += $ramPressurePath }

    try {
        $samples = Get-Counter -Counter $counters -SampleInterval 2 -MaxSamples 2 -ErrorAction Stop
    }
    catch {
        Write-Log "Get-Counter failed: $_" -Level ERROR
        return $null
    }

    $lastTs = $samples.CounterSamples.Timestamp | Sort-Object | Select-Object -Last 1
    $lastSample = $samples.CounterSamples | Where-Object { $_.Timestamp -eq $lastTs }

    $vmStats = @{}

    # CPU processing
    if ($cpuCounterPath) {
        $cpuSamples = $lastSample | Where-Object { $_.Path -eq $cpuCounterPath }
        foreach ($s in $cpuSamples) {
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
            if (-not $vmStats.ContainsKey($vmName)) { $vmStats[$vmName] = @{ CPUSum=0; CPUCount=0; RAMPercent=0 } }
            $vmStats[$vmName].CPUSum += $s.CookedValue
            $vmStats[$vmName].CPUCount += 1
        }
        foreach ($vmName in $vmStats.Keys) {
            $vcpucount = $vmCPUCount[$vmName]
            if ($vcpucount -gt 0 -and $vmStats[$vmName].CPUCount -eq $vcpucount) {
                $vmStats[$vmName].CPUPercent = [math]::Round($vmStats[$vmName].CPUSum / $vcpucount, 1)
            } else {
                $vmStats[$vmName].CPUPercent = 0
            }
        }
    }

    # RAM processing
    if ($ramPhysPath -and $ramTotalPath) {
        $physSamples = $lastSample | Where-Object { $_.Path -eq $ramPhysPath }
        $totalSamples = $lastSample | Where-Object { $_.Path -eq $ramTotalPath }
        $physMap = @{}
        $totalMap = @{}

        foreach ($s in $physSamples) {
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
            if ($vmName) { $physMap[$vmName] = $s.CookedValue }
        }
        foreach ($s in $totalSamples) {
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
            if ($vmName) { $totalMap[$vmName] = $s.CookedValue }
        }

        foreach ($vmName in $physMap.Keys) {
            if ($totalMap.ContainsKey($vmName) -and $totalMap[$vmName] -gt 0) {
                $percent = ($physMap[$vmName] / $totalMap[$vmName]) * 100
                if (-not $vmStats.ContainsKey($vmName)) { $vmStats[$vmName] = @{ CPUPercent=0 } }
                $vmStats[$vmName].RAMPercent = [math]::Round($percent, 1)
            } else {
                if (-not $vmStats.ContainsKey($vmName)) { $vmStats[$vmName] = @{ CPUPercent=0 } }
                $vmStats[$vmName].RAMPercent = 0
            }
        }
    } elseif ($ramPressurePath) {
        $pressureSamples = $lastSample | Where-Object { $_.Path -eq $ramPressurePath }
        foreach ($s in $pressureSamples) {
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
            if ($vmName) {
                if (-not $vmStats.ContainsKey($vmName)) { $vmStats[$vmName] = @{ CPUPercent=0 } }
                $vmStats[$vmName].RAMPercent = [math]::Round($s.CookedValue, 1)
            }
        }
    }

    return $vmStats
}

# --- Main (same as before, unchanged) ---
Write-Log "============================================="
Write-Log "Hyper-V CPU/RAM Monitor starting on $env:COMPUTERNAME"
Write-Log "CPU Threshold: $CpuThresholdPercent% of peak | RAM Threshold: $RamThresholdPercent% of peak"
Write-Log "Baseline: ${BaselineDurationMinutes}m | Interval: ${SampleIntervalSeconds}s | Cooldown: ${AlertCooldownMinutes}m"
Write-Log "============================================="

$nodeName = $env:COMPUTERNAME
$lastAlertTimeCPU = @{}
$lastAlertTimeRAM = @{}
$vmPeakCPU = @{}
$vmPeakRAM = @{}

$baselineEnd = (Get-Date).AddMinutes($BaselineDurationMinutes)
Write-Log "BASELINE: learning CPU & RAM peaks for $BaselineDurationMinutes minutes..."
while ((Get-Date) -lt $baselineEnd) {
    $vmStats = Get-VMCPUAndRAM
    if ($null -ne $vmStats) {
        foreach ($vmName in $vmStats.Keys) {
            $cpu = if ($vmStats[$vmName].ContainsKey('CPUPercent')) { $vmStats[$vmName].CPUPercent } else { 0 }
            $ram = if ($vmStats[$vmName].ContainsKey('RAMPercent')) { $vmStats[$vmName].RAMPercent } else { 0 }
            if ($cpu -gt 0) {
                if (-not $vmPeakCPU.ContainsKey($vmName)) { $vmPeakCPU[$vmName] = $cpu }
                elseif ($cpu -gt $vmPeakCPU[$vmName]) { $vmPeakCPU[$vmName] = $cpu }
            }
            if ($ram -gt 0) {
                if (-not $vmPeakRAM.ContainsKey($vmName)) { $vmPeakRAM[$vmName] = $ram }
                elseif ($ram -gt $vmPeakRAM[$vmName]) { $vmPeakRAM[$vmName] = $ram }
            }
            Write-Log "BASELINE | $vmName | CPU: $cpu% | RAM: $ram% | Peak CPU: $($vmPeakCPU[$vmName])% | Peak RAM: $($vmPeakRAM[$vmName])%"
        }
    }
    Start-Sleep -Seconds $SampleIntervalSeconds
}

foreach ($vmName in $vmPeakCPU.Keys) {
    if ($vmPeakCPU[$vmName] -lt 10) {
        Write-Log "$vmName CPU peak raised from $($vmPeakCPU[$vmName])% to 10% (floor)"
        $vmPeakCPU[$vmName] = 10
    }
}
foreach ($vmName in $vmPeakRAM.Keys) {
    if ($vmPeakRAM[$vmName] -lt 10) {
        Write-Log "$vmName RAM peak raised from $($vmPeakRAM[$vmName])% to 10% (floor)"
        $vmPeakRAM[$vmName] = 10
    }
}

Write-Log "BASELINE complete. Learned peaks:"
foreach ($vmName in $vmPeakCPU.Keys) {
    $cpuPeak = $vmPeakCPU[$vmName]
    $ramPeak = $vmPeakRAM[$vmName]
    Write-Log "  $vmName : CPU peak $cpuPeak% (alert at $CpuThresholdPercent% = $([math]::Round($cpuPeak * $CpuThresholdPercent / 100, 1))%) | RAM peak $ramPeak% (alert at $RamThresholdPercent% = $([math]::Round($ramPeak * $RamThresholdPercent / 100, 1))%)"
}
Write-Log "Switching to MONITORING mode"
Write-Log "============================================="

while ($true) {
    try {
        $vmStats = Get-VMCPUAndRAM
        if ($null -ne $vmStats) {
            foreach ($vmName in $vmStats.Keys) {
                $cpu = if ($vmStats[$vmName].ContainsKey('CPUPercent')) { $vmStats[$vmName].CPUPercent } else { 0 }
                $ram = if ($vmStats[$vmName].ContainsKey('RAMPercent')) { $vmStats[$vmName].RAMPercent } else { 0 }

                if ($cpu -gt 0 -and $vmPeakCPU.ContainsKey($vmName)) {
                    if ($cpu -gt $vmPeakCPU[$vmName]) {
                        Write-Log "$vmName CPU peak updated: $($vmPeakCPU[$vmName])% -> $cpu%"
                        $vmPeakCPU[$vmName] = $cpu
                    }
                    $cpuUsagePct = ($cpu / $vmPeakCPU[$vmName]) * 100
                } else { $cpuUsagePct = 0 }

                if ($ram -gt 0 -and $vmPeakRAM.ContainsKey($vmName)) {
                    if ($ram -gt $vmPeakRAM[$vmName]) {
                        Write-Log "$vmName RAM peak updated: $($vmPeakRAM[$vmName])% -> $ram%"
                        $vmPeakRAM[$vmName] = $ram
                    }
                    $ramUsagePct = ($ram / $vmPeakRAM[$vmName]) * 100
                } else { $ramUsagePct = 0 }

                Write-Log "$vmName | CPU: $cpu% (peak $($vmPeakCPU[$vmName])%, usage $([math]::Round($cpuUsagePct,1))%) | RAM: $ram% (peak $($vmPeakRAM[$vmName])%, usage $([math]::Round($ramUsagePct,1))%)"

                if ($cpuUsagePct -ge $CpuThresholdPercent) {
                    $now = Get-Date
                    $lastAlert = if ($lastAlertTimeCPU.ContainsKey($vmName)) { $lastAlertTimeCPU[$vmName] } else { [datetime]::MinValue }
                    if (($now - $lastAlert).TotalMinutes -ge $AlertCooldownMinutes) {
                        Write-Log "ALERT: $vmName CPU at $([math]::Round($cpuUsagePct,1))% of peak" -Level WARN
                        Send-DiscordAlert -VMName $vmName -NodeName $nodeName -MetricType 'CPU' -CurrentValue $cpu -PeakValue $vmPeakCPU[$vmName] -UsagePercent $cpuUsagePct
                        $lastAlertTimeCPU[$vmName] = $now
                    }
                    else {
                        $next = [math]::Round($AlertCooldownMinutes - ($now - $lastAlert).TotalMinutes, 1)
                        Write-Log "CPU alert suppressed: $vmName (cooldown ${next}m)" -Level WARN
                    }
                }

                if ($ramUsagePct -ge $RamThresholdPercent) {
                    $now = Get-Date
                    $lastAlert = if ($lastAlertTimeRAM.ContainsKey($vmName)) { $lastAlertTimeRAM[$vmName] } else { [datetime]::MinValue }
                    if (($now - $lastAlert).TotalMinutes -ge $AlertCooldownMinutes) {
                        Write-Log "ALERT: $vmName RAM at $([math]::Round($ramUsagePct,1))% of peak" -Level WARN
                        Send-DiscordAlert -VMName $vmName -NodeName $nodeName -MetricType 'RAM' -CurrentValue $ram -PeakValue $vmPeakRAM[$vmName] -UsagePercent $ramUsagePct
                        $lastAlertTimeRAM[$vmName] = $now
                    }
                    else {
                        $next = [math]::Round($AlertCooldownMinutes - ($now - $lastAlert).TotalMinutes, 1)
                        Write-Log "RAM alert suppressed: $vmName (cooldown ${next}m)" -Level WARN
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