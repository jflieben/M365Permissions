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

    $connected = $True

    #choose auth mode, env var trumps passed in param, trumps default / persisted from set-M365PermissionsConfig
    if($ManagedIdentity){
        $global:octo.userConfig.authMode = "ManagedIdentity"
    }elseif($ServicePrincipal){
        $global:octo.userConfig.authMode = "ServicePrincipal"
    }elseif($Delegated){
        $global:octo.userConfig.authMode = "Delegated"
    }elseif($Env:LCAUTHMODE){
        $global:octo.userConfig.authMode = $Env:LCAUTHMODE
    }else{
        $global:octo.userConfig.authMode = "Delegated"
    }

    #if we're doing delegated auth, use my multi-tenant app id
    if($global:octo.userConfig.authMode -eq "Delegated"){
        Write-Host "Using default $($global:octo.userConfig.authMode) authentication..."
        $global:octo.userConfig.LCClientId = "0ee7aa45-310d-4b82-9cb5-11cc01ad38e4"
    }

    #SPN auth requires a clientid and tenantid by the customer either through env vars or set-M365PermissionsConfig
    if($global:octo.userConfig.authMode -eq "ServicePrincipal"){
        Write-Host "Using $($global:octo.userConfig.authMode) authentication..."
        if($Env:LCCLIENTID){
            $global:octo.userConfig.LCClientId = $Env:LCCLIENTID
        }
        if($Env:LCTENANTID){
            $global:octo.userConfig.LCTenantId = $Env:LCTENANTID
        }   
        if(!$global:octo.userConfig.LCClientId -or !$global:octo.userConfig.LCTenantId){
            $connected = $False
            Write-Error "Service Principal authentication requires a ClientId and TenantId to be set, please run set-M365PermissionsConfig -LCClientId <clientid> -LCTenantId <tenantid> before connecting or configure LCCLIENTID and LCTENANTID as env variables" -ErrorAction Continue
        }
    }

    #Managed Identity auth requires a tenantid by the customer either through env vars or set-M365PermissionsConfig
    if($global:octo.userConfig.authMode -eq "ManagedIdentity"){
        Write-Host "Using $($global:octo.userConfig.authMode) authentication..."
    }
    
    if($connected){
        Write-Host ""
        try{
            $global:octo.currentUser = Get-CurrentUser
            $global:octo.OnMicrosoft = (New-GraphQuery -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$top=999' | Where-Object -Property isInitial -EQ $true).id 
            $global:octo.tenantName = $($global:octo.OnMicrosoft).Split(".")[0]
            $global:octo.isConnected = $True
        }catch{
            Throw $_
        }

        Write-Host "Authenticated successfully! Here are some examples using this module:"
        Write-Host ""
        Write-Host ">> Get-AllM365Permissions -expandGroups"
        
        Write-Host ">> Get-AllExOPermissions -includeFolderLevelPermissions"
        
        Write-Host ">> Get-ExOPermissions -recipientIdentity `$mailbox.Identity -includeFolderLevelPermissions"
        
        Write-Host ">> Get-SpOPermissions -siteUrl `"https://tenant.sharepoint.com/sites/site`" -ExpandGroups"
        
        Write-Host ">> Get-SpOPermissions -teamName `"INT-Finance Department`""
        
        Write-Host ">> get-AllSPOPermissions -ExpandGroups -IncludeOneDriveSites -ExcludeOtherSites"
        
        Write-Host ">> get-AllEntraPermissions -excludeGroupsAndUsers"    

        Write-Host ">> get-AllPBIPermissions" 
        
        Write-Host ">> Get-ChangedPermissions"   

        Write-Host ""
    }  
}