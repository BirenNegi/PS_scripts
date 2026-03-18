<#Variable is symoblic name given to computer memory location holding a value 

You can create variables in PowerShell using the $ sign followed by the variable name. For example:
$myVariable = "Hello, World!"In this example, we have created a variable called $myVariable and assigned it the value "Hello, World!". You can access the value of the variable by simply using its name:
Write-Output $myVariable This will output "Hello, World!" to the console. You
#>

# Storing numbers 
[int]$num = 10
$num
# num is integer type variable and can only hold whole numbers. 

#if you try to assign a decimal value to an integer variable, it will round the value to the nearest whole number. For example:
[double]$doublevalue = 10.5
$doublevalue

# if you create variable with space in name, you need to enclose it in curly braces and use the variable name with the $ sign. For example:
${Say hello} = "Hello, World!"
${Say hello}


#### Array = if we want to store multiple value in a single variable so we have to use array. An array is a collection of items stored in a single variable. You can create an array in PowerShell using the @() syntax. For example:
[Array]$var = @("Rahul","Rohit","Ramesh")
$var[0]
$var[1]
$var[2]


# hashtable = it is a collection of key-value pairs. You can create a hash table in PowerShell using the @{} syntax. For example:

[hashtable]$hashtable = @{
    name="rahul"
    age=30
    city="Delhi"
}

## Boolean variable = it can hold only two values: $true or $false. You can create a boolean variable in PowerShell by assigning it either $true or $false. For example:
$IsAdmin = $true
$IsAdmin

## Automatic variables = PowerShell has a set of automatic variables that are predefined and provide information about the current state of the PowerShell environment. For example, $Error is an automatic variable that contains an array of error objects that represent the most recent errors that have occurred in the session. the errors. For example:
$PSVersionTable


try {
    Get-Item "C:\nonexistentfile.txt"
}
catch {
    Write-Host "An error occurred: $($_.Exception.Message)"
}

# Prefrence variables = these variables are used to control the behavior of PowerShell. For example, $ErrorActionPreference is a preference variable that determines how PowerShell responds to errors. By default, it is set to "Continue", which means that PowerShell will continue executing the script even if an error occurs. You can change this variable to "Stop" to make PowerShell stop executing the script when an error occurs. For example:
$ErrorActionPreference = "Stop"

try {
    Get-Item "C:\temp\password.txt"
}
catch {
    Write-Host "An error occurred: $($_.Exception.Message)"
}

$ErrorActionPreference = "Stop"
Get-Item "C:\NotExistFile.txt"
Write-Host "Script continues"


# environment variables = these variables are used to store information about the environment in which PowerShell is running. For example, $env:USERNAME is an environment variable that contains the username of the currently logged-in user. You can access environment variables using the $env: prefix. For example:

Write-Host "Current user: $env:USERNAME"
Write-Host "Current path: $env:PATH"
