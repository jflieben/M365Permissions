function get-EntraUsersAndGroupsBatch {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        Parameters:
    #>        
    Param(
        [parameter(Mandatory=$true)][object[]]$entraUsers,
        [parameter(Mandatory=$false)][bool]$isTopLevel = $false
    )

    # Validate the entraUsers parameter is not null or empty
    if ($null -eq $entraUsers) {
        Write-LogMessage -message "Critical error: entraUsers parameter is null" -level 1
        return
    }
    
    if ($entraUsers.Count -eq 0) {
        Write-LogMessage -message "Warning: entraUsers parameter is an empty array" -level 2
        return
    }
    
    # Add a debug log to see what data we're actually receiving
    Write-LogMessage -message "Processing batch with $($entraUsers.Count) users. First user ID: $($entraUsers[0].id)" -level 4
    
    $global:EntraPermissions = @{}
    [System.Collections.ArrayList]$entraUserRows = @()
    $count = 0

    # Process owned objects using the advanced batch functionality
    Write-LogMessage -message "Processing user owned objects in batch mode" -level 4
    $ownedObjectsBatchResults = New-GraphQuery -Method GET -Uri "$($global:octo.graphUrl)" -UseBatchApi `
        -BatchItems $entraUsers `
        -BatchSize 20 `
        -BatchActivity "Processing user owned objects" `
        -BatchUrlGenerator {
            param($user)
            return "/users/$($user.id)/ownedObjects?`$select=id,displayName,groupTypes,mailEnabled,securityEnabled,membershipRule&`$top=999"
        } `
        -BatchIdGenerator {
            param($index)
            return "owned_$index"
        } `
        -ProgressId 2
    
    # Process memberships using the advanced batch functionality
    Write-LogMessage -message "Processing user group memberships in batch mode" -level 4
    $membershipsBatchResults = New-GraphQuery -Method GET -Uri "$($global:octo.graphUrl)" -UseBatchApi `
        -BatchItems $entraUsers `
        -BatchSize 20 `
        -BatchActivity "Processing user group memberships" `
        -BatchUrlGenerator {
            param($user)
            return "/users/$($user.id)/transitiveMemberOf/microsoft.graph.group?`$select=id,displayName,groupTypes,mailEnabled,securityEnabled,membershipRule&`$top=999"
        } `
        -BatchIdGenerator {
            param($index)
            return "member_$index"
        } `
        -ProgressId 3
    
    # Process the batch results
    Write-LogMessage -message "Processing batch results" -level 4
    for ($batchIndex = 0; $batchIndex -lt $ownedObjectsBatchResults.Count; $batchIndex++) {
        $ownedBatch = $ownedObjectsBatchResults[$batchIndex]
        $membershipBatch = $membershipsBatchResults[$batchIndex]
        
        # Calculate the start index for this batch
        $batchStartIndex = $batchIndex * 20
        
        # Process each user in the batch
        for ($j = 0; $j -lt [Math]::Min(20, $entraUsers.Count - $batchStartIndex); $j++) {
            $entraUser = $entraUsers[$batchStartIndex + $j]
            $count++
            
            # Determine user type
            if($entraUser.userPrincipalName -like "*#EXT#@*") {
                $principalType = "External User"
            } else {
                $principalType = "Internal User"
            }
            
            # Process owned objects for this user
            $ownedResponse = $ownedBatch.responses | Where-Object { $_.id -eq "owned_$j" }
            if ($ownedResponse -and $ownedResponse.status -eq 200) {
                $ownedObjects = $ownedResponse.body.value
                if ($null -eq $ownedObjects) { $ownedObjects = @() }
                
                foreach($ownedObject in $ownedObjects) {
                    if($ownedObject."@odata.type" -eq "#microsoft.graph.group") {
                        $groupType = Get-EntraGroupType -group $ownedObject
                        $entraUserRows.Add([PSCustomObject]@{
                            "GroupName" = $ownedObject.displayName
                            "GroupType" = $groupType
                            "GroupID" = $ownedObject.id
                            "MemberName" = $entraUser.displayName
                            "MemberID" = $entraUser.id
                            "MemberUPN" = $entraUser.userPrincipalName
                            "MemberType" = $principalType
                            "Role" = "Owner"
                        }) > $Null
                    } else {
                        $permissionsSplat = @{
                            targetPath = "/$($ownedObject.displayName)"
                            targetType = $ownedObject."@odata.type".Split(".")[2]
                            targetId = $ownedObject.id
                            principalEntraId = $entraUser.id
                            principalSysName = $entraUser.displayName
                            principalType = $principalType
                            principalRole = "Owner"
                            through = "Direct"
                            parentId = ""
                            accessType = "Allow"
                            tenure = "Permanent"
                            startDateTime = ""
                            endDateTime = ""
                        }
                        New-EntraPermissionEntry @permissionsSplat
                    }
                }
            }
            else {
                Write-LogMessage -level 2 -message "Failed to get owned objects for user $($entraUser.id), status: $($ownedResponse.status)"
            }
            
            # Process memberships for this user
            $membershipResponse = $membershipBatch.responses | Where-Object { $_.id -eq "member_$j" }
            if ($membershipResponse -and $membershipResponse.status -eq 200) {
                $memberships = $membershipResponse.body.value
                if ($null -eq $memberships) { $memberships = @() }
                
                foreach($membership in $memberships) {
                    $groupType = Get-EntraGroupType -group $membership
                    $entraUserRows.Add([PSCustomObject]@{
                        "GroupName" = $membership.displayName
                        "GroupType" = $groupType
                        "GroupID" = $membership.id
                        "MemberName" = $entraUser.displayName
                        "MemberID" = $entraUser.id
                        "MemberUPN" = $entraUser.userPrincipalName
                        "MemberType" = $principalType
                        "Role" = "Member"
                    }) > $Null
                }
            }
            else {
                Write-LogMessage -level 2 -message "Failed to get memberships for user $($entraUser.id), status: $($membershipResponse.status)"
            }
        }
    }
    
    Write-LogMessage -message "Processed $count users with batch processing" -level 4
    [System.GC]::GetTotalMemory($true) | out-null

    Add-ToReportQueue -permissions $entraUserRows -category "GroupsAndMembers"

    $permissionRows = foreach($row in $global:EntraPermissions.Keys) {
        foreach($permission in $global:EntraPermissions.$row) {
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
}