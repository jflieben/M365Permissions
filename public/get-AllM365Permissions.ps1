Function get-AllM365Permissions{   
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>         
    Param(
    )

    Write-LogMessage -message "Starting FULL M365 Tenant scan as $($global:octo.currentUser.userPrincipalName)"
    Write-LogMessage -message "Planned scan order:"
    Write-LogMessage -message "1. PowerBI permissions"
    Write-LogMessage -message "2. Entra permissions"
    Write-LogMessage -message "3. Exchange permissions"
    Write-LogMessage -message "4. Onedrive permissions"
    Write-LogMessage -message "5. Teams and other Sharepoint permissions"
    Write-LogMessage -message "6. Entra device permissions"
    Write-LogMessage -message "7. Azure permissions"
    if($global:octo.userConfig.authMode -ne "Delegated"){ 
        Write-LogMessage -message "8. Power Platform permissions"
    }

    get-AllPBIPermissions -skipReportGeneration
    get-AllEntraPermissions -skipReportGeneration
    get-AllExOPermissions -includeFolderLevelPermissions -skipReportGeneration
    get-AllSpOPermissions -includeOnedriveSites -skipReportGeneration
    get-AllDevicePermissions -skipReportGeneration
    get-AllAzurePermissions -skipReportGeneration
    if($global:octo.userConfig.authMode -ne "Delegated"){ 
        get-PowerPlatformPermissions -skipReportGeneration
    }
    Write-Report
}