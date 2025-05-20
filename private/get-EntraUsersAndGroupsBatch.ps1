function get-EntraUsersAndGroupsBatch {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        Parameters:
    #>        
    Param(
        [parameter(Mandatory=$true)][object[]]$entraUsers
    )

    if ($null -eq $entraUsers -or $entraUsers.Count -eq 0) {
        Write-LogMessage -message "No users provided to get-EntraUsersAndGroupsBatch" -level 2
        return
    }
    $global:EntraPermissions = @{}

    [System.Collections.ArrayList]$entraUserRows = @()
    $count = 0
    
    # Take the 100 users sent to this function and split them into batches of 20 due to the Graph API batch limit
    for ($i = 0; $i -lt $entraUsers.Count; $i += 20) {
        $batchUsers = $entraUsers[$i..([Math]::Min($i + 19, $entraUsers.Count - 1))]
        
        Write-Progress -Id 2 -PercentComplete $(($i / $entraUsers.Count) * 100) -Activity "Processing user batch" -Status "Processing users $i to $([Math]::Min($i + 19, $entraUsers.Count - 1))"
        
        # Create batch requests for owned objects
        $ownedObjectsRequests = @()
        foreach ($j in 0..($batchUsers.Count - 1)) {
            $ownedObjectsRequests += @{
                id = "owned_$j"
                method = "GET"
                url = "/users/$($batchUsers[$j].id)/ownedObjects?`$select=id,displayName,groupTypes,mailEnabled,securityEnabled,membershipRule&`$top=999"
            }
        }
        
        # Create batch requests for transitive memberships
        $membershipsRequests = @()
        foreach ($j in 0..($batchUsers.Count - 1)) {
            $membershipsRequests += @{
                id = "member_$j"
                method = "GET"
                url = "/users/$($batchUsers[$j].id)/transitiveMemberOf/microsoft.graph.group?`$select=id,displayName,groupTypes,mailEnabled,securityEnabled,membershipRule&`$top=999"
            }
        }
        
        # Running batch request for Owned Objects
        $ownedObjectsResponse = New-GraphQuery -Method POST -Uri "$($global:octo.graphbatchUrl)" -Body (@{"requests"=@($ownedObjectsRequests)} | ConvertTo-Json -Depth 10) -NoRetry
        
        # Running batch request for Memberships
        $membershipsResponse = New-GraphQuery -Method POST -Uri "$($global:octo.graphbatchUrl)" -Body (@{"requests"=@($membershipsRequests)} | ConvertTo-Json -Depth 10) -NoRetry
        
        foreach ($j in 0..($batchUsers.Count - 1)) {
            $entraUser = $batchUsers[$j]
            $count++
            
            if($entraUser.userPrincipalName -like "*#EXT#@*") {
                $principalType = "External User"
            } else {
                $principalType = "Internal User"
            }
            
            <#
                The following code is used to extract the owned objects and memberships from the batch responses.
                It checks if the response contains a value and assigns it to the respective variable.
                If not, it initializes it as an empty array to avoid null reference errors and to ensure that previous loop data is not carried over.
            #>
            $ownedObjects = $ownedObjectsResponse.responses | Where-Object { $_.id -eq "owned_$j" } | Select-Object -ExpandProperty body
            if ($ownedObjects.value) { $ownedObjects = $ownedObjects.value } else { $ownedObjects = @() }
            
            $memberships = $membershipsResponse.responses | Where-Object { $_.id -eq "member_$j" } | Select-Object -ExpandProperty body
            if ($memberships.value) { $memberships = $memberships.value } else { $memberships = @() }
            
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
    }

    Write-Progress -Id 2 -Completed

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