Function get-AllEntraPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
    #>        
    Param(
        [Switch]$skipReportGeneration
    )

    Write-LogMessage -message "Starting Entra scan..." -level 4

    New-StatisticsObject -category "GroupsAndMembers" -subject "Entities"
    Write-Progress -Id 1 -PercentComplete 0 -Activity "Scanning Entra ID" -Status "Getting users and groups" 

    # Get user count with proper error handling
    try {
        $userCount = (New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/users/`$count" -Method GET -ComplexFilter -nopagination)
        Write-LogMessage -message "Retrieving metadata for $userCount users..." -level 4
    }
    catch {
        Write-LogMessage -message "Failed to retrieve user count: $_" -level 2
        $userCount = 0
    }
    
    Write-Progress -Id 1 -PercentComplete 1 -Activity "Scanning Entra ID" -Status "Getting users and groups" 

    # Get users with proper error handling
    try {
        $allUsers = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/users?`$select=id,userPrincipalName,displayName" -Method GET
        Write-LogMessage -message "Got metadata for $($allUsers.Count) users" -level 4
        
        # Verify we have users
        if ($null -eq $allUsers -or $allUsers.Count -eq 0) {
            Write-LogMessage -message "No users retrieved from Graph API" -level 2
            $allUsers = @()
        }
    }
    catch {
        Write-LogMessage -message "Failed to retrieve users: $_" -level 2
        $allUsers = @()
    }

    $activity = "Entra ID users"
    $jobsCreated = 0
    
    # More robust chunking with verification
    for ($i = 0; $i -lt $allUsers.Count; $i += 100) {
        $endIndex = [math]::Min($i + 99, $allUsers.Count - 1)
        
        # Only proceed if we have a valid range
        if ($i -le $endIndex) {
            $userBatch = $allUsers[$i..$endIndex]
            
            # Verify the batch contains users
            if ($null -ne $userBatch -and $userBatch.Count -gt 0) {
                Write-LogMessage -message "Creating scan job for users $i to $endIndex" -level 5
                
                New-ScanJob -Title $activity -Target "users_$($i)_$($userCount)" -FunctionToRun "get-EntraUsersAndGroupsBatch" -FunctionArguments @{
                    "entraUsers" = $userBatch
                }
                $jobsCreated++
            }
            else {
                Write-LogMessage -message "Skipping empty batch for users $i to $endIndex" -level 2
            }
        }
    }
    
    Write-LogMessage -message "Created $jobsCreated scan jobs for processing users" -level 4

    Update-StatisticsObject -category "GroupsAndMembers" -subject "Entities" -Amount $allUsers.Count
    Stop-StatisticsObject -category "GroupsAndMembers" -subject "Entities"

    # Only start jobs if we created any
    if ($jobsCreated -gt 0) {
        Start-ScanJobs -Title $activity
    }
    else {
        Write-LogMessage -message "No scan jobs were created - skipping job execution" -level 2
    }
    
    Remove-Variable -name allUsers -Force -Confirm:$False

    [System.GC]::GetTotalMemory($true) | out-null

    $global:EntraPermissions = @{}
    New-StatisticsObject -category "Entra" -subject "Roles"  

    $partners = New-GraphQuery -Uri "$($global:octo.graphUrl)/beta/directory/partners" -Method GET
    foreach($partner in $partners){
        Update-StatisticsObject -category "Entra" -subject "Roles"
        $permissionSplat = @{
            targetPath = "/"
            targetType = "tenant"
            principalEntraId = $partner.partnerTenantId
            principalEntraUpn = $partner.companyName
            principalSysName = $partner.supportUrl
            principalType = $partner.companyType
            principalRole = $partner.contractType
            through = "Direct"
            tenure = "Permanent"                    
        }            
        New-EntraPermissionEntry @permissionSplat
    }

    Write-Progress -Id 1 -PercentComplete 5 -Activity "Scanning Entra ID" -Status "Retrieving role definitions"

    #get role definitions
    $roleDefinitions = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/directoryRoleTemplates" -Method GET


    Write-Progress -Id 1 -PercentComplete 35 -Activity "Scanning Entra ID" -Status "Retrieving flexible (PIM) assigments"

    #get eligible role assignments
    try{
        $roleEligibilities = (New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/roleManagement/directory/roleEligibilityScheduleInstances" -Method GET -NoRetry | Where-Object {$_})
        $roleActivations = (New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/roleManagement/directory/roleAssignmentScheduleInstances" -Method GET | Where-Object {$_.assignmentType -eq "Activated"})
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
        try{
            $principal = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/directoryObjects/$($roleEligibility.principalId)" -Method GET
        }catch{
            Write-LogMessage -level 2 -message "Failed to resolve principal $($roleEligibility.principalId) to a directory object, was it deleted?" 
            $principal = $Null
            continue  
        }
        
        Update-StatisticsObject -category "Entra" -subject "Roles"
        $permissionSplat = @{
            targetPath = $roleEligibility.directoryScopeId
            principalEntraId = $principal.id
            principalEntraUpn = $principal.userPrincipalName
            principalSysName = $principal.displayName
            principalType = $principal."@odata.type"
            principalRole = $roleDefinition.displayName
            tenure = "Eligible"    
            startDateTime = $roleEligibility.startDateTime
            endDateTime = $roleEligibility.endDateTime                 
        }            
        New-EntraPermissionEntry @permissionSplat
        Write-Progress -Id 2 -Completed -Activity "Processing flexible (PIM) assignments"
    }

    Write-Progress -Id 1 -PercentComplete 10 -Activity "Scanning Entra ID" -Status "Retrieving fixed assigments"

    #get fixed assignments
    $roleAssignments = New-GraphQuery -Uri "$($global:octo.graphUrl)/beta/roleManagement/directory/roleAssignments?`$expand=principal" -Method GET

    Write-Progress -Id 1 -PercentComplete 20 -Activity "Scanning Entra ID" -Status "Processing fixed assigments"

    foreach($roleAssignment in $roleAssignments){
        if($roleActivations -and $roleActivations.roleAssignmentOriginId -contains $roleAssignment.id){
            Write-LogMessage -level 5 -message "Ignoring $($roleAssignment.id) because it is Eligible as well"
            continue
        }        
        $roleDefinition = $roleDefinitions | Where-Object { $_.id -eq $roleAssignment.roleDefinitionId }
        Update-StatisticsObject -category "Entra" -subject "Roles"
        $permissionSplat = @{
            targetPath = $roleAssignment.directoryScopeId
            principalEntraId = $roleAssignment.principal.id
            principalEntraUpn = $roleAssignment.principal.userPrincipalName
            principalSysName = $roleAssignment.principal.displayName
            principalType = $roleAssignment.principal."@odata.type"
            principalRole = $roleDefinition.displayName
            tenure = "Permanent"                    
        }            
        New-EntraPermissionEntry @permissionSplat
    }

    Remove-Variable roleDefinitions -Force -Confirm:$False
    Remove-Variable roleAssignments -Force -Confirm:$False
    Remove-Variable roleEligibilities -Force -Confirm:$False

    Write-Progress -Id 1 -PercentComplete 50 -Activity "Scanning Entra ID" -Status "Getting Service Principals"
    $servicePrincipals = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/servicePrincipals?`$expand=appRoleAssignments" -Method GET
    
    foreach($servicePrincipal in $servicePrincipals){
        Update-StatisticsObject -category "Entra" -subject "Roles"
        #skip disabled SPN's
        if($servicePrincipal.accountEnabled -eq $false -or $servicePrincipal.appRoleAssignments.Count -eq 0){
            continue
        }
        foreach($appRole in @($servicePrincipal.appRoleAssignments)){
            #skip disabled roles
            if($appRole.deletedDateTime){
                continue
            }

            $appRoleMeta = $Null;$appRoleMeta = @($servicePrincipals.appRoles | Where-Object { $_.id -eq $appRole.appRoleId })[0]
            if($False -eq $appRoleMeta.isEnabled){
                continue
            }

            $permissionSplat = @{
                targetPath = "/$($appRole.resourceDisplayName)"
                targetType = "API"
                targetId = $appRole.resourceId
                principalEntraId = $servicePrincipal.id
                principalSysName = $servicePrincipal.displayName
                principalType = $servicePrincipal.servicePrincipalType
                principalRole = $appRoleMeta.value
                tenure = "Permanent"             
            }   
            New-EntraPermissionEntry @permissionSplat
        }
    }

    Remove-Variable servicePrincipals -Force -Confirm:$False

    Stop-statisticsObject -category "Entra" -subject "Roles"
    
    $permissionRows = foreach($row in $global:EntraPermissions.Keys){
        foreach($permission in $global:EntraPermissions.$row){
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

    Add-ToReportQueue -permissions $permissionRows -category "Entra"
    Remove-Variable -Name EntraPermissions -Scope Global -Force -Confirm:$False
    if(!$skipReportGeneration){
        Write-LogMessage -message "Generating report..." -level 4
        Write-Report
    }else{
        Reset-ReportQueue
    }

    Write-Progress -Id 1 -Completed -Activity "Scanning Entra ID"
}