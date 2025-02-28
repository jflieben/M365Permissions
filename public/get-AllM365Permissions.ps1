Function get-AllM365Permissions{   
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>         
    Param(
        [Switch]$expandGroups
    )

    Write-LogMessage -message "Starting FULL M365 Tenant scan as $($global:octo.currentUser.userPrincipalName)"
    Write-LogMessage -message "Planned scan order:"
    Write-LogMessage -message "1. PowerBI permissions"
    Write-LogMessage -message "2. Entra permissions"
    Write-LogMessage -message "3. Exchange permissions"
    Write-LogMessage -message "4. Onedrive permissions"
    Write-LogMessage -message "5. Teams and Sharepoint permissions"

    get-AllPBIPermissions -expandGroups:$expandGroups.IsPresent
    get-AllEntraPermissions -expandGroups:$expandGroups.IsPresent
    get-AllExOPermissions -expandGroups:$expandGroups.IsPresent -includeFolderLevelPermissions
    get-AllSpOPermissions -expandGroups:$expandGroups.IsPresent -includeOnedriveSites
}