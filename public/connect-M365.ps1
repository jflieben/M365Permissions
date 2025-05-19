Function connect-M365{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Switch]$Delegated,
        [Switch]$ServicePrincipal,
        [Switch]$ManagedIdentity
    )

    $readyToConnect = $True

    #choose auth mode, env var trumps passed in param, trumps default / persisted from set-M365PermissionsConfig
    if($ManagedIdentity){
        $global:octo.userConfig.authMode = "ManagedIdentity"
    }elseif($ServicePrincipal){
        $global:octo.userConfig.authMode = "ServicePrincipal"
    }elseif($Delegated){
        $global:octo.userConfig.authMode = "Delegated"
    }elseif($Env:LCAUTHMODE){
        $global:octo.userConfig.authMode = $Env:LCAUTHMODE
    }elseif(!$global:octo.userConfig.authMode){
        $global:octo.userConfig.authMode = "Delegated"
    }

    #if we're doing delegated auth, use my multi-tenant app id
    if($global:octo.userConfig.authMode -eq "Delegated"){
        Write-LogMessage -message "Using default $($global:octo.userConfig.authMode) authentication..."
        $global:octo.userConfig.LCClientId = "0ee7aa45-310d-4b82-9cb5-11cc01ad38e4"
    }

    #SPN auth requires a clientid and tenantid by the customer either through env vars or set-M365PermissionsConfig
    if($global:octo.userConfig.authMode -eq "ServicePrincipal"){
        Write-LogMessage -message "Using $($global:octo.userConfig.authMode) authentication..."
        if($Env:LCCLIENTID){
            $global:octo.userConfig.LCClientId = $Env:LCCLIENTID
        }
        if($Env:LCTENANTID){
            $global:octo.userConfig.LCTenantId = $Env:LCTENANTID
        }   
        if(!$global:octo.userConfig.LCClientId -or !$global:octo.userConfig.LCTenantId){
            $readyToConnect = $False
            Write-Error "Service Principal authentication requires a ClientId and TenantId to be set, please run set-M365PermissionsConfig -LCClientId <clientid> -LCTenantId <tenantid> before connecting or configure LCCLIENTID and LCTENANTID as env variables" -ErrorAction Continue
        }
    }

    #Managed Identity auth requires a tenantid by the customer either through env vars or set-M365PermissionsConfig
    if($global:octo.userConfig.authMode -eq "ManagedIdentity"){
        Write-LogMessage -message "Using $($global:octo.userConfig.authMode) authentication..."
    }
    
    if($readyToConnect){
        Write-LogMessage -message ""
        try{
            $global:octo.connection = "Connecting"
            $global:octo.currentUser = Get-CurrentUser
            $global:octo.OnMicrosoft = (New-GraphQuery -Method GET -Uri "$($global:octo.graphUrl)/v1.0/domains?`$top=999" | Where-Object -Property isInitial -EQ $true).id 
            $global:octo.tenantName = $($global:octo.OnMicrosoft).Split(".")[0]
            $global:octo.sessionIdentifier = "$($global:octo.tenantName)_$((Get-Date).ToString("yyyyMMdd"))"
            if(!$global:octo.userConfig.outputFolder.EndsWith($global:octo.sessionIdentifier)){
                $global:octo.userConfig.outputFolder = "$($global:octo.userConfig.outputFolder)\$($global:octo.sessionIdentifier)"
                #write config to output folder for reference so each run's settings can be compared if needed
                if(!(Test-Path -Path $global:octo.userConfig.outputFolder)){
                    New-Item -Path $global:octo.userConfig.outputFolder -ItemType Directory -Force | Out-Null
                }
                Get-M365PermissionsConfig | ConvertTo-Json | Out-File -FilePath "$($global:octo.userConfig.outputFolder)\M365Permissions.config" -Force -Encoding UTF8
            }
            if(!(Test-Path -Path $global:octo.userConfig.outputFolder)){
                New-Item -Path $global:octo.userConfig.outputFolder -ItemType Directory -Force | Out-Null
            }
            $global:octo.connection = "Connected"
        }catch{
            Throw $_
        }

        Write-LogMessage -message "Authenticated successfully! Here are some examples using this module:"
        Write-LogMessage -message ""
        Write-LogMessage -message ">> Get-AllM365Permissions"
        
        Write-LogMessage -message ">> Get-AllExOPermissions -includeFolderLevelPermissions"
        
        Write-LogMessage -message ">> Get-ExOPermissions -recipientIdentity `$mailbox.Identity -includeFolderLevelPermissions"
        
        Write-LogMessage -message ">> Get-SpOPermissions -siteUrl `"https://tenant.sharepoint.com/sites/site`""
        
        Write-LogMessage -message ">> Get-SpOPermissions -teamName `"INT-Finance Department`""
        
        Write-LogMessage -message ">> get-AllSPOPermissions -IncludeOneDriveSites -ExcludeOtherSites"
        
        Write-LogMessage -message ">> get-AllEntraPermissions"    

        Write-LogMessage -message ">> get-AllPBIPermissions" 

        Write-LogMessage -message ">> get-PowerPlatformPermissions" 
        
        Write-LogMessage -message ">> Get-ChangedPermissions"   

        Write-LogMessage -message ""
    }  
}