function Set-M365Config {
    <#
    .SYNOPSIS
        Updates module configuration settings.
    .PARAMETER GuiPort
        TCP port for the web GUI (default 8080).
    .PARAMETER MaxThreads
        Maximum parallel threads for scanning (default 5).
    .PARAMETER OutputFormat
        Default export format: XLSX or CSV.
    .PARAMETER LogLevel
        Logging verbosity: Minimal, Normal, Verbose.
    .EXAMPLE
        Set-M365Config -GuiPort 9090 -MaxThreads 10
    #>
    [CmdletBinding()]
    param(
        [int]$GuiPort,
        [int]$MaxThreads,
        [ValidateSet('XLSX', 'CSV')]
        [string]$OutputFormat,
        [ValidateSet('Minimal', 'Normal', 'Verbose')]
        [string]$LogLevel
    )

    $engine = Get-M365Engine
    $config = $engine.GetConfig()

    if ($PSBoundParameters.ContainsKey('GuiPort'))     { $config.GuiPort = $GuiPort }
    if ($PSBoundParameters.ContainsKey('MaxThreads'))   { $config.MaxThreads = $MaxThreads }
    if ($PSBoundParameters.ContainsKey('OutputFormat')) { $config.OutputFormat = $OutputFormat }
    if ($PSBoundParameters.ContainsKey('LogLevel'))    { $config.LogLevel = $LogLevel }

    $engine.UpdateConfig($config)
    Write-Host "Configuration updated." -ForegroundColor Green
}
