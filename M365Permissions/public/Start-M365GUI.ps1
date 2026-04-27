function Start-M365GUI {
    <#
    .SYNOPSIS
        Starts the web-based GUI for M365Permissions.
    .PARAMETER Port
        TCP port to listen on. Uses configured GuiPort if not specified.
    .EXAMPLE
        Start-M365GUI
    .EXAMPLE
        Start-M365GUI -Port 9090
    #>
    [CmdletBinding()]
    param(
        [int]$Port
    )

    $engine = Get-M365Engine
    if (-not $Port) {
        $Port = ($engine.GetConfig()).GuiPort
    }

    $engine.StartServer($Port, $script:GuiRoot, $true)
    Write-Host "GUI started at http://localhost:$Port" -ForegroundColor Cyan
}
