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

    $activity = "Scanning Devices"
    New-StatisticsObject -category "Devices" -subject "CloudPCs"
    Write-Progress -Id 1 -PercentComplete 0 -Activity $activity -Status "Getting CloudPCs" 

    try{
        [Array]$allCloudPCs = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/deviceManagement/virtualEndpoint/cloudPCs" -Method GET
    }catch{
        Write-Error $_ -ErrorAction Continue
        $allCloudPCs = @()
    }
    Write-LogMessage -message "Got $($allCloudPCs.count) cloud PC's"

    Write-Progress -Id 1 -PercentComplete 0 -Activity $activity -Status "Scanning $($allCloudPCs.count) CloudPCs"

    $count = 0
    foreach($cloudPC in $allCloudPCs){
        $count++
        $percentComplete = try{$count / $allCloudPCs.count * 100} catch {0}
        Write-Progress -Id 2 -PercentComplete $percentComplete -Activity "Scanning CloudPCs" -Status "$count / $($allCloudPCs.count)"
        Update-StatisticsObject -category "Devices" -subject "CloudPCs"
        $aadObj = get-aadObject -id $cloudPC.userPrincipalName
        $permissionsSplat = @{
            targetPath = "/cloudPCs/$($cloudPC.managedDeviceName)"
            targetType = "cloudPC"
            targetId   = $cloudPC.id
            principalEntraId = $aadObj.id
            principalEntraUpn = $cloudPC.userPrincipalName
            principalSysId   = $aadObj.userPrincipalName
            principalSysName = $aadObj.displayName
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
    Write-Progress -Id 1 -PercentComplete 0 -Activity $activity -Status "Getting Entra devices..."
    [Array]$allEntraDevices = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/devices?`$select=displayName,registeredOwners,systemLabels,id,createdDateTime&`$expand=registeredOwners" -Method GET
    Write-LogMessage -message "Got $($allEntraDevices.count) EntraID devices"
    Write-Progress -Id 1 -PercentComplete 0 -Activity $activity -Status "Scanning $($allEntraDevices.count) Entra devices..."

    New-StatisticsObject -category "Devices" -subject "Entra"
    $count = 0
    foreach($device in $allEntraDevices){
        $count++
        if($device.systemLabels -contains "CloudPC"){
            Write-LogMessage -message "Skipping device $($device.displayName) as it is a CloudPC" -level 5
            continue
        }
        $percentComplete = try{$count / $allEntraDevices.count * 100} catch {0}
        Write-Progress -Id 2 -PercentComplete $percentComplete -Activity "Scanning Entra Devices" -Status "$count / $($allEntraDevices.count)"
        Update-StatisticsObject -category "Devices" -subject "Entra"

        if($device.registeredOwners){
            $aadObj = get-aadObject -id $device.registeredOwners[0].id
        }elseif($device."registeredOwners@delta"){
            $aadObj = get-aadObject -id $device."registeredOwners@delta"[0].id
        }
    
        $permissionsSplat = @{
            targetPath = "/devices/$($device.displayName)"
            targetType = "device"
            targetId   = $device.id
            principalEntraId = $aadObj.id
            principalEntraUpn = $aadObj.userPrincipalName
            principalSysId   = $aadObj.userPrincipalName
            principalSysName = $aadObj.displayName
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

     Write-Progress -Id 2 -Completed -Activity "Scanning Entra Devices"

    Remove-Variable allEntraDevices -Force -Confirm:$False
    [System.GC]::GetTotalMemory($true) | out-null
    Stop-statisticsObject -category "Devices" -subject "Entra"

    $permissionRows = foreach($row in $global:DevicePermissions.Keys){
        foreach($permission in $global:DevicePermissions.$row){
            [PSCustomObject]@{
                "targetPath" = $row
                "targetType" = $permission.targetType
                "targetId" = $permission.targetId
                "principalEntraId" = $permission.principalEntraId
                "principalSysId" = $permission.principalSysId
                "principalSysName" = $permission.principalSysName
                "principalType" = $permission.principalType
                "principalRole" = $permission.principalRole
                "through" = $permission.through
                "parentId" = $permission.parentId
                "accessType" = $permission.accessType
                "tenure" = $permission.tenure
                "startDateTime" = $permission.startDateTime
                "endDateTime" = $permission.endDateTime
                "createdDateTime" = $permission.createdDateTime
                "modifiedDateTime" = $permission.modifiedDateTime
            }
        }
    }

    Add-ToReportQueue -permissions $permissionRows -category "Devices"
    Remove-Variable -Name DevicePermissions -Scope Global -Force -Confirm:$False
    if(!$skipReportGeneration){
        Write-LogMessage -message "Generating report..." -level 4
        Write-Report
    }else{
        Reset-ReportQueue
    }
    Write-Progress -Id 1 -Completed -Activity $activity
}