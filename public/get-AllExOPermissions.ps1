Function get-AllExOPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -expandGroups: if set, group memberships will be expanded to individual users
        -includeFolderLevelPermissions: if set, folder level permissions for each mailbox will be retrieved. This can be (very) slow

        Potential to do:
        only reason we need GA rights for EXO scanning is because get-recipientpermission doesn't support Global Reader, this could be fixed by modifying the scope in EXO but is a config change a customer would need to accept
    #>        
    Param(
        [Switch]$expandGroups,
        [Switch]$includeFolderLevelPermissions,
        [Switch]$skipReportGeneration
    )

    $activity = "Scanning Exchange Online"

    if($includeFolderLevelPermissions){
        Write-LogMessage -message "Including folder level permissions, this will lengthen the scan duration significantly"
    }

    Write-Progress -Id 1 -PercentComplete 1 -Activity $activity -Status "Scanning roles..."
    get-ExORoles -expandGroups:$expandGroups.IsPresent
    Write-Progress -Id 1 -PercentComplete 1 -Activity $activity -Status "Retrieving all recipients..."
    Write-LogMessage -message "Getting all recipients..."
    [System.GC]::GetTotalMemory($true) | out-null
    Write-Progress -Id 1 -PercentComplete 2 -Activity $activity -Status "Retrieving all recipients..."
    $global:octo.recipients = (New-ExOQuery -cmdlet "Get-Recipient" -cmdParams @{"ResultSize" = "Unlimited"}) | Where-Object{$_ -and !$_.Identity.StartsWith("DiscoverySearchMailbox")}
    foreach($recipient in $global:octo.recipients){
        New-ScanJob -Title $activity -Target $recipient.displayName -FunctionToRun "get-ExOPermissions" -FunctionArguments @{
            "recipientIdentity" = $recipient.Identity
            "expandGroups" = $expandGroups.IsPresent
            "includeFolderLevelPermissions" = $includeFolderLevelPermissions.IsPresent
            "isParallel" = $True
        }
    }
    [System.GC]::GetTotalMemory($true) | out-null
    Start-ScanJobs -Title $activity
    $global:octo.recipients = $Null
    if(!$skipReportGeneration){
        Write-LogMessage -message "Generating report..." -level 4
        Write-Report
    }
    Write-Progress -Id 1 -Completed -Activity $activity
}