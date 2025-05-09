Function get-AllAzurePermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Switch]$skipReportGeneration
    )

    $activity = "Scanning Azure"
    Write-Progress -Id 1 -PercentComplete 1 -Activity $activity -Status "Getting subscriptions..."
    Write-LogMessage -level 4 -message "Getting subscriptions..."
    $subscriptions = New-GraphQuery -Uri "$($global:octo.azureUrl)/subscriptions?api-version=2020-01-01" -Method GET -resource "$($global:octo.azureUrl)/"
    Write-LogMessage -level 4 -message "$($subscriptions.Count) subscriptions retrieved :)"
    Write-Progress -Id 1 -PercentComplete 2 -Activity $activity -Status "Scanning subscriptions..."
    
    foreach($subscription in $subscriptions){
        New-ScanJob -Title $activity -Target $subscription.subscriptionId -FunctionToRun "get-AzurePermissions" -FunctionArguments @{
            "subscriptionId" = $subscription.subscriptionId
            "isParallel" = $True
        }
    }

    [System.GC]::GetTotalMemory($true) | out-null
    Write-LogMessage -message "Starting scan..."
    Start-ScanJobs -Title $activity
    
    if(!$skipReportGeneration){
        Write-LogMessage -message "Generating report..." -level 4
        Write-Report
    }
    Write-Progress -Id 1 -Completed -Activity $activity
}