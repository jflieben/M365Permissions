Function New-SpOPermissionEntry{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>    
    Param(
        [Parameter(Mandatory=$true)]$Permission,
        [Parameter(Mandatory=$true)]$Path
    )

    if($Permission.Identity -in ("SHAREPOINT\system")){
        Write-LogMessage -level 5 -message "Skipping permission $($Permission.Identity) as it is a system account"
        return $Null
    }

    if(!$global:octo.userConfig.includeCurrentUser -and ($Permission.Email -eq $global:octo.currentUser.userPrincipalName -or $Permission.Identity -like "*$($global:octo.currentUser.userPrincipalName)*")){
        Write-LogMessage -level 5 -message "Skipping permission $($Permission.Email) as it is the auditor account"
        return $Null
    }

    if(!($global:SPOPermissions.Keys -Contains $Path)){
        $global:SPOPermissions.$($Path) = @()
    }elseif($global:SPOPermissions.$($Path) -Contains $Permission){
        Write-LogMessage -level 5 -message "Not adding permission $($Permission.Identity) to $Path as it is already present"
        return $Null
    }

    Write-LogMessage -level 5 -message "Adding permission $($Permission.Permission) for $($Permission.Identity) to $Path"
    $global:SPOPermissions.$($Path) += $Permission    
}
