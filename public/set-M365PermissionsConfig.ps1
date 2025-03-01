Function set-M365PermissionsConfig{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -maxThreads: the maximum amount of threads to use for parallel processing, by default 5. Ensure you've read my blog before increasing this.
        -outputFolder: the path to the folder where you want to save permissions. By default it'll create the file under AppData\Roaming\LiebenConsultancy\M365Permissions\Reports
        -outputFormat: XLSX or CSV
        -Verbose: if set, verbose output will be shown everywhere (=very chatty)
        -includeCurrentUser: add entries for the user performing the audit (as this user will have all access, it'll clutter the report)
        -defaultTimeoutMinutes: the default timeout in minutes for all parallelized jobs, by default 120 minutes
        -maxJobRetries: the amount of times a job will be retried if it fails, by default 3
        -autoConnect: if set, the script will automatically connect to M365 using the configured authentication method, or default to Delegated if none has been set
        -LCClientId: the client id of the service principal to use for Service Principal authentication
        -LCTenantId: the tenant id of the service principal to use for Service Principal authentication
        -authMode: the authentication method to use, either Delegated (Interactive), ServicePrincipal or ManagedIdentity (Azure VM/Runbook/Functions etc)
    #>        
    Param(
        [Int]$maxThreads,
        [String]$outputFolder,
        [ValidateSet('XLSX','CSV')]
        [String]$outputFormat,
        [Boolean]$includeCurrentUser,
        [Int]$defaultTimeoutMinutes,
        [Int]$maxJobRetries,
        [Boolean]$autoConnect,
        [String]$LCClientId,
        [String]$LCTenantId,
        [ValidateSet('Delegated','ServicePrincipal','ManagedIdentity')]	
        [String]$authMode,
        [ValidateSet('Full','Normal','Minimal','None')]	
        [String]$logLevel    
    )

    $defaultConfig = @{
        "maxThreads" = [Int]5
        "outputFolder" = [String]"CURRENTFOLDER"
        "outputFormat" = [String]"XLSX"
        "includeCurrentUser" = [Boolean]$false
        "defaultTimeoutMinutes" = [Int]120
        "maxJobRetries" = [Int]3
        "autoConnect" = [Boolean]$false
        "LCClientId" = [String]$Null
        "LCTenantId" = [String]$Null
        "authMode" = [String]"Delegated"
        "logLevel" = [String]"Minimal"
    }

    $configLocation = Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy\M365Permissions.conf"
    if(!(Test-Path $configLocation)){
        $preferredConfig = @{}
    }else{
        $preferredConfig = Get-Content -Path $configLocation | ConvertFrom-Json -AsHashtable
    }

    $reportsFolder = Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy\Reports"
    if(!(Test-Path $reportsFolder)){
        New-Item -Path $reportsFolder -ItemType Directory -Force | Out-Null
    }

    $tempFolder = Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy\Temp"
    if(!(Test-Path $tempFolder)){
        New-Item -Path $tempFolder -ItemType Directory -Force | Out-Null
    }    

    #ensure verbose preferences are set in main process
    if($logLevel  -eq "Full" -or $preferredConfig.logLevel -eq "Full"){
        $global:VerbosePreference = "Continue"
        $global:InformationPreference = "Continue"
        $global:DebugPreference = "Continue"
    }else{
        $global:VerbosePreference = "SilentlyContinue"
        $global:InformationPreference = "SilentlyContinue"
        $global:DebugPreference = "SilentlyContinue"
    }

    #override cached config with any passed in parameters (and only those we explicitly defined in the default config options)
    $updateConfigFile = $false
    foreach($passedParam in $PSBoundParameters.GetEnumerator()){
        if($defaultConfig.ContainsKey($passedParam.Key)){
            $preferredConfig.$($passedParam.Key) = $passedParam.Value
            Write-LogMessage -level 5 -message "Persisted $($passedParam.Key) to $($passedParam.Value) for your account"
            $updateConfigFile = $true
        }
    }

    #set global vars based on customization and/or defaults
    foreach($configurable in $defaultConfig.GetEnumerator()){
        if($Null -ne $preferredConfig.$($configurable.Name)){
            Write-LogMessage -level 5 -message "Loaded $($configurable.Key) ($($preferredConfig.$($configurable.Name))) from persisted settings in $configLocation"
            $global:octo.userConfig.$($configurable.Name) = $preferredConfig.$($configurable.Name)
        }else{
            $global:octo.userConfig.$($configurable.Name) = $configurable.Value
        }
    }

    #update config file if needed
    if($updateConfigFile){
        Set-Content -Path $configLocation -Value $($preferredConfig | ConvertTo-Json) -Force
    }

    #override output folder with actual path
    if($global:octo.userConfig.outputFolder -eq "CURRENTFOLDER"){
        $global:octo.userConfig.outputFolder = $reportsFolder
    }

    #configure a temp folder specific for this run
    $global:octo.outputTempFolder = Join-Path -Path $tempFolder -ChildPath "$((Get-Date).ToString("yyyyMMddHHmm"))"

    #run verbose log to file if verbose is on
    if($global:octo.userConfig.LogLevel -eq "Full"){
        try{Start-Transcript -Path $(Join-Path -Path $global:octo.outputTempFolder -ChildPath "M365PermissionsVerbose.log") -Force -Confirm:$False}catch{
            Write-LogMessage -level 5 -message "Transcript already running"
        }
    }
}