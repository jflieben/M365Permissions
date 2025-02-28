Function get-AllEntraPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -expandGroups: if set, group memberships will be expanded to individual users
        -excludeGroupsAndUsers: exclude group and user memberships from the report, only show role assignments
    #>        
    Param(
        [Switch]$expandGroups,
        [Switch]$excludeGroupsAndUsers
    )

    Write-LogMessage -message "Starting Entra scan..." -level 4
    $global:EntraPermissions = @{}
    New-StatisticsObject -category "Entra" -subject "Roles"    

    if(!$excludeGroupsAndUsers){
        get-AllEntraUsersAndGroups
        [System.GC]::GetTotalMemory($true) | out-null
        Reset-ReportQueue   
    }    

    Write-Progress -Id 1 -PercentComplete 5 -Activity "Scanning Entra ID" -Status "Retrieving role definitions"

    #get role definitions
    $roleDefinitions = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/directoryRoleTemplates' -Method GET

    Write-Progress -Id 1 -PercentComplete 10 -Activity "Scanning Entra ID" -Status "Retrieving fixed assigments"

    #get fixed assignments
    $roleAssignments = New-GraphQuery -Uri 'https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments?$expand=principal' -Method GET

    Write-Progress -Id 1 -PercentComplete 20 -Activity "Scanning Entra ID" -Status "Processing fixed assigments"

    foreach($roleAssignment in $roleAssignments){
        $roleDefinition = $roleDefinitions | Where-Object { $_.id -eq $roleAssignment.roleDefinitionId }
        $principalType = $roleAssignment.principal."@odata.type".Split(".")[2]
        $groupMembers = $Null
        if($principalType -eq "group" -and $expandGroups){
            try{
                $groupMembers = get-entraGroupMembers -groupId $roleAssignment.principal.id    
            }catch{
                Write-LogMessage -level 2 -message "Failed to retrieve group members for $($roleAssignment.principal.displayName), adding as group principal type instead"
            }
            foreach($groupMember in $groupMembers){
                Update-StatisticsObject -category "Entra" -subject "Roles"
                New-EntraPermissionEntry -path $roleAssignment.directoryScopeId -type "PermanentRole" -principalId $groupMember.id -roleDefinitionId $roleAssignment.roleDefinitionId -principalName $groupMember.displayName -principalUpn $groupMember.userPrincipalName -principalType $groupMember.principalType -roleDefinitionName $roleDefinition.displayName -through "SecurityGroup" -parent $roleAssignment.principal.id
            }
        }
        
        if(!$groupMembers){
            Update-StatisticsObject -category "Entra" -subject "Roles"
            New-EntraPermissionEntry -path $roleAssignment.directoryScopeId -type "PermanentRole" -principalId $roleAssignment.principal.id -roleDefinitionId $roleAssignment.roleDefinitionId -principalName $roleAssignment.principal.displayName -principalUpn $roleAssignment.principal.userPrincipalName -principalType $principalType -roleDefinitionName $roleDefinition.displayName
        }
    }

    Write-Progress -Id 1 -PercentComplete 35 -Activity "Scanning Entra ID" -Status "Retrieving flexible (PIM) assigments"

    #get eligible role assignments
    try{
        $roleEligibilities = (New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances' -Method GET -NoRetry | Where-Object {$_})
    }catch{
        Write-LogMessage -level 2 -message "Failed to retrieve flexible assignments, this is fine if you don't use PIM and/or don't have P2 licensing."
        $roleEligibilities = @()
    }

    Write-Progress -Id 1 -PercentComplete 45 -Activity "Scanning Entra ID" -Status "Processing flexible (PIM) assigments"

    $count = 0
    foreach($roleEligibility in $roleEligibilities){
        $count++
        Write-Progress -Id 2 -PercentComplete $(try{$count / $roleEligibilities.Count *100}catch{1}) -Activity "Processing flexible (PIM) assignments" -Status "[$count / $($roleEligibilities.Count)]"
        $roleDefinition = $roleDefinitions | Where-Object { $_.id -eq $roleEligibility.roleDefinitionId }
        $principalType = "Unknown"
        $groupMembers = $Null
        try{
            $principal = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/directoryObjects/$($roleEligibility.principalId)" -Method GET
            $principalType = $principal."@odata.type".Split(".")[2]
        }catch{
            Write-LogMessage -level 2 -message "Failed to resolve principal $($roleEligibility.principalId) to a directory object, was it deleted?"    
            $principal = $Null
        }
        if($principalType -eq "group" -and $expandGroups){
            try{
                $groupMembers = get-entraGroupMembers -groupId $principal.id
            }catch{
                Write-LogMessage -level 2 -message "Failed to retrieve group members for $($principal.displayName), adding as group principal type instead"
            }
            foreach($groupMember in $groupMembers){
                Update-StatisticsObject -category "Entra" -subject "Roles"
                New-EntraPermissionEntry -path $roleEligibility.directoryScopeId -type "EligibleRole" -principalId $groupMember.id -roleDefinitionId $roleEligibility.roleDefinitionId -principalName $groupMember.displayName -principalUpn $groupMember.userPrincipalName -principalType $groupMember.principalType -roleDefinitionName $roleDefinition.displayName -startDateTime $roleEligibility.startDateTime -endDateTime $roleEligibility.endDateTime -parent $principal.id -through "SecurityGroup"
            }
        }
        if(!$groupMembers){
            Update-StatisticsObject -category "Entra" -subject "Roles"
            New-EntraPermissionEntry -path $roleEligibility.directoryScopeId -type "EligibleRole" -principalId $principal.id -roleDefinitionId $roleEligibility.roleDefinitionId -principalName $principal.displayName -principalUpn $principal.userPrincipalName -principalType $principalType -roleDefinitionName $roleDefinition.displayName -startDateTime $roleEligibility.startDateTime -endDateTime $roleEligibility.endDateTime
        }
        Write-Progress -Id 2 -Completed -Activity "Processing flexible (PIM) assignments"
    }

    Remove-Variable roleDefinitions -Force -Confirm:$False
    Remove-Variable roleAssignments -Force -Confirm:$False
    Remove-Variable roleEligibilities -Force -Confirm:$False

    Write-Progress -Id 1 -PercentComplete 50 -Activity "Scanning Entra ID" -Status "Getting Service Principals"
    $servicePrincipals = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals?$expand=transitiveMemberOf' -Method GET
    
    foreach($servicePrincipal in $servicePrincipals){
        Update-StatisticsObject -category "Entra" -subject "Roles"
        #skip disabled SPN's
        if($servicePrincipal.accountEnabled -eq $false){
            continue
        }

        foreach($appRole in @($servicePrincipal.appRoles | Where-Object { $_.allowedMemberTypes -contains "Application" })){
            #skip disabled roles
            if($appRole.isEnabled -eq $false){
                continue
            }
            New-EntraPermissionEntry -path "/$($servicePrincipal.displayName)" -type "APIPermission" -principalId $servicePrincipal.appId -roleDefinitionId $appRole.value -principalName $servicePrincipal.displayName -principalUpn "N/A" -principalType "ServicePrincipal" -roleDefinitionName $appRole.displayName
        }
    }

    Write-Progress -Id 1 -PercentComplete 75 -Activity "Scanning Entra ID" -Status "Getting Graph Subscriptions"
    if($global:octo.userConfig.authMode -ne "Delegated"){
        Write-LogMessage -level 2 -message "Graph subscriptions can only be retrieved in delegated mode, and will not be added to your report."
    }else{
        $graphSubscriptions = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/subscriptions' -Method GET
        foreach($graphSubscription in $graphSubscriptions){
            Update-StatisticsObject -category "Entra" -subject "Roles"
            $spn = $null; $spn = $servicePrincipals | Where-Object { $_.appId -eq $graphSubscription.applicationId }
            if(!$spn){
                $spn = @{
                    displayName = "Microsoft"
                    id = $graphSubscription.applicationId
                }
            }
            try{$parent = $Null; $parent = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/directoryObjects/$($graphSubscription.creatorId)" -Method GET}catch{$parent = $Null}
            if(!$parent){
                $parent = @{
                    displayName = "Unknown"
                    "@odata.type" = "Deleted?"
                }
            }
            New-EntraPermissionEntry -path "/graph/$($graphSubscription.resource)" -type "Subscription/Webhook" -principalId $graphSubscription.applicationId -roleDefinitionId "N/A" -principalName $spn.displayName -principalUpn "N/A" -principalType "ServicePrincipal" -roleDefinitionName "Get $($graphSubscription.changeType) events" -startDateTime "See audit log" -endDateTime $graphSubscription.expirationDateTime -through "GraphAPI" -parent "$($parent.displayName) ($($parent.'@odata.type'.Split(".")[2]))"
        }

        Remove-Variable graphSubscriptions -Force -Confirm:$False
    }
    Remove-Variable servicePrincipals -Force -Confirm:$False

    Stop-statisticsObject -category "Entra" -subject "Roles"
    
    $permissionRows = foreach($row in $global:EntraPermissions.Keys){
        foreach($permission in $global:EntraPermissions.$row){
            [PSCustomObject]@{
                "Path" = $row
                "Type" = $permission.Type
                "principalName" = $permission.principalName
                "roleDefinitionName" = $permission.roleDefinitionName               
                "principalUpn" = $permission.principalUpn
                "principalType" = $permission.principalType
                "through" = $permission.through
                "parent" = $permission.parent
                "startDateTime" = $permission.startDateTime
                "endDateTime" = $permission.endDateTime
                "principalId"    = $permission.principalId                
                "roleDefinitionId" = $permission.roleDefinitionId
            }
        }
    }

    Add-ToReportQueue -permissions $permissionRows -category "Entra"
    Remove-Variable -Name EntraPermissions -Scope Global -Force -Confirm:$False
    Reset-ReportQueue

    Write-Progress -Id 1 -Completed -Activity "Scanning Entra ID"
}