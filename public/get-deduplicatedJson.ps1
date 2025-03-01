Function Get-deduplicatedJson{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -permissionsFilePath: the path to the new permissions file. Leave both empty to auto-detect
        -reportFolder: the path to the new report folder. Leave both empty to auto-detect
    #>        
    Param(
        [Parameter(Mandatory=$false)][String]$permissionsFilePath,
        [Parameter(Mandatory=$false)][String]$reportFolder
    )

    if(!$permissionsFilePath -and !$reportFolder){
        if($global:octo.connection -eq "Connected"){
            Write-LogMessage -Level 4 -message "No permissions file path or report folder specified, auto-detecting based on session identifier $($global:octo.userConfig.sessionIdentifier) in $($global:octo.userConfig.outputFolder)"
        }else{
            Throw "Please run connect-M365 before using this function, OR specify the permissions file path manually using -permissionsFilePath or report folder using -reportFolder"
        }
        $reportFiles = Get-ChildItem -Path $global:octo.userConfig.outputFolder -Recurse -Filter "*.json" | Where-Object { $_.Name -notlike "*delta*" }
    }

    if($reportFolder){
        $reportFiles = Get-ChildItem -Path $reportFolder -Recurse -Filter "*.json" | Where-Object { $_.Name -notlike "*delta*" }
    }elseif($permissionsFilePath){
        $reportFiles = (Get-Item -Path $permissionsFilePath)
    }

    if($reportFiles.Count -lt 1){
        Throw "Less than 1 JSON reports found in $($reportFolder). Please run a scan first or specify the permission file path manually using -permissionsFilePath or report folder using -reportFolder"
    }    
    Write-LogMessage -message "Permissions files to deduplicate: $($reportFiles.Name)"

    $count = 0
    foreach($reportFile in $reportFiles){
        $count++
        Write-Progress -Id 1 -Activity "Deduplicating reports" -Status "$count/$($reportFiles.count) Loading content from $($reportFile.Name)" -PercentComplete 0
        Write-LogMessage -message "Deduplicating $($reportFile.Name)"
        $report = Get-Content -Path $reportFile.FullName | ConvertFrom-Json
        Write-Progress -Id 1 -Activity "Deduplicating reports" -Status "$count/$($reportFiles.count) Parsing objects from $($reportFile.Name)" -PercentComplete 0
        $uniqueObjects = [System.Collections.Generic.HashSet[string]]::new()
        $dedupedReport = $report | Where-Object {
            $hash = ($_ | ConvertTo-Json -Depth 1)
            $uniqueObjects.Add($hash)
        }
        Write-LogMessage -message "$($report.Count) reduced to $($dedupedReport.Count) rows in $($reportFile.Name), writing to file..." 
        Write-Progress -Id 1 -Activity "Deduplicating reports" -Status "$count/$($reportFiles.count) Writing back to $($reportFile.Name)" -PercentComplete 0
        $dedupedReport | ConvertTo-Json -Depth 100 | Out-File -Path $reportFile.FullName -Force
        [System.GC]::GetTotalMemory($true) | out-null
    }

    Write-Progress -Id 1 -Completed

    Write-LogMessage -message "Deduplication complete"
}