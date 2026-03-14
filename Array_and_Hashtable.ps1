<# ##### Array 

In PowerShell, an array stores multiple values in a single variable. In real production environments
 (DevOps, System Admin, MSP work like you do), arrays are commonly used to process multiple servers, 
 users, files, or URLs in automation scripts.

 #>

#Basic Array Example
$Servers = @("Server01","Server02","Server03")

foreach ($Server in $Servers) {
    Write-Host "Checking $Server"
}



$Servers = @("google.com","facebook.com","fast.com")

foreach ($Server in $Servers) {
    Test-Connection $Server -Count 1 
}



#Service Management on Multiple Servers

$Servers = @("App01","App02","App03")

foreach ($server in $Servers) {
    Get-Service -ComputerName $server -Name "Spooler"

}


#5. User Management (Active Directory)
$Users = @("user1","user2","user3")

foreach ($user in $Users) {
    Disable-ADAccount -Identity $user
}



# Stopping multile VMs

$vms = @("Ubuntuvm01", "WindowsVM02", "Centos03")
 
 foreach ($vm in $vms ) {
 
 Stop-AzVM -name $vm -resourcegroup 
 }


 #7. Array with Numbers

 $Numbers = @(10,20,30,40)

$Numbers[0]


#Example: Ping multiple client servers

$Servers = @("DC01","SQL01","WEB01")

foreach ($Server in $Servers) {
    if(Test-Connection $Server -Count 1 -Quiet){
        Write-Host "$Server is Online"
    }
    else{
        Write-Host "$Server is Down"
    }
}





########### Hastable 

###Configuration

$config = @{
    Server = "web01"
    Port   = 443
    Env    = "Production"
}

Write-Host "Connecting to $($config.server) on port $($config.port)"


#Passing Parameters to Cmdlets > Azure provisioing 

$params = @{
    Name = "TestVM"
    ResourceGroupName = "ProdRG"
    Location = "EastUS"
}

New-AzVM @params


#Storing User Information

$user = @{
    Name = "Birendra"
    Department = "IT"
    AccessLevel = "Admin"
}

Write-Host "$($user.Name) from $($user.Department) and his access level is $($user.AccessLevel) "



#Building Custom Objects

$result = @{
    Server = "web01"
    Status = "Online"
    CPU    = "40%"
}

[PSCustomObject]$result

 
#Real Example (Production Monitoring Script)

$servers = @{
    web01 = "10.0.0.5"
    web02 = "10.0.0.6"
    db01  = "10.0.0.10"
}

foreach ($server in $servers.Keys) {
    Test-Connection $servers[$server] -Count 1
}


$checkactiveshare = @{
    $url 
}
