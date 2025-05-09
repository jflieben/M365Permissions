Function get-AzurePermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [parameter(Mandatory=$true)][String]$subscriptionId,
        [Boolean]$isParallel=$False
    )

    $global:AzurePermissions = @{}
    $activity = "Scanning $($subscriptionId)"
    Write-Progress -Id 2 -PercentComplete 1 -Activity $activity -Status "Getting metadata..."
    New-StatisticsObject -category "Azure" -subject "objects"
    Write-LogMessage -level 4 -message "Getting subscription $subscriptionId ..."
   
    $subscription = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions/$($subscriptionId)?api-version=2022-12-01" -Method GET -resource "$($global:octo.azureUrl)/"
    Write-LogMessage -message "Starting Azure scan of subscription $($subscription.subscriptionId)..." -level 4

    try{
        Write-Progress -Id 2 -PercentComplete 1 -Activity $activity -Status "Getting roledefinitions..."
    
        Write-LogMessage -level 4 -message "Getting role definitions and generating lookup hash..."
        $roleDefinitions = New-GraphQuery -Uri '$($global:octo.azureUrl)/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01' -Method GET -resource "$($global:octo.azureUrl)/"
        $roleDefinitionsLookup = @{}
        foreach($roleDefinition in $roleDefinitions){
            $roleDefinitionsLookup.$($roleDefinition.name) = $roleDefinition
        }

        Remove-Variable roleDefinitions -Force -Confirm:$False
        [System.GC]::GetTotalMemory($true) | out-null 

        Write-LogMessage -level 4 -message "Hash generated :)" 
    }catch{
        Write-LogMessage -level 3 -message "Failed to retrieve role definitions with error $($_.Exception.Message)"
    }
    
    Update-StatisticsObject -category "Azure" -subject "objects"

    Write-LogMessage -level 4 -message "Getting role definitions for subscription $($subscription.subscriptionId)"
    $roleDefinitions = $Null; $roleDefinitions = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions/$($subscription.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01" -Method GET -resource "$($global:octo.azureUrl)/"
    foreach($roleDefinition in $roleDefinitions){
        if(!$roleDefinitionsLookup.$($roleDefinition.name)){
            Write-LogMessage -level 4 -message "Role definition $($roleDefinition.name) not found in lookup hash, adding it as custom role"
            $roleDefinitionsLookup.$($roleDefinition.name) = $roleDefinition
        }
    }  

    Write-Progress -Id 2 -PercentComplete 5 -Activity $activity -Status "Getting permissions..."
    
    Write-LogMessage -level 4 -message "Getting eligible role assignments for subscription $($subscription.subscriptionId)"
    try{
        $eligiblePermissions = $Null; $eligiblePermissions = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions/$($subscription.subscriptionId)/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&`$filter=atScope()" -Method GET -resource "$($global:octo.azureUrl)/"
    }catch{
        Write-LogMessage -level 3 -message "Failed to retrieve role assignments with error $($_.Exception.Message)"
    }
    foreach($eligiblePermission in $eligiblePermissions){
        add-AzurePermissions -tenure "Eligible" -permission $eligiblePermission -roleDefinitionsLookup $roleDefinitionsLookup -targetPath "/$($subscription.subscriptionId)" -targetType "subscription" -targetId $subscription.subscriptionId
    }

    Write-LogMessage -level 4 -message "Getting permanent role assignments for subscription $($subscription.subscriptionId)"
    $permanentPermissions = $Null; $permanentPermissions = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions/$($subscription.subscriptionId)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()" -Method GET -resource "$($global:octo.azureUrl)/"
    foreach($permanentPermission in $permanentPermissions){
        add-AzurePermissions -tenure "Permanent" -permission $permanentPermission -roleDefinitionsLookup $roleDefinitionsLookup -targetPath "/$($subscription.subscriptionId)" -targetType "subscription" -targetId $subscription.subscriptionId
    }

    Write-LogMessage -level 4 -message "Getting resourcegroups for subscription $($subscription.subscriptionId)"
    Write-Progress -Id 2 -PercentComplete 10 -Activity $activity -Status "Getting resourcegroups..."
    
    $resourceGroups = $Null; $resourceGroups = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions/$($subscription.subscriptionId)/resourcegroups?api-version=2021-04-01" -Method GET -resource "$($global:octo.azureUrl)/"
    foreach($resourceGroup in $resourceGroups){
        Write-Progress -Id 2 -PercentComplete 1 -Activity $activity -Status "Processing resource group $($resourceGroup.name)..."
    
        Update-StatisticsObject -category "Azure" -subject "objects"
        Write-LogMessage -level 4 -message "Getting role definitions for resource group $($resourceGroup.name)"
        $roleDefinitions = $Null; $roleDefinitions = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01" -Method GET -resource "$($global:octo.azureUrl)/"
        foreach($roleDefinition in $roleDefinitions){
            if(!$roleDefinitionsLookup.$($roleDefinition.name)){
                Write-LogMessage -level 4 -message "Role definition $($roleDefinition.name) not found in lookup hash, adding it as custom role"
                $roleDefinitionsLookup.$($roleDefinition.name) = $roleDefinition
            }
        }

        Write-LogMessage -level 4 -message "Getting eligible role assignments for resource group $($resourceGroup.name)"
        try{
            $eligiblePermissions = $Null; $eligiblePermissions = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&`$filter=atScope()" -Method GET -resource "$($global:octo.azureUrl)/"
        }catch{
            Write-LogMessage -level 3 -message "Failed to retrieve role assignments with error $($_.Exception.Message)"
        }
        foreach($eligiblePermission in $eligiblePermissions){
            add-AzurePermissions -tenure "Eligible" -permission $eligiblePermission -roleDefinitionsLookup $roleDefinitionsLookup -targetPath "/$($subscription.subscriptionId)/$($resourceGroup.name)" -targetType "resourceGroup" -targetId $resourceGroup.id
        }

        Write-LogMessage -level 4 -message "Getting permanent role assignments for resource group $($resourceGroup.name)"
        $permanentPermissions = $Null; $permanentPermissions = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()" -Method GET -resource "$($global:octo.azureUrl)/"
        foreach($permanentPermission in $permanentPermissions){
            add-AzurePermissions -tenure "Permanent" -permission $permanentPermission -roleDefinitionsLookup $roleDefinitionsLookup -targetPath "/$($subscription.subscriptionId)/$($resourceGroup.name)" -targetType "resourceGroup" -targetId $resourceGroup.id
        }

        Write-LogMessage -level 4 -message "Getting resources for resource group $($resourceGroup.name)"
        $resources = $Null; $resources = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/resources?api-version=2021-04-01" -Method GET -resource "$($global:octo.azureUrl)/"
        foreach($resource in $resources){
            Update-StatisticsObject -category "Azure" -subject "objects"
            Write-LogMessage -level 4 -message "Getting permanent role assignments for resource $($resource.name)"
            try{
                $permanentPermissions = $Null; $permanentPermissions = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/$($resource.type)/$($resource.name)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()" -Method GET -resource "$($global:octo.azureUrl)/"
            }catch{
                Write-LogMessage -level 3 -message "Failed to retrieve role assignments for resource $($resource.name) with error $($_.Exception.Message)"
                continue
            }
            foreach($permanentPermission in $permanentPermissions){
                add-AzurePermissions -tenure "Permanent" -permission $permanentPermission -roleDefinitionsLookup $roleDefinitionsLookup -targetPath "/$($subscription.subscriptionId)/$($resourceGroup.name)/$($resource.type)/$($resource.name)" -targetType $resource.type -targetId $resource.id
            }

            Write-LogMessage -level 4 -message "Getting eligible role assignments for resource $($resource.name)"
            try{
                $eligiblePermissions = $Null; $eligiblePermissions = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/$($resource.type)/$($resource.name)/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&`$filter=atScope()" -Method GET -resource "$($global:octo.azureUrl)/"
            }catch{
                Write-LogMessage -level 3 -message "Failed to retrieve role assignments for resource $($resource.name) with error $($_.Exception.Message)"
                continue
            }

            foreach($eligiblePermission in $eligiblePermissions){
                add-AzurePermissions -tenure "Eligible" -permission $eligiblePermission -roleDefinitionsLookup $roleDefinitionsLookup -targetPath "/$($subscription.subscriptionId)/$($resourceGroup.name)/$($resource.type)/$($resource.name)" -targetType $resource.type -targetId $resource.id
            }
        }
    }

    Remove-Variable roleDefinitionsLookup -Force -Confirm:$False
    Remove-Variable permanentPermissions -Force -Confirm:$False
    [System.GC]::GetTotalMemory($true) | out-null
    Write-Progress -Id 1 -Completed -Activity "Scanning Azure"  
    
    Stop-statisticsObject -category "Azure" -subject "objects"

    $permissionRows = foreach($row in $global:AzurePermissions.Keys){
        foreach($permission in $global:AzurePermissions.$row){
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
    Add-ToReportQueue -permissions $permissionRows -category "Azure"
    Remove-Variable -Name AzurePermissions -Scope Global -Force -Confirm:$False
    if(!$isParallel){
        Write-Report         
    }else{
        [System.GC]::GetTotalMemory($true) | out-null         
    }    
}