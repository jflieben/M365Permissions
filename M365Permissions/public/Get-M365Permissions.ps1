function Get-M365Permissions {
    <#
    .SYNOPSIS
        Retrieves permission entries from a completed scan.
    .PARAMETER ScanId
        The scan ID to query. If omitted, uses the most recent scan.
    .PARAMETER Category
        Filter by category (SharePoint, Entra, Exchange).
    .PARAMETER SearchText
        Free-text search across target paths and principal names.
    .PARAMETER Page
        Page number (1-based). Default 1.
    .PARAMETER PageSize
        Results per page. Default 100.
    .EXAMPLE
        Get-M365Permissions
    .EXAMPLE
        Get-M365Permissions -Category SharePoint -SearchText "contoso.com"
    #>
    [CmdletBinding()]
    param(
        [long]$ScanId,
        [string]$Category,
        [string]$SearchText,
        [int]$Page = 1,
        [int]$PageSize = 100
    )

    $engine = Get-M365Engine
    if ($ScanId -eq 0) {
        $scans = $engine.GetScans()
        if ($scans.Count -eq 0) {
            Write-Warning "No scans found. Run Start-M365Scan first."
            return
        }
        $ScanId = $scans[0].Id
    }
    return $engine.QueryPermissions($ScanId, $Category, $SearchText, $Page, $PageSize)
}
