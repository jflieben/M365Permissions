Function New-ExOPermissionEntry{
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
        [Parameter(Mandatory=$true)]$principalType,
        [Parameter(Mandatory=$true)]$principalRole,
        [Parameter(Mandatory=$false)]$through,
        [Parameter(Mandatory=$false)]$parentId,
        [Parameter(Mandatory=$false)][ValidateSet("Allow", "Deny")]$accessType="Allow",
        [Parameter(Mandatory=$false)][ValidateSet("Permanent", "Eligible")]$tenure="Permanent",
        [Parameter(Mandatory=$false)]$startDateTime,
        [Parameter(Mandatory=$false)]$endDateTime,
        [Parameter(Mandatory=$false)]$createdDateTime,
        [Parameter(Mandatory=$false)]$modifiedDateTime
    )

    if($global:octo.currentUser.userPrincipalName -eq $principalEntraUpn -and !$global:octo.userConfig.includeCurrentUser){
        Write-LogMessage -level 5 -message "Skipping permission $($principalRole) scoped at $targetPath for $($principalEntraUpn) as it is the auditor account"
        return $Null
    }

    $Permission = [PSCustomObject]@{
        "targetPath" = $targetPath
        "targetType" = $targetType
        "targetId" = $targetId
        "principalEntraId" = $principalEntraId
        "principalEntraUpn" = $principalEntraUpn
        "principalSysId" = $principalSysId
        "principalSysName" = $principalSysName
        "principalType" = $principalType
        "principalRole" = $principalRole
        "through" = $through
        "parentId" = $parentId
        "accessType" = $accessType
        "tenure" = $tenure
        "startDateTime" = $startDateTime
        "endDateTime" = $endDateTime
        "createdDateTime" = $createdDateTime
        "modifiedDateTime" = $modifiedDateTime
    }

    if($global:ExOPermissions){
        #loop over entries
        foreach($exoPath in $global:ExOPermissions.GetEnumerator()){
            #entry starts with intended entry
            if($targetPath -contains $exoPath){
                if($global:ExOPermissions.$exoPath -contains $Permission){
                    Write-LogMessage -level 5 -message "Skipping permission $($principalRole) scoped at $targetPath for $($principalSysName) as it is already present"
                    return $Null
                }
                foreach($ExistingPermission in $global:ExOPermissions.$exoPath){
                    if($ExistingPermission.accessType -eq $accessType -and $ExistingPermission.through -eq $through -and $ExistingPermission.targetType -eq $targetType){
                        if($ExistingPermission.principalRole -eq "FullAccess"){
                            Write-LogMessage -level 5 -message "Skipping permission $($principalRole) scoped at $targetPath for $($principalSysName) as FullAccess already present"
                            return $Null
                        }
                        if($ExistingPermission.principalRole -eq $principalRole){
                            if($principalEntraUpn -and $ExistingPermission.principalEntraUpn -eq $principalEntraUpn){
                                Write-LogMessage -level 5 -message "Skipping permission $($principalRole) scoped at $targetPath for $($principalEntraUpn) as it is already present"
                                return $Null
                            }
                            if($principalEntraId -and $ExistingPermission.principalEntraId -eq $principalEntraId){
                                Write-LogMessage -level 5 -message "Skipping permission $($principalRole) scoped at $targetPath for $($principalEntraId) as it is already present"
                                return $Null
                            }
                            if($principalSysName -and $ExistingPermission.principalSysName -eq $principalSysName){
                                Write-LogMessage -level 5 -message "Skipping permission $($principalRole) scoped at $targetPath for $($principalSysName) as it is already present"
                                return $Null
                            }
                        }
                    }
                }
            }
        }
    }

    Write-LogMessage -level 5 -message "Adding permission $($principalRole) scoped at $targetPath for $($principalSysName)"
    if(!$global:ExOPermissions.$targetPath){
        $global:ExOPermissions.$targetPath = @()
    }
    $global:ExOPermissions.$targetPath += $Permission
}
