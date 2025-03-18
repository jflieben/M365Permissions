#requires -Modules Microsoft.PowerShell.Utility
<#
    .DESCRIPTION
    See .psd1

    .NOTES
    AUTHOR              : Jos Lieben (jos@lieben.nu)
    Copyright/License   : https://www.lieben.nu/liebensraum/commercial-use/
    CREATED             : 04/11/2024
    UPDATED             : See GitHub

    .LINK
    https://www.lieben.nu/liebensraum/m365permissions

    .ROADMAP
    1.1.x Dynamically add entra (and SPO?) groups and users while scanning other resources
    1.1.x check defender xdr options 
    1.1.x Assess if Azure RM should be added or if a good open source tool already exists
    1.1.x Assess SQL or PBI as data destinations
    1.1.x How to handle spo group membership pivoting if we don't expand spo group membership           
    1.1.x exo folder permission change results in update of LastModifiedTime attribute in 27/02/2025 15:07:10 format   
    1.1.x auto cleanup app registrations etc after a run?
    1.1.x support for Sharepoint AsApp authorizations                                                                                                                                      
#>                                                                                                                                              

$helperFunctions = @{
    private = @( Get-ChildItem -Path "$($PSScriptRoot)\private" -Filter '*.ps*1' -ErrorAction SilentlyContinue )
    public  = @( Get-ChildItem -Path "$($PSScriptRoot)\public" -Filter '*.ps*1' -ErrorAction SilentlyContinue )
}
ForEach ($helperFunction in (($helperFunctions.private + $helperFunctions.public) | Where-Object { $null -ne $_ })) {
    try {
        Switch -Regex ($helperFunction.Extension) {
            '\.ps(m|d)1' { $null = Import-Module -Name "$($helperFunction.FullName)" -Scope Global -Force }
            '\.ps1' { (. "$($helperFunction.FullName)") }
            default { Write-Warning -Message "[$($helperFunction.Name)] Unable to import module function" }
        }
    }
    catch {
        Write-Error -Message "[$($helperFunction.Name)] Unable to import function: $($error[1].Exception.Message)"
    }
}

if ($helperFunctions.public) { Export-ModuleMember -Alias * -Function @($helperFunctions.public.BaseName) }
if ($env:username -like "*joslieben*"){Export-ModuleMember -Alias * -Function @($helperFunctions.private.BaseName) }

#first load config, subsequent loads will detect global var and skip this section (multi-threading)
if(!$global:octo){
    $global:octo = [Hashtable]::Synchronized(@{})
    $global:octo.ScanJobs = @{}
    $global:octo.PnPGroupCache = @{}
    $global:octo.LCRefreshToken = $Null
    $global:octo.LCCachedTokens = @{}
    $global:octo.connection = "Pending"

    if ([Environment]::GetCommandLineArgs().Contains('-NonInteractive') -or $False -eq [System.Environment]::UserInteractive) {
        $global:octo.interactiveMode=$false
    } else {
        $global:octo.interactiveMode=$true
        cls
    }

    $global:octo.moduleVersion = (Get-Content -Path (Join-Path -Path $($PSScriptRoot) -ChildPath "M365Permissions.psd1") | Out-String | Invoke-Expression).ModuleVersion
    if((Split-Path $PSScriptRoot -Leaf) -eq "M365Permissions"){
        $global:octo.modulePath = $PSScriptRoot
    }else{
        $global:octo.modulePath = (Split-Path -Path $PSScriptRoot -Parent)
    }

    #sets default config of user-configurable settings, can be overridden by user calls to set-M365PermissionsConfig
    $global:octo.userConfig = @{}

    #create the base reports folder
    $reportsFolder = Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy\Reports"
    if(!(Test-Path $reportsFolder)){
        New-Item -Path $reportsFolder -ItemType Directory -Force | Out-Null
    }

    #create the base temp folder
    $tempFolder = Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy\Temp"
    if(!(Test-Path $tempFolder)){
        New-Item -Path $tempFolder -ItemType Directory -Force | Out-Null
    }   

    #configure a temp folder specific for this run
    $global:octo.outputTempFolder = Join-Path -Path $tempFolder -ChildPath "$((Get-Date).ToString("yyyyMMddHHmm"))"  
    if(!(Test-Path $global:octo.outputTempFolder)){
        $Null = New-Item -Path $global:octo.outputTempFolder -ItemType Directory -Force
    }      

    set-M365PermissionsConfig

    #run verbose log to file if verbose is on
    if($global:octo.userConfig.LogLevel -eq "Full"){
        Start-Transcript -Path $(Join-Path -Path $global:octo.outputTempFolder -ChildPath "M365PermissionsVerbose.log") -Force -Confirm:$False
    }    
        
    $global:runspacePool = [runspacefactory]::CreateRunspacePool(1, $global:octo.userConfig.maxThreads, ([system.management.automation.runspaces.initialsessionstate]::CreateDefault()), $Host)
    $global:runspacePool.ApartmentState = "STA"
    $global:runspacepool.Open() 
    
    Write-Host "----------------------------------"
    Write-Host "Welcome to M365Permissions v$($global:octo.moduleVersion)!"
    Write-Host "Visit https://www.lieben.nu/liebensraum/m365permissions/ for documentation"
    Write-Host "Free for non-commercial use, see https://www.lieben.nu/liebensraum/commercial-use/ for commercial use"
    Write-Host "----------------------------------"
    Write-Host ""

    if($global:octo.userConfig.autoConnect -eq $true){
        connect-M365
    }else{
        Write-Host "Before you can run a scan, please run connect-M365"
        Write-Host ""
        Write-Host "If you do not want to see this message in the future, run `"set-M365PermissionsConfig -autoConnect `$True`""
        Write-Host ""
    }
}

#automatically block display of progress bars in non-interactive mode
if(!$global:octo.interactiveMode){
    $ProgressPreference -eq "SilentlyContinue"
}

if($global:octo.userConfig.logLevel -eq "Full"){
    $global:VerbosePreference = "Continue"
    $global:InformationPreference = "Continue"
    $global:DebugPreference = "Continue"
}else{
    $global:VerbosePreference = "SilentlyContinue"
    $global:InformationPreference = "SilentlyContinue"
    $global:DebugPreference = "SilentlyContinue"
}