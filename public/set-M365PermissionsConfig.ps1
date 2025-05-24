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
        -logLevel: the level of logging to use, either Full, Normal, Minimal or None. Full will log everything, None will log nothing, even errors. Normal and minimal are in between. Use Full for troubleshooting.
        -respectSiteLocks: if set to True (default is False), the script will respect site locks when scanning SharePoint sites. By default, this is set to false which means the script will remove a lock if it exists and reapply it when done scanning. This ONLY happens when scanning as a user, Service Principals do not need to unlock a site first
        -cloudType: global, usgov, usdod, china. Default: global
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
        [String]$logLevel,
        [Boolean]$respectSiteLocks,
        [ValidateSet('global','usgov','usdod','china')]	
        [String]$cloudType
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
        "respectSiteLocks" = [Boolean]$false
        "cloudType" = [String]"global"
    }

    $configLocation = Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy\M365Permissions.conf"
    if(!(Test-Path $configLocation)){
        $preferredConfig = @{}
    }else{
        $preferredConfig = Get-Content -Path $configLocation | ConvertFrom-Json -AsHashtable
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
        $global:octo.userConfig.outputFolder = (Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy\Reports")
    }

    if($global:octo.sessionIdentifier -and !$global:octo.userConfig.outputFolder.EndsWith($global:octo.sessionIdentifier)){
        $global:octo.userConfig.outputFolder = "$($global:octo.userConfig.outputFolder)\$($global:octo.sessionIdentifier)"
    }

    #set login url's based on selected Cloud
    switch($global:octo.userConfig.cloudType){
        'global' {
            $global:octo.idpUrl = "https://login.microsoftonline.com"
            $global:octo.graphUrl = "https://graph.microsoft.com"
            $global:octo.graphbatchUrl = "https://graph.microsoft.com/v1.0/`$batch"
            $global:octo.sharepointUrl = "sharepoint.com"
            $global:octo.outlookUrl = "outlook.office365.com"
            $global:octo.azureUrl = "https://management.azure.com"
            $global:octo.fabricUrl = "https://api.fabric.microsoft.com"
            $global:octo.powerbiUrl = "https://api.powerbi.com"
            $global:octo.babUrl = "https://api.bap.microsoft.com"
            $global:octo.flowUrl = "https://api.flow.microsoft.com"
            $global:octo.pappsUrl = "https://api.powerapps.com"
            $global:octo.ppResource = "https://service.powerapps.com"
        }
        'usgov' {
            $global:octo.idpUrl = "https://login.microsoftonline.us"
            $global:octo.graphUrl = "https://graph.microsoft.us"
            $global:octo.sharepointUrl = "sharepoint.us"
            $global:octo.outlookUrl = "outlook.office365.us"
            $global:octo.azureUrl = "https://management.usgovcloudapi.net"
            $global:octo.fabricUrl = "https://api.fabric.microsoft.us"
            $global:octo.powerbiUrl = "https://api.powerbi.us"
            $global:octo.babUrl = "https://gov.api.bap.microsoft.us"
            $global:octo.flowUrl = "https://api.flow.microsoft.us"
            $global:octo.pappsUrl = "https://api.powerapps.us"
            $global:octo.ppResource = "https://gov.service.powerapps.us"
        }
        'usdod' {
            $global:octo.idpUrl = "https://login.microsoftonline.us"
            $global:octo.graphUrl = "https://dod-graph.microsoft.us"
            $global:octo.sharepointUrl = "sharepoint-mil.us"
            $global:octo.outlookUrl = "outlook-dod.office365.us"
            $global:octo.azureUrl = "https://management.usgovcloudapi.net" #not sure if this one is even remotely correct
            $global:octo.fabricUrl = "https://api.fabric.microsoft.us"
            $global:octo.powerbiUrl = "https://api.powerbi.us"
            $global:octo.babUrl = "https://api.bap.appsplatform.us"
            $global:octo.flowUrl = "https://api.flow.microsoft.us" #not sure if this one is even remotely correct
            $global:octo.pappsUrl = "https://api.powerapps.us" #not sure if this one is even remotely correct
            $global:octo.ppResource = "https://service.apps.appsplatform.us"
        }
        'china' {
            $global:octo.idpUrl = "https://login.chinacloudapi.cn"
            $global:octo.graphUrl = "https://microsoftgraph.chinacloudapi.cn"
            $global:octo.sharepointUrl = "sharepoint.cn"
            $global:octo.outlookUrl = "partner.outlook.cn"
            $global:octo.azureUrl = "https://management.chinacloudapi.cn"
            $global:octo.fabricUrl = "https://api.fabric.microsoft.cn" #not sure if this one is even remotely correct
            $global:octo.powerbiUrl = "https://api.powerbi.cn" #not sure if this one is even remotely correct
            $global:octo.babUrl = "https://api.bap.partner.microsoftonline.cn"
            $global:octo.flowUrl = "https://api.flow.microsoft.cn" #not sure if this one is even remotely correct
            $global:octo.pappsUrl = "https://api.powerapps.cn" #not sure if this one is even remotely correct
            $global:octo.ppResource = "https://service.powerapps.cn" #not sure if this one is even remotely correct
        }
    }
}