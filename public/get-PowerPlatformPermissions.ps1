Function get-PowerPlatformPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Boolean]$isParallel=$False
    )

    if($global:octo.userConfig.authMode -eq "Delegated"){
        Write-Error "You can only scan Power Platform permissions when using ServicePrincipal or ManagedIdentity authentication mode" -ErrorAction Continue
        return $Null
    }

    $global:PowerPlatformPermissions = @{}
    New-StatisticsObject -category "PowerPlatform" -subject "Securables"

    $activity = "Scanning Power Platform"
    Write-Progress -Id 1 -Activity $activity -Status "Starting scan" -PercentComplete 0
    Write-LogMessage -message "Starting Power Platform scan with Environments..." -level 4
    try{
        $environments = New-GraphQuery -Uri "$($global:octo.babUrl)/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01&`$expand=properties" -Method GET -resource $global:octo.babUrl
    }catch{
        Write-Error "You have not (yet) configured the correct permissions for the Power Platform, aborting scan. See https://www.lieben.nu/liebensraum/2025/05/scanning-the-power-platform/ for instructions!" -ErrorAction Continue
        return $Null
    }

    foreach($environment in $environments){
        Update-StatisticsObject -category "PowerPlatform" -subject "Securables"
        if($environment.properties.states.runtime.id -eq "Disabled"){
            Write-LogMessage -message "Skipping $($environment.name) because it is disabled!" -level 3
            continue
        }        
        Write-LogMessage -message "Scanning environment $($environment.name)...." -level 4
        Write-Progress -Id 1 -Activity $activity -Status "Scanning environment $($environment.name)...." -PercentComplete 0
        $environmentId = $environment.name            
        $flows = New-GraphQuery -Uri "$($global:octo.flowUrl)/providers/Microsoft.ProcessSimple/scopes/admin/environments/$environmentId/v2/flows?api-version=2016-11-01&`$select=permissions" -Method GET -resource $global:octo.ppResource
        Write-LogMessage -message "Got $($flows.Count) Flows..." -level 4
        for($f = 0; $f -lt $flows.Count; $f++){
            Update-StatisticsObject -category "PowerPlatform" -subject "Securables"
            $flow = $flows[$f]
            $percentComplete = try{$f / $flows.Count * 100} catch{0}
            Write-Progress -Id 2 -Activity "Scanning flows" -Status "Checking $($flow.properties.displayName) ($f of $($flows.Count))..." -PercentComplete $percentComplete
            
            try{
                $flowUsers = $Null; $flowUsers = New-GraphQuery -ignoreableErrors @("409") -Uri "$($global:octo.flowUrl)/providers/Microsoft.ProcessSimple/scopes/admin/environments/$environmentId/flows/$($flow.name)/permissions?api-version=2016-11-01" -Method GET -resource $global:octo.ppResource
            }catch{
                Write-LogMessage $_ -level 3
                continue
            }
            $deletedUserIds = @();
            for($u = 0; $u -lt $flowUsers.Count; $u++){
                if(!$flowUsers[$u].properties.principal){continue}
                if($flowUsers[$u].properties.principal.type -eq "Tenant"){
                    Write-LogMessage -message "Flow user $($flowUsers[$u].properties.permissionType) $($flowUsers[$u].properties.principal.id) is a tenant"
                    continue
                }
                $aadObj = get-aadObject -id $flowUsers[$u].properties.principal.id
                if(!$aadObj -and $deletedUserIds -notcontains $flowUsers[$u].properties.principal.id){
                    $deletedUserIds += $flowUsers[$u].properties.principal.id
                }
            }

            for($u = 0; $u -lt $flowUsers.Count; $u++){
                if(!$flowUsers[$u].properties.principal){continue}
                if($deletedUserIds -contains $flowUsers[$u].properties.principal.id){
                    Write-LogMessage -message "Flow user $($flowUsers[$u].properties.permissionType) $($flowUsers[$u].properties.principal.id) does not exist in Entra, skipping..." -level 5
                    continue
                }
                $flowUser = $flowUsers[$u]
                if($flowUser.properties.permissionType -ne "Principal"){
                    Write-LogMessage -message "Flow user $($flowUser.properties.permissionType) is not a principal, skipping..." -level 3
                    continue
                }

                $permissionSplat = @{
                    targetPath = "/$environmentId/flows/$($flow.name)/$($flow.properties.displayName)"
                    targetType = "PowerPlatformFlow"
                    targetId = $flow.name
                    principalEntraId = if($flowUser.properties.principal.type -eq "Tenant"){$flowUser.properties.principal.tenantId}else{$flowUser.properties.principal.id}
                    principalSysId = $flowUser.name
                    principalSysName = $flowUser.name
                    principalType = $flowUser.properties.principal.type
                    principalRole = $flowUser.properties.roleName
                    tenure = "Permanent"
                } 
                New-PowerPermissionEntry @permissionSplat
            }
        }
        Write-Progress -Id 2 -Activity "Scanning flows" -Completed

        $powerApps = New-GraphQuery -Uri "$($global:octo.pappsUrl)/providers/Microsoft.PowerApps/scopes/admin/environments/$environmentId/apps?api-version=2016-11-01&`$expand=permissions" -Method GET -resource $global:octo.ppResource
        Write-LogMessage -message "Got $($powerApps.Count) PowerApps..." -level 4
        for($p = 0; $p -lt $powerApps.Count; $p++){
            Update-StatisticsObject -category "PowerPlatform" -subject "Securables"
            $powerApp = $powerApps[$p]
            $percentComplete = try{$p / $powerApps.Count * 100} catch{0}
            Write-Progress -Id 2 -Activity "Scanning powerApps" -Status "Checking $($powerApp.properties.displayName) ($p of $($powerApps.Count))..." -PercentComplete $percentComplete
            try{
                $powerAppUsers = $Null; $powerAppUsers = New-GraphQuery -ignoreableErrors @("409") -Uri "$($global:octo.pappsUrl)/providers/Microsoft.PowerApps/scopes/admin/environments/$environmentId/apps/$($powerApp.name)/permissions?api-version=2016-11-01" -Method GET -resource $global:octo.ppResource
            }catch{
                Write-LogMessage $_ -level 3
                continue
            }
            $deletedUserIds = @();
            for($u = 0; $u -lt $powerAppUsers.Count; $u++){
                if(!$powerAppUsers[$u].properties.principal){continue}
                if($powerAppUsers[$u].properties.principal.type -eq "Tenant"){
                    Write-LogMessage -message "PowerApps user $($powerAppUsers[$u].properties.permissionType) $($powerAppUsers[$u].properties.principal.id) is a tenant"
                    continue
                }                    
                $aadObj = get-aadObject -id $powerAppUsers[$u].properties.principal.id
                if(!$aadObj -and $deletedUserIds -notcontains $powerAppUsers[$u].properties.principal.id){
                    $deletedUserIds += $powerAppUsers[$u].properties.principal.id
                }
            }

            for($u = 0; $u -lt $powerAppUsers.Count; $u++){
                if(!$powerAppUsers[$u].properties.principal){continue}
                if($deletedUserIds -contains $powerAppUsers[$u].properties.principal.id){
                    Write-LogMessage -message "PowerApps user $($powerAppUsers[$u].properties.permissionType) $($powerAppUsers[$u].properties.principal.id) does not exist in Entra, skipping..." -level 5
                    continue
                }
                $powerAppUser = $powerAppUsers[$u]
                $permissionSplat = @{
                    targetPath = "/$environmentId/powerapps/$($powerApp.name)/$($powerApp.properties.displayName)"
                    targetType = "PowerPlatformApp"
                    targetId = $powerApp.name
                    principalEntraId = if($powerAppUser.properties.principal.type -eq "Tenant"){$powerAppUser.properties.principal.tenantId}else{$powerAppUser.properties.principal.id}
                    principalSysId = $powerAppUser.properties.principal.email
                    principalSysName = $powerAppUser.properties.principal.displayName
                    principalType = $powerAppUser.properties.principal.type
                    principalRole = $powerAppUser.properties.roleName
                    tenure = "Permanent"
                    createdDateTime = $powerAppUser.properties.createdOn
                } 
                New-PowerPermissionEntry @permissionSplat
            }
        }
        Write-Progress -Id 2 -Activity "Scanning powerApps" -Completed
    }

    Write-Progress -Id 1 -Completed -Activity "Scanning Azure"  
    
    Stop-statisticsObject -category "PowerPlatform" -subject "Securables"

    $permissionRows = foreach($row in $global:PowerPlatformPermissions.Keys){
        foreach($permission in $global:PowerPlatformPermissions.$row){
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
    Write-Progress -Id 2 -Activity $activity -Completed
    Add-ToReportQueue -permissions $permissionRows -category "PowerPlatform"
    Remove-Variable -Name PowerPlatformPermissions -Scope Global -Force -Confirm:$False
    if(!$isParallel){
        Write-Report         
    }else{
        [System.GC]::GetTotalMemory($true) | out-null         
    }        
}