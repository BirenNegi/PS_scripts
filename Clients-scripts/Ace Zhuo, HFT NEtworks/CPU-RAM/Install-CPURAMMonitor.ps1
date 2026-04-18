#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Remove', 'Status')]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [string]$DiscordWebhookUrl = '',

    [Parameter(Mandatory = $false)]
    [int]$CpuThresholdPercent = 80,

    [Parameter(Mandatory = $false)]
    [int]$RamThresholdPercent = 80,

    [Parameter(Mandatory = $false)]
    [int]$BaselineDurationMinutes = 10,

    [Parameter(Mandatory = $false)]
    [int]$SampleIntervalSeconds = 30,

    [Parameter(Mandatory = $false)]
    [int]$AlertCooldownMinutes = 5,

    [Parameter(Mandatory = $false)]
    [string]$ScriptPath = "$PSScriptRoot\Watch-HyperV-CPU-RAM.ps1"
)

$TaskName = 'HyperV-CPU-RAM-Monitor'

if ($Action -eq 'Status') {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host "`n Scheduled Task : $TaskName" -ForegroundColor Cyan
        Write-Host " State          : $($task.State)"
        Write-Host " Last Run       : $($info.LastRunTime)"
        Write-Host " Last Result    : $($info.LastTaskResult)"
        Write-Host " Next Run       : $($info.NextRunTime)`n"
    }
    else {
        Write-Host " Task '$TaskName' not installed." -ForegroundColor Yellow
    }
}

if ($Action -eq 'Remove') {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host " Task '$TaskName' removed." -ForegroundColor Green
    }
    else {
        Write-Host " Task '$TaskName' not found." -ForegroundColor Yellow
    }
}

if ($Action -eq 'Install') {
    if (-not $DiscordWebhookUrl) {
        Write-Error "DiscordWebhookUrl is required for Install."
        exit 1
    }
    if (-not (Test-Path $ScriptPath)) {
        Write-Error "Script not found at: $ScriptPath"
        exit 1
    }

    $psArgs = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" +
              " -DiscordWebhookUrl `"$DiscordWebhookUrl`"" +
              " -CpuThresholdPercent $CpuThresholdPercent" +
              " -RamThresholdPercent $RamThresholdPercent" +
              " -BaselineDurationMinutes $BaselineDurationMinutes" +
              " -SampleIntervalSeconds $SampleIntervalSeconds" +
              " -AlertCooldownMinutes $AlertCooldownMinutes"

    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
        -RestartCount 5 `
        -RestartInterval (New-TimeSpan -Minutes 2) `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger -Settings $settings -Principal $principal -Description "Hyper-V CPU/RAM Adaptive Monitor" | Out-Null

    Write-Host "`n Task '$TaskName' installed successfully." -ForegroundColor Green
    Write-Host " Runs as    : SYSTEM"
    Write-Host " Trigger    : At system startup"
    Write-Host " Script     : $ScriptPath"
    Write-Host " CPU Threshold : $CpuThresholdPercent% of each VM's CPU peak"
    Write-Host " RAM Threshold : $RamThresholdPercent% of each VM's RAM peak"
    Write-Host " Interval   : $SampleIntervalSeconds seconds`n"
    Write-Host " Starting task now..." -ForegroundColor Cyan

    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
    Write-Host " Task state : $( (Get-ScheduledTask -TaskName $TaskName).State )`n" -ForegroundColor Green
}