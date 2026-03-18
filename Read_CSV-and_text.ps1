Get-Content
Import-Csv
Read-Host



#Get-Content is a cmdlet in PowerShell that allows you to read the contents of a file and display it in the console. It can be used to read text files, CSV files, and other types of files. For example, if you have a text file called "test.txt" located in the "C:\temp" directory, you can use the following command to read its contents:
Get-Content -Path "C:\temp\test.txt"
$text = Get-content -path c:\temp\test.txt


Get-Content "C:\Logs\application.log" -Tail 20


#Import-Csv is a cmdlet in PowerShell that allows you to read the contents of a CSV file and display it in the console. It can be used to read CSV files and convert them into PowerShell objects. For example, if you have a CSV file called "test.csv" located in the "C:\temp" directory, you can use the following command to read its contents:
Import-Csv -Path "D:\Data\Code\Own_projects\Powershell\mydata.csv" | Format-List
$csvData = Import-Csv -path D:\Data\Code\Own_projects\Powershell\mydata.csv



#read-host is a cmdlet in PowerShell that allows you to prompt the user for input and read their response. It can be used to get input from the user during script execution. For example, you can use the following command to prompt the user for their name and store it in a variable:
$name = Read-Host "Please enter your name"
Write-Host "Hello, $name!"
