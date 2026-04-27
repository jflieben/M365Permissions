function Compare-M365Scans {
    <#
    .SYNOPSIS
        Compares two scan results to find permission changes (added, removed, changed).
    .PARAMETER OldScanId
        The scan ID for the baseline.
    .PARAMETER NewScanId
        The scan ID for the comparison.
    .EXAMPLE
        Compare-M365Scans -OldScanId 1 -NewScanId 2
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long]$OldScanId,

        [Parameter(Mandatory)]
        [long]$NewScanId
    )

    $engine = Get-M365Engine
    return $engine.CompareScans($OldScanId, $NewScanId)
}
