function Connect-M365 {
    <#
    .SYNOPSIS
        Connects to Microsoft 365 using delegated authentication (browser-based PKCE flow).
    .DESCRIPTION
        Opens a browser window for the user to sign in with their Microsoft 365 account.
        Uses OAuth2 PKCE flow with a loopback redirect URI. No client secret needed.
    .EXAMPLE
        Connect-M365
    #>
    [CmdletBinding()]
    param()

    $engine = Get-M365Engine
    $task = $engine.ConnectAsync()
    $task.GetAwaiter().GetResult()
    $status = $engine.GetStatus()
    Write-Host "Connected to $($status.TenantDomain) as $($status.UserPrincipalName)" -ForegroundColor Green
}
