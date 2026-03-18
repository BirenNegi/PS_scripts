#check CPU usage 
Get-WmiObject Win32_Processor | Select-Object Name, LoadPercentage

#check disk space 
Get-WmiObject Win32_LogicalDisk | Select-Object DeviceID, FreeSpace, Size | 

#check memory usage in gb
Get-WmiObject Win32_OperatingSystem | Select-Object TotalVisibleMemorySize, FreePhysicalMemory 

# 


#store password in a variable
$securePass = Read-Host "Enter password" -AsSecureString

#convert secure string to plain text and save to a file
$securePass | ConvertFrom-SecureString | Out-File "C:\secure\password.txt"


$securePass = Get-Content "C:\temp\password.txt" | ConvertTo-SecureString






