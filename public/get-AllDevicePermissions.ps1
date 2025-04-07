Function get-AllDevicePermissions{   
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>         
    Param(
        [Switch]$skipReportGeneration
    )

    Write-LogMessage -message "Starting Device scan..." -level 4

    $global:DevicePermissions = @{}

    New-StatisticsObject -category "Devices" -subject "CloudPCs"
    Write-Progress -Id 1 -PercentComplete 0 -Activity "Scanning Devices" -Status "Getting CloudPCs" 

    [Array]$allCloudPCs = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/virtualEndpoint/cloudPCs' -Method GET
    Write-LogMessage -message "Got $($allCloudPCs.count) cloud PC's"

    Write-Progress -Id 1 -PercentComplete 0 -Activity "Scanning Devices" -Status "Scanning $($allCloudPCs.count) CloudPCs"

    $count = 0
    foreach($cloudPC in $allCloudPCs){
        $percentComplete = try{$count / $allCloudPCs.count * 100} catch {0}
        Write-Progress -Id 2 -PercentComplete $percentComplete -Activity "Scanning CloudPCs" -Status "$count / $($allCloudPCs.count)"
        Update-StatisticsObject -category "Devices" -subject "CloudPCs"
        $permissionsSplat = @{
            targetPath = "/cloudPCs/$($cloudPC.managedDeviceName)"
            targetType = "cloudPC"
            targetId   = $cloudPC.id
            principalEntraId = get-aadObjectId -upn $cloudPC.userPrincipalName
            principalEntraUpn = $cloudPC.userPrincipalName
            principalSysId   = $cloudPC.userPrincipalName
            principalSysName = $cloudPC.userPrincipalName
            principalType    = "#microsoft.graph.user"
            principalRole    = "User"
            modifiedDateTime = $cloudPC.lastModifiedDateTime
            through          = "Direct"
            parentId         = ""
            accessType       = "Allow"
            tenure           = "Permanent"
        }
        New-DevicePermissionEntry @permissionsSplat
    }

    Remove-Variable allCloudPCs -Force -Confirm:$False
    [System.GC]::GetTotalMemory($true) | out-null
    Stop-statisticsObject -category "Devices" -subject "CloudPCs"

    Write-Progress -Id 2 -Completed -Activity "Scanning CloudPCs"

    Write-LogMessage -message "Getting EntraID devices..." -level 4
    Write-Progress -Id 1 -PercentComplete 0 -Activity "Scanning Devices" -Status "Getting Entra devices..."
    [Array]$allEntraDevices = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/devices?$select=displayName,registeredOwners,systemLabels,id,createdDateTime&$expand=registeredOwners' -Method GET
    Write-LogMessage -message "Got $($allEntraDevices.count) EntraID devices"
    Write-Progress -Id 1 -PercentComplete 0 -Activity "Scanning Devices" -Status "Scanning $($allEntraDevices.count) Entra devices..."

    New-StatisticsObject -category "Devices" -subject "Entra"
    $count = 0
    foreach($device in $allEntraDevices){
        if($device.systemLabels -contains "CloudPC"){
            Write-LogMessage -message "Skipping device $($device.displayName) as it is a CloudPC" -level 5
            continue
        }
        $percentComplete = try{$count / $allEntraDevices.count * 100} catch {0}
        Write-Progress -Id 2 -PercentComplete $percentComplete -Activity "Scanning Entra Devices" -Status "$count / $($allEntraDevices.count)"
        Update-StatisticsObject -category "Devices" -subject "Entra"

        $userId = $null
        $userUpn = $null
        $userDisplayName = $null

        if($device.registeredOwners){
            $userId = $device.registeredOwners[0].id
            $userUpn = $device.registeredOwners[0].userPrincipalName
            $userDisplayName = $device.registeredOwners[0].displayName
        }
    
        $permissionsSplat = @{
            targetPath = "/devices/$($device.displayName)"
            targetType = "device"
            targetId   = $device.id
            principalEntraId = $userId
            principalEntraUpn = $userUpn
            principalSysId   = $userUpn
            principalSysName = $userDisplayName
            principalType    = "#microsoft.graph.user"
            principalRole    = "Owner"
            createdDateTime = $device.createdDateTime
            through          = "Direct"
            parentId         = ""
            accessType       = "Allow"
            tenure           = "Permanent"
        }
        New-DevicePermissionEntry @permissionsSplat
    }

    Remove-Variable allEntraDevices -Force -Confirm:$False
    [System.GC]::GetTotalMemory($true) | out-null
    Stop-statisticsObject -category "Devices" -subject "Entra"

    if(!$skipReportGeneration){
        Write-LogMessage -message "Generating report..." -level 4
        Write-Report
    }
}