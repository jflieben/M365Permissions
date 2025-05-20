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

Measure-Command -Expression {
    get-EntraUsersAndGroupsBatch -entraUsers $entraUsers
}
<#
Initial test with the existing function
$entraUsers.count
100

Days              : 0
Hours             : 0
Minutes           : 1
Seconds           : 15
Milliseconds      : 203
Ticks             : 752031409
TotalDays         : 0,00087040672337963
TotalHours        : 0,0208897613611111
TotalMinutes      : 1,25338568166667
TotalSeconds      : 75,2031409
TotalMilliseconds : 75203,1409
#>

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
        $ownedObjectsResponse = New-GraphQuery -Method POST -Uri "$($global:octo.graphbatchUrl)" -Body (@{"requests"=@($ownedObjectsRequests)} | ConvertTo-Json -Depth 10)
        
        # Running batch request for Memberships
        $membershipsResponse = New-GraphQuery -Method POST -Uri "$($global:octo.graphbatchUrl)" -Body (@{"requests"=@($ownedObjectsRequests)} | ConvertTo-Json -Depth 10)
        
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

Measure-Command -Expression {
    get-EntraUsersAndGroupsBatch -entraUsers $entraUsers
}
<#
Initial test with batch request implemented
$entraUsers.count
100

Days              : 0
Hours             : 0
Minutes           : 0
Seconds           : 5
Milliseconds      : 209
Ticks             : 52091435
TotalDays         : 6,02910127314815E-05
TotalHours        : 0,00144698430555556
TotalMinutes      : 0,0868190583333333
TotalSeconds      : 5,2091435
TotalMilliseconds : 5209,1435
#>