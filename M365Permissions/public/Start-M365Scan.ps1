function Start-M365Scan {
    <#
    .SYNOPSIS
        Starts a permission scan across selected Microsoft 365 services.
    .PARAMETER ScanTypes
        Which services to scan. Default is all available: SharePoint, Entra, Exchange.
    .EXAMPLE
        Start-M365Scan
    .EXAMPLE
        Start-M365Scan -ScanTypes SharePoint, Entra
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('SharePoint', 'Entra', 'Exchange', 'OneDrive', 'PowerBI', 'PowerAutomate', 'Azure', 'AzureDevOps', 'Purview')]
        [string[]]$ScanTypes = @('SharePoint', 'Entra', 'Exchange')
    )

    $engine = Get-M365Engine
    $task = $engine.StartScanAsync($ScanTypes)
    $scanId = $task.GetAwaiter().GetResult()
    Write-Host "Scan started (ID: $scanId). Use Get-M365ScanStatus to monitor progress." -ForegroundColor Cyan
    return $scanId
}
