function Stop-M365GUI {
    <#
    .SYNOPSIS
        Stops the web-based GUI server.
    .EXAMPLE
        Stop-M365GUI
    #>
    [CmdletBinding()]
    param()

    $engine = Get-M365Engine
    $engine.StopServerAsync().GetAwaiter().GetResult()
    Write-Host "GUI stopped." -ForegroundColor Yellow
}
