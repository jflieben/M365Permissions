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

    $global:EntraPermissions = @{}

    [System.Collections.ArrayList]$entraUserRows = @()
    $count = 0
    foreach($entraUser in $entraUsers){
        $count++
        Write-Progress -Id 2 -PercentComplete $(try{$count / $entraUsers.Count *100}catch{1}) -Activity "Processing user batch" -Status "$count / $($entraUsers.Count) $($entraUser.displayName)"       
        if($entraUser.userPrincipalName -like "*#EXT#@*"){
            $principalType = "External User"
        }else{
            $principalType = "Internal User"
        }

        $ownedObjects = New-GraphQuery -Uri  "$($global:octo.graphUrl)/v1.0/users/$($entraUser.id)/ownedObjects?`$select=id,displayName,groupTypes,mailEnabled,securityEnabled,membershipRule&`$top=999" -Method GET
        $memberships = New-GraphQuery -Uri  "$($global:octo.graphUrl)/v1.0/users/$($entraUser.id)/transitiveMemberOf/microsoft.graph.group?`$select=id,displayName,groupTypes,mailEnabled,securityEnabled,membershipRule&`$top=999" -Method GET
        
        foreach($membership in $memberships){
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

        foreach($ownedObject in $ownedObjects){
            if($ownedObject."@odata.type" -eq "#microsoft.graph.group"){
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
            }else{
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

    Write-Progress -Id 2 -Completed

    [System.GC]::GetTotalMemory($true) | out-null

    Add-ToReportQueue -permissions $entraUserRows -category "GroupsAndMembers"

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
}