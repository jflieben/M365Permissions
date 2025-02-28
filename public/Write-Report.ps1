function Write-Report {
    #flush all .xml's
    Reset-ReportQueue

    $basePath = Join-Path -Path $global:octo.userConfig.outputFolder -ChildPath "M365Permissions.@@@"
      
    try {
        $sourceJSONFiles = Get-ChildItem -Path $global:octo.userConfig.outputFolder -Filter "*.json"
        Write-LogMessage -Level 5 -Message "Found $($sourceJSONFiles.Count) JSON files to process"
        foreach($JSONFile in $sourceJSONFiles){
            $data = Get-Content -Path $JSONFile.FullName | ConvertFrom-Json -Depth 5
            $category = $JSONFile.Name.Split("_")[-1].replace(".json","")
            switch ($global:octo.userConfig.outputFormat) {
                "XLSX" { 
                    $targetPath = $basePath.Replace("@@@", "xlsx")
                }
                "CSV" { 
                    $targetPath = $basePath.Replace(".@@@", "$($category).csv")
                }
            }   
            $maxRetries = 60
            $attempts = 0
            while ($attempts -lt $maxRetries) {
                $attempts++
                try {
                    switch ($global:octo.userConfig.outputFormat) {
                        "XLSX" { $data | Export-Excel -NoNumberConversion "Module version" -Path $targetPath -WorksheetName $($category) -TableName $($category) -TableStyle Medium10 -Append -AutoSize }
                        "CSV" { $data | Export-Csv -Path $targetPath -NoTypeInformation -Append }
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
        $sourceJSONFiles | % { Remove-Item -Path $_.FullName -Force }
    } catch {
        Write-Error $_ -ErrorAction Continue
        Write-Error "Failed to write to $targetPath" -ErrorAction Stop
    }
}