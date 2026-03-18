# Powershell Pipeline is a series of commands that are connected together using the pipe operator (|). each pipeline operator sends the results of the precedng command to the next command 

# Get-service & stop-service are in pipeline 
Get-Service -Name "Spooler" | Stop-Service

(Get-Service).GetType()


# Three lines of code is reduced to one line using pipeline
Get-Service -Name "Spooler" | Select-Object Name, Status | Format-Table -AutoSize

$textfilter = Get-ChildItem -Path "C:\temp" 



#real production use cases.
Get-Service | Where-Object {$_.Status -eq "Stopped"} | Start-Service

#Real Use Case Detect failed login attempts suspicious activity Often used in security scripts.
Get-EventLog Security | Where-Object {$_.EntryType -eq "FailureAudit"} | Select TimeGenerated, Message

#deleting old backup files.

Get-childitem D:backups\*.bak | where-object {$_.lastwritetime -lt (get-date).AddDays(-30)} | Remove-Item

