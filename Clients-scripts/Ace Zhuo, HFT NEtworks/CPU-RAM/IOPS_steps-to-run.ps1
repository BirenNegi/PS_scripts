# 2. Install as a persistent scheduled task
.\Install-IOPSMonitorTask.ps1 `
    -Action Install `
    -DiscordWebhookUrl "https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN" `
    -IOPSThreshold 200 `
    -SampleIntervalSeconds 30 `
    -AlertCooldownMinutes 1


# 3. Check status anytime
.\Install-IOPSMonitorTask.ps1 -Action Status


# 4. Or run it interactively for testing
.\Watch-HyperVIOPS.ps1 -DiscordWebhookUrl "https://discord.com/api/webhooks/..." -IOPSThreshold 500


# Get the live logs 
Get-Content "C:\HyperV-IOPS-Monitor.log" -Wait -Tail 20


## if remote excution issue run this to bypass 
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser

## stop and start task 
Stop-ScheduledTask  -TaskName "HyperV-IOPS-Monitor"
Start-ScheduledTask -TaskName "HyperV-IOPS-Monitor"
Get-ScheduledTask -TaskName "*H*"



### check current assigned value 
Get-ScheduledTask -TaskName "HyperV-IOPS-Monitor" | 
    Select-Object -ExpandProperty Actions | 
    Select-Object -ExpandProperty Arguments




################################ Discord ############################

## check discord if working manualy hit
Invoke-RestMethod -Uri "https://discord.com/api/webhooks/1493927969155186728/Boq-T_zllAo-OhC-eFjyf9FDY9SCVbQKB2GEhazamihKdAhooO1xcq5yq3Vm9ua20WWX" `
    -Method Post `
    -Body '{"content":"test from admin account"}' `
    -ContentType 'application/json'


# See your adapters
Get-NetAdapter | Select Name, Status

# Disable IPv6 on the active adapter (replace "Ethernet" with your adapter name)
Disable-NetAdapterBinding -Name "Ethernet" -ComponentID ms_tcpip6

# Then test again
Test-NetConnection -ComputerName discord.com -Port 443