function Remove-ReportFileLock {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     

    Param(
        [parameter(Mandatory=$true)]$lock
    )

    Write-LogMessage -level 5 -message "Waiting for 5 additional seconds to remove lock...."
    Start-Sleep -s 5
    $lock.Close()
    $lock.Dispose()
    Write-LogMessage -level 5 -message "Lock removed!"
}