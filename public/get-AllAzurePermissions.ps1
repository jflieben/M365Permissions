Function get-AllAzurePermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Switch]$skipReportGeneration
    )

    $global:AzurePermissions = @{}
    New-StatisticsObject -category "Azure" -subject "objects"
    Write-LogMessage -level 4 -message "Getting subscriptions..."
    $subscriptions = New-GraphQuery -Uri "https://management.azure.com/subscriptions?api-version=2020-01-01" -Method GET -resource "https://management.azure.com/"
    Write-LogMessage -level 4 -message "$($subscriptions.Count) subscriptions retrieved :)"
    foreach($subscription in $subscriptions){
        Write-LogMessage -message "Starting Azure scan of subscription $($subscription.subscriptionId)..." -level 4
    
        try{
            Write-LogMessage -level 4 -message "Getting role definitions and generating lookup hash..."
            $roleDefinitions = New-GraphQuery -Uri 'https://management.azure.com/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01' -Method GET -resource "https://management.azure.com/"
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
        $roleDefinitions = $Null; $roleDefinitions = New-GraphQuery -Uri "https://management.azure.com/subscriptions/$($subscription.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01" -Method GET -resource "https://management.azure.com/"
        foreach($roleDefinition in $roleDefinitions){
            if(!$roleDefinitionsLookup.$($roleDefinition.name)){
                Write-LogMessage -level 4 -message "Role definition $($roleDefinition.name) not found in lookup hash, adding it as custom role"
                $roleDefinitionsLookup.$($roleDefinition.name) = $roleDefinition
            }
        }  
        Write-LogMessage -level 4 -message "Getting eligible role assignments for subscription $($subscription.subscriptionId)"
        try{
            $eligiblePermissions = $Null; $eligiblePermissions = New-GraphQuery -Uri "https://management.azure.com/subscriptions/$($subscription.subscriptionId)/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&`$filter=atScope()" -Method GET -resource "https://management.azure.com/"
        }catch{
            Write-LogMessage -level 3 -message "Failed to retrieve role assignments with error $($_.Exception.Message)"
        }
        foreach($eligiblePermission in $eligiblePermissions){
            add-AzurePermissions -tenure "Eligible" -permission $eligiblePermission -roleDefinitionsLookup $roleDefinitionsLookup -targetPath "/$($subscription.subscriptionId)" -targetType "subscription" -targetId $subscription.subscriptionId
        }

        Write-LogMessage -level 4 -message "Getting permanent role assignments for subscription $($subscription.subscriptionId)"
        $permanentPermissions = $Null; $permanentPermissions = New-GraphQuery -Uri "https://management.azure.com/subscriptions/$($subscription.subscriptionId)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" -Method GET -resource "https://management.azure.com/"
        foreach($permanentPermission in $permanentPermissions){
            add-AzurePermissions -tenure "Permanent" -permission $permanentPermission -roleDefinitionsLookup $roleDefinitionsLookup -targetPath "/$($subscription.subscriptionId)" -targetType "subscription" -targetId $subscription.subscriptionId
        }

        Write-LogMessage -level 4 -message "Getting resourcegroups for subscription $($subscription.subscriptionId)"
        $resourceGroups = $Null; $resourceGroups = New-GraphQuery -Uri "https://management.azure.com/subscriptions/$($subscription.subscriptionId)/resourcegroups?api-version=2021-04-01" -Method GET -resource "https://management.azure.com/"
        foreach($resourceGroup in $resourceGroups){
            Update-StatisticsObject -category "Azure" -subject "objects"
            Write-LogMessage -level 4 -message "Getting role definitions for resource group $($resourceGroup.name)"
            $roleDefinitions = $Null; $roleDefinitions = New-GraphQuery -Uri "https://management.azure.com/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01" -Method GET -resource "https://management.azure.com/"
            foreach($roleDefinition in $roleDefinitions){
                if(!$roleDefinitionsLookup.$($roleDefinition.name)){
                    Write-LogMessage -level 4 -message "Role definition $($roleDefinition.name) not found in lookup hash, adding it as custom role"
                    $roleDefinitionsLookup.$($roleDefinition.name) = $roleDefinition
                }
            }

            Write-LogMessage -level 4 -message "Getting eligible role assignments for resource group $($resourceGroup.name)"
            try{
                $eligiblePermissions = $Null; $eligiblePermissions = New-GraphQuery -Uri "https://management.azure.com/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&`$filter=atScope()" -Method GET -resource "https://management.azure.com/"
            }catch{
                Write-LogMessage -level 3 -message "Failed to retrieve role assignments with error $($_.Exception.Message)"
            }
            foreach($eligiblePermission in $eligiblePermissions){
                add-AzurePermissions -tenure "Eligible" -permission $eligiblePermission -roleDefinitionsLookup $roleDefinitionsLookup -targetPath "/$($subscription.subscriptionId)/$($resourceGroup.name)" -targetType "resourceGroup" -targetId $resourceGroup.id
            }

            Write-LogMessage -level 4 -message "Getting permanent role assignments for resource group $($resourceGroup.name)"
            $permanentPermissions = $Null; $permanentPermissions = New-GraphQuery -Uri "https://management.azure.com/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" -Method GET -resource "https://management.azure.com/"
            foreach($permanentPermission in $permanentPermissions){
                add-AzurePermissions -tenure "Permanent" -permission $permanentPermission -roleDefinitionsLookup $roleDefinitionsLookup -targetPath "/$($subscription.subscriptionId)/$($resourceGroup.name)" -targetType "resourceGroup" -targetId $resourceGroup.id
            }

            Write-LogMessage -level 4 -message "Getting resources for resource group $($resourceGroup.name)"
            $resources = $Null; $resources = New-GraphQuery -Uri "https://management.azure.com/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/resources?api-version=2021-04-01" -Method GET -resource "https://management.azure.com/"
            foreach($resource in $resources){
                Update-StatisticsObject -category "Azure" -subject "objects"
                Write-LogMessage -level 4 -message "Getting permanent role assignments for resource $($resource.name)"
                try{
                    $permanentPermissions = $Null; $permanentPermissions = New-GraphQuery -Uri "https://management.azure.com/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/$($resource.type)/$($resource.name)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" -Method GET -resource "https://management.azure.com/"
                }catch{
                    Write-LogMessage -level 3 -message "Failed to retrieve role assignments for resource $($resource.name) with error $($_.Exception.Message)"
                    continue
                }
                foreach($permanentPermission in $permanentPermissions){
                    add-AzurePermissions -tenure "Permanent" -permission $permanentPermission -roleDefinitionsLookup $roleDefinitionsLookup -targetPath "/$($subscription.subscriptionId)/$($resourceGroup.name)/$($resource.type)/$($resource.name)" -targetType $resource.type -targetId $resource.id
                }

                Write-LogMessage -level 4 -message "Getting eligible role assignments for resource $($resource.name)"
                try{
                    $eligiblePermissions = $Null; $eligiblePermissions = New-GraphQuery -Uri "https://management.azure.com/subscriptions/$($subscription.subscriptionId)/resourceGroups/$($resourceGroup.name)/providers/$($resource.type)/$($resource.name)/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&`$filter=atScope()" -Method GET -resource "https://management.azure.com/"
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
    }

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

    Add-ToReportQueue -permissions $permissionRows -category "Azure"
    Remove-Variable -Name AzurePermissions -Scope Global -Force -Confirm:$False
    if(!$skipReportGeneration){
        Write-LogMessage -message "Generating report..." -level 4
        Write-Report
    }else{
        Reset-ReportQueue
    }
}