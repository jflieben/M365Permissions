# M365Permissions — Module entry point
# Initializes the .NET engine and auto-opens the GUI in interactive sessions.

$script:Engine = $null
$script:ModuleRoot = $PSScriptRoot
$script:GuiRoot = Join-Path $PSScriptRoot 'gui' 'static'

function Get-M365Engine {
    if ($null -eq $script:Engine) {
        $dbFolder = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'LiebenConsultancy' 'M365Permissions'
        if (-not (Test-Path $dbFolder)) { New-Item -ItemType Directory -Path $dbFolder -Force | Out-Null }
        $dbPath = Join-Path $dbFolder 'data.db'
        $script:Engine = [M365Permissions.Engine.Engine]::new($dbPath)
    }
    return $script:Engine
}

# Dot-source all public functions
$publicPath = Join-Path $PSScriptRoot 'public'
if (Test-Path $publicPath) {
    Get-ChildItem -Path $publicPath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

# Auto-start GUI on module import in interactive sessions (skip if M365_NO_AUTOSTART is set)
if ([Environment]::UserInteractive -and -not [Environment]::GetCommandLineArgs().Contains('-NonInteractive') -and -not $env:M365_NO_AUTOSTART) {
    try {
        $engine = Get-M365Engine
        $port = ($engine.GetConfig()).GuiPort
        $engine.StartServer($port, $script:GuiRoot, $true)
        Write-Host "M365Permissions GUI started at http://localhost:$port" -ForegroundColor Cyan
    }
    catch {
        Write-Warning "Failed to auto-start GUI: $_"
    }
}

# Shared cleanup logic
function script:Cleanup-Engine {
    if ($null -ne $script:Engine) {
        try {
            $null = $script:Engine.StopServerAsync().GetAwaiter().GetResult()
        } catch { }
        try {
            $script:Engine.Dispose()
        } catch { }
        $script:Engine = $null
    }
}

# Cleanup on module removal (Remove-Module)
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    script:Cleanup-Engine
}

# Cleanup on PowerShell process exit (closing the window)
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    script:Cleanup-Engine
} | Out-Null
