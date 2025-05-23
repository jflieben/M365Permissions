function Write-Report {
    #flush all .xml's
    Reset-ReportQueue

    #ensure the JSON files have been deduplicated to reduce noise
    Get-deduplicatedJson

    #add a change detection run, silently (e.g. in case this is a first time run)
    try{
        Get-changedPermissions
    }catch{
        Write-LogMessage -Level 4 -Message "Failed to detect changes, continuing..."
    }

    $basePath = Join-Path -Path $global:octo.userConfig.outputFolder -ChildPath "M365Permissions.@@@"
      
    try {
        $sourceJSONFiles = Get-ChildItem -Path $global:octo.userConfig.outputFolder -Filter "*.json"
        Write-LogMessage -Level 5 -Message "Found $($sourceJSONFiles.Count) JSON files to process"
        foreach($JSONFile in $sourceJSONFiles){
            Write-LogMessage -Level 5 -Message "Sorting $($JSONFile.Name)"
            $data = Get-Content -Path $JSONFile.FullName | ConvertFrom-Json -Depth 2 | Sort-Object -Property "targetPath"
            $category = $JSONFile.Name.Split("_")[1].replace(".json","")
            Write-LogMessage -Level 5 -Message "Saving $($JSONFile.Name)"
            if($global:octo.userConfig.outputFormat -eq "XLSX"){
                if($JSONFile.Name.Split("_")[-1] -eq "delta.json"){
                    $targetPath = $basePath.Replace("M365Permissions", "M365Permissions_delta").Replace("@@@", "xlsx")
                }else{
                    $targetPath = $basePath.Replace("@@@", "xlsx")
                }
            }else {
                if($JSONFile.Name.Split("_")[-1] -eq "delta.json"){
                    continue #change detection is only for XLSX output
                }
                $targetPath = $basePath.Replace(".@@@", "$($category).csv")
            }

            $maxRetries = 60
            $attempts = 0
            while ($attempts -lt $maxRetries) {
                $attempts++
                try {
                    switch ($global:octo.userConfig.outputFormat) {
                        "XLSX" { $data | Export-Excel -NoNumberConversion "Module version" -Path $targetPath -WorksheetName $($category) -TableName $($category) -TableStyle Medium10 -AutoSize }
                        "CSV" { $data | Export-Csv -Path $targetPath -NoTypeInformation }
                    }
                    $attempts = $maxRetries
                    Write-LogMessage "Wrote $($data.count) rows for $category to $targetPath"
                } catch {
                    if ($attempts -eq $maxRetries) {
                        Throw
                    } else {
                        Write-LogMessage -level 5 -message "File locked, waiting..."
                        Start-Sleep -s (Get-Random -Minimum 1 -Maximum 3)
                    }
                }
            }
        }
    } catch {
        Write-Error $_ -ErrorAction Continue
        Write-Error "Failed to write to $targetPath" -ErrorAction Stop
    }
}