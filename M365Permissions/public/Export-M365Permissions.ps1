function Export-M365Permissions {
    <#
    .SYNOPSIS
        Exports scan results to XLSX or CSV file.
    .PARAMETER ScanId
        The scan ID to export. If omitted, uses the most recent scan.
    .PARAMETER Format
        Output format: XLSX or CSV. Default XLSX.
    .PARAMETER OutputPath
        File path to save the export. If omitted, saves to current directory.
    .EXAMPLE
        Export-M365Permissions
    .EXAMPLE
        Export-M365Permissions -ScanId 3 -Format CSV -OutputPath "C:\Reports\scan.csv"
    #>
    [CmdletBinding()]
    param(
        [long]$ScanId,
        [ValidateSet('XLSX', 'CSV')]
        [string]$Format = 'XLSX',
        [string]$OutputPath
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

    $bytes = $engine.ExportScan($ScanId, $Format.ToLower())
    $ext = if ($Format -eq 'XLSX') { '.xlsx' } else { '.csv' }

    if (-not $OutputPath) {
        $OutputPath = Join-Path (Get-Location) "M365Permissions_Scan${ScanId}${ext}"
    }

    [System.IO.File]::WriteAllBytes($OutputPath, $bytes)
    Write-Host "Exported to $OutputPath" -ForegroundColor Green
    return $OutputPath
}
