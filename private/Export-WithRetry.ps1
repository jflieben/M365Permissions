function Export-WithRetry {
    param(
        [parameter(Mandatory = $true)][string]$category,
        [parameter(Mandatory = $true)][object]$data
    )

    $basePath = Join-Path -Path $global:octo.userConfig.outputFolder -ChildPath "M365Permissions_$($global:octo.sessionIdentifier).@@@"

    switch ($global:octo.userConfig.outputFormat) {
        "XLSX" { 
            $targetPath = $basePath.Replace("@@@", "xlsx")
        }
        "CSV" { 
            $targetPath = $basePath.Replace(".@@@", "$($category).csv")
        }
    }           

    try {
        if ($global:octo.userConfig.outputFormat -eq "XLSX") {
            $lock = New-ReportFileLock
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
    } catch {
        Write-Error $_ -ErrorAction Continue
        Write-Error "Failed to write to $targetPath" -ErrorAction Stop
    } finally {
        if ($global:octo.userConfig.outputFormat -eq "XLSX") {
            Remove-ReportFileLock -lock $lock
        }
    }
}