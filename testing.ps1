
try
{
Remove-Item c:\temp\test.txt -Recurse -ErrorAction SilentlyContinue

Write-Host "creating a new folder and file" -ForegroundColor Green
}

catch {
    write-host "error occured"
}
$Error[0].Exception.Message | Out-File c:\temp\error.txt
#$error.GetType()


