function Get-M365ScanStatus {
    <#
    .SYNOPSIS
        Gets the progress of the current or most recent scan.
    .EXAMPLE
        Get-M365ScanStatus
    #>
    [CmdletBinding()]
    param()

    $engine = Get-M365Engine
    $progress = $engine.GetScanProgress()
    if ($null -eq $progress) {
        Write-Host "No scan in progress." -ForegroundColor Yellow
        return
    }
    return $progress
}
