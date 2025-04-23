Function New-AzurePermissionEntry{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>    
    Param(
        [Parameter(Mandatory=$true)]$targetPath,
        [Parameter(Mandatory=$true)]$targetType,
        [Parameter(Mandatory=$true)]$targetId,
        [Parameter(Mandatory=$true)]$principalEntraId,
        [Parameter(Mandatory=$false)]$principalEntraUpn,
        [Parameter(Mandatory=$false)]$principalSysId,
        [Parameter(Mandatory=$false)]$principalSysName,
        [Parameter(Mandatory=$true)]$principalType,
        [Parameter(Mandatory=$true)]$principalRole,
        [Parameter(Mandatory=$false)]$through="Direct",
        [Parameter(Mandatory=$false)]$parentId = "",
        [Parameter(Mandatory=$true)][ValidateSet("Allow", "Deny")]$accessType,
        [Parameter(Mandatory=$true)][ValidateSet("Permanent", "Eligible")]$tenure,
        [Parameter(Mandatory=$false)]$startDateTime,
        [Parameter(Mandatory=$false)]$endDateTime,
        [Parameter(Mandatory=$false)]$createdDateTime,
        [Parameter(Mandatory=$false)]$modifiedDateTime
    )

    #grab and cache metadata on the principal
    $aadObj = get-aadObject -id $principalEntraId
    if($aadObj){
        $principalSysName = $aadObj.displayName
        $principalSysId = $aadObj.userPrincipalName
    }
    switch ($principalType) {
        "User" {
            if($aadObj){
                if ($aadObj.userPrincipalName -like "*#EXT#@*") {
                    $principalType = "External User"
                } else {
                    $principalType = "Internal User"
                }
            }else{
                $principalType = "Unknown User"
            }
        }
        "ServicePrincipal" {
            $principalType = "Service Principal"
        }
        "Group" {
            $principalType = "EntraSecurityGroup"
        }
        Default {
            #leave unmodified
        }
    }

    if($global:AzurePermissions){
        foreach($azPath in $global:AzurePermissions.Keys){
            if($targetPath.startsWith($azPath)){
                #the targetPath is a child of this path, we should check if the permission being submitted already matches a permission in this path
                foreach($permission in $global:AzurePermissions.$azPath){
                    if($permission.principalEntraId -eq $principalEntraId -and $permission.principalRole -eq $principalRole -and $permission.through -eq $through -and $permission.tenure -eq $tenure -and $permission.startDateTime -eq $startDateTime -and $permission.endDateTime -eq $endDateTime){
                        #permission already exists, skip it
                        Write-LogMessage -level 5 -message "Permission $($principalRole) scoped at $targetPath for $($principalSysName) $($principalEntraUpn) ($($principalEntraId)) already exists, skipping"
                        return
                    }
                }
            }
        }
    }

    Write-LogMessage -level 5 -message "Adding permission $($principalRole) scoped at $targetPath for $($principalSysName) $($principalEntraUpn) ($($principalEntraId))"
    if(!$global:AzurePermissions.$targetPath){
        $global:AzurePermissions.$targetPath = @()
    }

    $global:AzurePermissions.$targetPath += [PSCustomObject]@{
        targetType = $targetType
        targetId = $targetId
        principalEntraId = $principalEntraId
        principalSysId = $principalSysId
        principalSysName = $principalSysName
        principalType = $principalType
        principalRole = $principalRole
        through = $through
        parentId = $parentId   
        accessType = $accessType
        tenure = $tenure
        startDateTime = $startDateTime
        endDateTime = $endDateTime
        createdDateTime  = $createdDateTime
        modifiedDateTime  = $modifiedDateTime
    }
}