@{
    RootModule           = 'M365Permissions.psm1'
    ModuleVersion        = '2.0.2'
    CompatiblePSEditions = @('Core')
    GUID                 = '748c97a1-b861-4bc5-8455-53494b565526'
    Author               = 'Jos Lieben (jos@lieben.nu)'
    CompanyName          = 'Lieben Consultancy'
    Copyright            = 'https://www.lieben.nu/liebensraum/commercial-use/'
    HelpInfoURI          = 'https://lieben.nu/liebensraum/m365permissions/'
    Description          = @'
M365Permissions - Microsoft 365 & Azure Permission Scanner

For the enterprise Azure-native version, see https://www.m365permissions.com

This module reports on permissions across SharePoint, Entra ID, Exchange Online, OneDrive, Power BI, Power Platform, Azure RBAC, and Azure DevOps.

INSTALLATION:
    Install-PSResource -Name M365Permissions -Repository PSGallery

USAGE:
    Import-Module M365Permissions   # Opens GUI automatically in your browser

Free for non-commercial use. See https://www.lieben.nu/liebensraum/commercial-use/
'@
    PowerShellVersion    = '7.4'

    # .NET assemblies loaded from lib/ subfolder
    RequiredAssemblies   = @(
        'lib\M365Permissions.Engine.dll',
        'lib\Microsoft.Data.Sqlite.dll',
        'lib\SQLitePCLRaw.core.dll',
        'lib\SQLitePCLRaw.provider.e_sqlite3.dll',
        'lib\SQLitePCLRaw.batteries_v2.dll',
        'lib\ClosedXML.dll',
        'lib\DocumentFormat.OpenXml.dll',
        'lib\SixLabors.Fonts.dll'
    )

    FunctionsToExport    = @(
        'Connect-M365',
        'Disconnect-M365',
        'Start-M365Scan',
        'Stop-M365Scan',
        'Start-M365GUI',
        'Stop-M365GUI'
    )

    CmdletsToExport      = @()
    VariablesToExport     = @()
    AliasesToExport       = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @('M365', 'Permissions', 'SharePoint', 'Entra', 'Exchange', 'Security', 'Audit')
            LicenseUri   = 'https://www.lieben.nu/liebensraum/commercial-use/'
            ProjectUri   = 'https://lieben.nu/liebensraum/m365permissions'
            ReleaseNotes = 'Initial release - V2 rewrite'
        }
    }
}
