Function New-DevicePermissionEntry{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>    
    Param(
        [Parameter(Mandatory=$true)]$targetPath,
        [Parameter(Mandatory=$true)]$targetType,
        [Parameter(Mandatory=$true)]$targetId,
        [Parameter(Mandatory=$false)]$principalEntraId,
        [Parameter(Mandatory=$false)]$principalEntraUpn,
        [Parameter(Mandatory=$false)]$principalSysId,
        [Parameter(Mandatory=$false)]$principalSysName,
        [Parameter(Mandatory=$false)]$principalType,
        [Parameter(Mandatory=$false)]$principalRole ="User",
        [Parameter(Mandatory=$false)]$through="Direct",
        [Parameter(Mandatory=$false)]$parentId = "",
        [Parameter(Mandatory=$false)][ValidateSet("Allow", "Deny")]$accessType = "Allow",
        [Parameter(Mandatory=$false)][ValidateSet("Permanent", "Eligible")]$tenure = "Permanent",
        [Parameter(Mandatory=$false)]$startDateTime,
        [Parameter(Mandatory=$false)]$endDateTime,
        [Parameter(Mandatory=$false)]$createdDateTime,
        [Parameter(Mandatory=$false)]$modifiedDateTime
    )

    if($global:octo.currentUser.userPrincipalName -eq $principalUpn -and !$global:octo.userConfig.includeCurrentUser){
        Write-LogMessage -level 5 -message "Skipping permission $($roleDefinitionName) scoped at $targetPath for $($principalUpn) as it is the auditor account"
        return $Null
    }

    switch ($principalType) {
        "#microsoft.graph.user" {
            if ($principalEntraUpn -like "*#EXT#@*") {
                $principalType = "External User"
            } else {
                $principalType = "Internal User"
            }
        }
        "#microsoft.graph.servicePrincipal" {
            $principalType = "Service Principal"
        }
        "#microsoft.graph.device" {
            $principalType = "Device"
        }
        "#microsoft.graph.group" {
            $principalType = "EntraSecurityGroup"
            $through = "EntraSecurityGroup"
        }
        Default {
            #leave unmodified
        }
    }

    Write-LogMessage -level 5 -message "Adding permission $($principalRole) scoped at $targetPath for $($principalEntraUpn) $($principalEntraId)"
    if(!$global:DevicePermissions.$targetPath){
        $global:DevicePermissions.$targetPath = @()
    }
    
    $global:DevicePermissions.$targetPath += [PSCustomObject]@{
        targetPath = $targetPath
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