function New-ReportFileLock {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     

    $lockFilePath = Join-Path -Path $global:octo.userConfig.outputFolder -ChildPath "M365Permissions.lock"
    if(!(Test-Path -Path $lockFilePath)){
        Write-LogMessage -level 5 -message "Creating lock file..."  
        $Null = New-Item -Path $lockFilePath -ItemType File -Force | Out-Null
        Write-LogMessage -level 5 -message "Lock file created!"
    }
    Write-LogMessage -level 5 -message "Creating lock..."
    while($True){
        try{
            $lock = [System.IO.File]::Open($lockFilePath, 'OpenOrCreate', 'ReadWrite', 'None')
            break
        }catch{
            Write-LogMessage -level 5 -message "Could not lock file, waiting for other process..."
            Start-Sleep -Seconds 1
        }
    }
    Write-LogMessage -level 5 -message "Lock created!"
    return $lock
}