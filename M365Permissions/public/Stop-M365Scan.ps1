function Stop-M365Scan {
    <#
    .SYNOPSIS
        Cancels a running permission scan.
    .EXAMPLE
        Stop-M365Scan
    #>
    [CmdletBinding()]
    param()

    $engine = Get-M365Engine
    $engine.CancelScan()
    Write-Host "Scan cancellation requested." -ForegroundColor Yellow
}
