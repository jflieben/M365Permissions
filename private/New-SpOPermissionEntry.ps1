Function New-SpOPermissionEntry{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>    
    Param(
        [Parameter(Mandatory=$true)]$Permission,
        [Parameter(Mandatory=$true)]$targetPath
    )

    if($Permission.principalSysId -in ("SHAREPOINT\system")){
        Write-LogMessage -level 5 -message "Skipping permission $($Permission.principalSysId) as it is a system account"
        return $Null
    }

    if(!$global:octo.userConfig.includeCurrentUser -and ($Permission.principalEntraId -eq $global:octo.currentUser.id -or $Permission.principalSysId -like "*$($global:octo.currentUser.userPrincipalName)*")){
        Write-LogMessage -level 5 -message "Skipping permission $($Permission.principalSysId) as it is the auditor account"
        return $Null
    }

    if(!($global:SPOPermissions.Keys -Contains $targetPath)){
        $global:SPOPermissions.$($targetPath) = @()
    }elseif($global:SPOPermissions.$($targetPath) -Contains $Permission){
        Write-LogMessage -level 5 -message "Not adding permission $($Permission.principalSysId) to $targetPath as it is already present"
        return $Null
    }

    Write-LogMessage -level 5 -message "Adding permission $($Permission.principalRole) for $($Permission.principalSysId) to $targetPath"
    $global:SPOPermissions.$($targetPath) += $Permission    
}
