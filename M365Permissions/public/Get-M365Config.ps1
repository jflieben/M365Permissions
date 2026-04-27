function Get-M365Config {
    <#
    .SYNOPSIS
        Retrieves the current module configuration.
    .EXAMPLE
        Get-M365Config
    #>
    [CmdletBinding()]
    param()

    $engine = Get-M365Engine
    return $engine.GetConfig()
}
