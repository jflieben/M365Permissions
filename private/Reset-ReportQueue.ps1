function Reset-ReportQueue{
    Write-LogMessage -level 5 -message "Start Flushing report queue to data storage...."
    
    $dataBatch = @()
    $queuedFiles = Get-ChildItem -Path $global:octo.outputTempFolder -Filter "*.xml"
    if($queuedFiles.Count -gt 0){
        Write-LogMessage -level 5 -message "Reading batch of $($queuedFiles.Count) reports from $($global:octo.outputTempFolder)..."
        foreach($queuedFile in $queuedFiles){
            $dataBatch += Import-Clixml -Path $queuedFile.FullName
            Remove-Item -Path $queuedFile.FullName -Force
        }  
    }

    if($dataBatch){
        $statistics =$Null; $statistics = ($dataBatch | Where-Object{$_.statistics}).statistics
        if($statistics){
            $filePath = Join-Path -Path $global:octo.userConfig.outputFolder -ChildPath "M365Permissions_statistics.json"
            Write-ToJSONStorage -data $statistics -FilePath $filePath
        }
        $categories = $Null; $categories = ($dataBatch | Where-Object{$_.category}).category | select-object -Unique
        foreach($category in $categories){
            $permissions = $Null; $permissions = ($dataBatch | Where-Object {$_.category -eq $category -and $_.permissions}).permissions
            if($permissions){
                $filePath = Join-Path -Path $global:octo.userConfig.outputFolder -ChildPath "M365Permissions_$($category).json"
                Write-ToJSONStorage -data $permissions -FilePath $filePath
            }
        }   
        Write-LogMessage -level 5 -message "Wrote $($dataBatch.Count) reports to JSON storage in $($global:octo.userConfig.outputFolder) :)"
    }else{
        Write-LogMessage -level 5 -message "No reports to write to data storage..."
    }
    [System.GC]::GetTotalMemory($true) | out-null  
}