function Disconnect-M365 {
    <#
    .SYNOPSIS
        Disconnects the current Microsoft 365 session.
    .EXAMPLE
        Disconnect-M365
    #>
    [CmdletBinding()]
    param()

    $engine = Get-M365Engine
    $engine.Disconnect()
    Write-Host "Disconnected from Microsoft 365" -ForegroundColor Yellow
}
