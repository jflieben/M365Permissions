function get-AllEntraUsersAndGroups {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     

    New-StatisticsObject -category "GroupsAndMembers" -subject "Entities"
    Write-Progress -Id 1 -PercentComplete 0 -Activity "Scanning Entra ID" -Status "Getting users and groups" 

    $userCount = (New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/users?$top=1' -Method GET -ComplexFilter -nopagination)."@odata.count"
    Write-Host "Retrieving metadata for $userCount users..."
    Write-Progress -Id 1 -PercentComplete 1 -Activity "Scanning Entra ID" -Status "Getting users and groups" 

    $allUsersAndOwnedObjects = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/users?$select=id,userPrincipalName,displayName&$expand=ownedObjects' -Method GET
    Write-Host "Got ownership metadata"
    $allUsersAndTheirGroups = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/users?$select=id,userPrincipalName,displayName&$expand=transitiveMemberOf/microsoft.graph.group' -Method GET
    Write-Host "Got group membership metadata"

    [System.GC]::GetTotalMemory($true) | out-null

    #get over the expand limit of 20 objects
    for($i=0;$i -lt $allUsersAndOwnedObjects.Count;$i++){
        Write-Progress -Id 2 -PercentComplete $(try{($i+1) / $allUsersAndOwnedObjects.Count *100}catch{1}) -Activity "Getting ownership for users with > 20 owned groups" -Status "$($i+1) / $($allUsersAndOwnedObjects.Count) $($allUsersAndOwnedObjects[$i].displayName)"
        if($allUsersAndOwnedObjects[$i].ownedObjects.Count -ge 20){
            $allUsersAndOwnedObjects[$i].ownedObjects = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/users/$($allUsersAndOwnedObjects[$i].id)/ownedObjects?`$select=id,displayName,groupTypes,mailEnabled,securityEnabled,membershipRule&`$top=999" -Method GET
        }
    }
    Write-Progress -Id 2 -Completed -Activity "Getting ownership for users with > 20 owned groups"

    for($i=0;$i -lt $allUsersAndTheirGroups.Count;$i++){
        Write-Progress -Id 2 -PercentComplete $(try{($i+1) / $allUsersAndTheirGroups.Count *100}catch{1}) -Activity "Getting membership for users in > 20 groups" -Status "$($i+1) / $($allUsersAndTheirGroups.Count) $($allUsersAndTheirGroups[$i].displayName)"
        if($allUsersAndTheirGroups[$i].transitiveMemberOf.Count -ge 20){
            $allUsersAndTheirGroups[$i].transitiveMemberOf = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/users/$($allUsersAndTheirGroups[$i].id)/transitiveMemberOf/microsoft.graph.group?`$select=id,displayName,groupTypes,mailEnabled,securityEnabled,membershipRule&`$top=999" -Method GET
        }
    }
    Write-Progress -Id 2 -Completed -Activity "Getting membership for users in > 20 groups"        

    [System.GC]::GetTotalMemory($true) | out-null

    [System.Collections.ArrayList]$groupMemberRows = @()
    $count = 0
    foreach($user in $allUsersAndTheirGroups){
        $count++
        $ownerInfo = $Null; $ownerInfo = $allUsersAndOwnedObjects | Where-Object { $_.id -eq $user.id }
        if($user.userPrincipalName -like "*#EXT#@*"){
            $principalType = "External User"
        }else{
            $principalType = "Internal User"
        }
        
        Update-StatisticsObject -category "GroupsAndMembers" -subject "Entities"
        Write-Progress -Id 2 -PercentComplete $(try{$count / $allUsersAndTheirGroups.Count *100}catch{1}) -Activity "Processing users and groups" -Status "$count / $($allUsersAndTheirGroups.Count) $($user.displayName)"
        foreach($groupMembership in $user.transitiveMemberOf){
            $groupType = Get-EntraGroupType -group $groupMembership

            if($ownerInfo.ownedObjects.id -contains $groupMembership.id){
                $memberRoles = "Member,Owner"
            }else{
                $memberRoles = "Member"
            }

            $groupMemberRows.Add([PSCustomObject]@{
                "GroupName" = $groupMembership.displayName
                "GroupType" = $groupType
                "GroupID" = $groupMembership.id
                "MemberName" = $user.displayName
                "MemberID" = $user.id
                "MemberType" = $principalType
                "Roles" = $memberRoles
            }) > $Null
        }

        foreach($ownedGroup in $ownerInfo.ownedObjects){
            #skip those groups a user is also member of (already processed above)
            if($user.transitiveMemberOf.id -contains $ownedGroup.id){
                continue
            }
            $groupType = Get-EntraGroupType -group $ownedGroup
            $groupMemberRows.Add([PSCustomObject]@{
                "GroupName" = $ownedGroup.displayName
                "GroupType" = $groupType
                "GroupID" = $ownedGroup.id
                "MemberName" = $user.displayName
                "MemberID" = $user.id
                "MemberType" = $principalType
                "Roles" = "Owner"
            }) > $Null
        }
    }

    #add objects such as spn's' ownership
    $count = 0
    foreach($user in $allUsersAndOwnedObjects){
        $count++
        Write-Progress -Id 2 -PercentComplete $(try{$count / $allUsersAndOwnedObjects.Count *100}catch{1}) -Activity "Processing entity ownerships" -Status "$count / $($allUsersAndOwnedObjects.Count) $($user.displayName)"            
        foreach($ownedObject in ($user.ownedObjects | where-object { $_."@odata.type" -ne "#microsoft.graph.group"})){
            Update-StatisticsObject -category "GroupsAndMembers" -subject "Entities"
            New-EntraPermissionEntry -path "/$($ownedObject.id) ($($ownedObject.displayName))" -type "$($ownedObject."@odata.type".Split(".")[2])" -principalId $user.id -roleDefinitionId "N/A" -principalName $user.displayName -principalUpn $user.userPrincipalName -principalType "User" -roleDefinitionName "Owner"
        }
    }

    Write-Progress -Id 2 -Completed -Activity "Processing users and groups"
    Stop-StatisticsObject -category "GroupsAndMembers" -subject "Entities"
    Add-ToReportQueue -permissions $groupMemberRows -category "GroupsAndMembers"
}