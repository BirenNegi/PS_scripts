# Main triger 
.\Install-CPURAMMonitor.ps1 -Action Install `
    -DiscordWebhookUrl "https://discord.com/api/webhooks/123456/abcdef" `
    -CpuThresholdPercent 75 `
    -RamThresholdPercent 80 `
    -BaselineDurationMinutes 10 `
    -SampleIntervalSeconds 30 `
    -AlertCooldownMinutes 5




# Status of task
Stop-ScheduledTask -TaskName "HyperV-CPU-RAM-Monitor"
Start-ScheduledTask -TaskName "HyperV-CPU-RAM-Monitor"
.\Install-CPURAMMonitor.ps1 -Action Status

# view logs

Get-Content C:\Scripts\HyperV-CPU-RAM-Monitor.log -Tail 30 -Wait