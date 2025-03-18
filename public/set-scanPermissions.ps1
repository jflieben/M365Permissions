Function set-scanPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -appId: the appId of the application (SPN or managed identity) you want to assign permissions to
        -appName: the name of the application (SPN or managed identity) you want to assign permissions to. If it doesn't exist, it will be created as application + SPN
        -switchToSPNAuth: use this if you intend to immediate use the newly created SPN on this machine to run a scan, this will force re-auth and will configure the relevant settings with set-M365PermissionConfig
    #>        
    Param(
        [string]$appId,
        [string]$appName,
        [Switch]$switchToSPNAuth
    )

    $global:octo.userConfig.LCClientId = "2886cc8e-5190-4fb4-9525-61c9b83aa70e" #use onboarding appId

    if(!$appId -and !$appName){
        Throw "You need to provide either an appId or an appName"
    }    

    #ensure we have an onboarding token, which can in turn provision a new or configure an existing SPN to run scans
    try{
        $global:octo.LCRefreshToken = get-AuthorizationCode -clientId $global:octo.userConfig.LCClientId -skipVersionCheck
        $global:octo.userConfig.authMode = "Delegated"
        $global:octo.connection = "Connected"
    }catch{
        Write-Error $_ -ErrorAction Continue
        Throw "Failed to authorize for onboarding, cannot continue"
    }

    if(!$appId){
        $spn = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$Filter=displayName eq '$appName'" -Method GET -ComplexFilter
    }else{
        $spn = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$appId'" -Method GET -ComplexFilter
    }

    if(!$spn -and $appName){
        Write-LogMessage -message "$appName not detected, creating..."
        $desiredState = @{
            "displayName" = $appName
        }
        try {
            $app = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/applications" -Body ($desiredState | ConvertTo-Json) -Method POST
            Write-LogMessage -message "$appName created, waiting 10 seconds..."
            Start-Sleep -s 10
            $spn = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$Filter=appId eq '$($app.appId)'" -Method GET
            if(!$spn){
                $desiredState = @{
                    "appId" = $app.appId
                }
                try {
                    $spn = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Body ($desiredState | ConvertTo-Json) -Method POST
                    Write-LogMessage -message "SPN added to $($app.displayName), waiting 10 seconds..."
                    Start-Sleep -s 10
                } catch {
                    Throw $_
                } 
            }            
        } catch {
            Throw $_
        }       
    }

    Write-LogMessage -message "SPN $($spn.displayName) detected, checking permissions..."
    $appRoles = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($spn.id)/appRoleAssignments" -Method GET

    $requiredRoles = @(
        @{
            "resource" = "00000003-0000-0ff1-ce00-000000000000" #Sharepoint Online
            "id" = "678536fe-1083-478a-9c59-b99265e6b0d3" #Sites.FullControl.All
        }
        @{
            "resource" = "00000002-0000-0ff1-ce00-000000000000" #Exchange Online
            "id" = "dc50a0fb-09a3-484d-be87-e023b12c6440" #Exchange.ManageAsApp
        }
        @{
            "resource" = "00000002-0000-0ff1-ce00-000000000000" #Exchange Online
            "id" = "dc890d15-9560-4a4c-9b7f-a736ec74ec40" #full_access_as_app
        }        
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "7ab1d382-f21e-4acd-a863-ba3e13f7da61" #Directory.Read.All
        }   
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "c74fd47d-ed3c-45c3-9a9e-b8676de685d2" #EntitlementManagement.Read.All
        }   
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "fee28b28-e1f3-4841-818e-2704dc62245f" #RoleEligibilitySchedule.ReadWrite.Directory
        }   
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8" #RoleManagement.ReadWrite.Directory
        }      
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "a82116e5-55eb-4c41-a434-62fe8a61c773" #Sites.FullControl.All
        }                                       
    )

    foreach ($role in $requiredRoles) {
        $existingPermission = $null; $existingPermission = $appRoles | Where-Object { $_.appRoleId -eq $role.id}
        if (!$existingPermission) {
            try {
                $targetSpn = $null; $targetSpn = (New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$($role.resource)')" -Method GET -NoRetry)
            }catch { $targetSpn = $null }

            if (!$targetSpn) {
                Write-LogMessage -message "Required SPN $($role.resource) not detected, creating..."
                $desiredState = @{
                    "appId" = $role.resource
                }
                try {
                    $targetSpn = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Body ($desiredState | ConvertTo-Json) -Method POST
                    Write-LogMessage -message "SPN registered, waiting 10 seconds..."
                    Start-Sleep -s 10
                } catch {
                    Write-Error $_ -ErrorAction Continue
                    $targetSpn = $null
                }
            }else {
                Write-LogMessage -message "Detected required SPN $($role.resource)"
            }  

            $body = @{
                principalId = $spn.Id
                resourceId  = $targetSpn.id
                appRoleId   = $role.id
            }
            try {
                Write-LogMessage -message "Adding approle $($role.id)..."
                New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($targetSpn.id)/appRoleAssignments" -Body ($body | ConvertTo-Json -Depth 15) -Method POST
                Write-LogMessage -message "Added approle $($role.id) :)"
            }catch {
                Write-Error $_ -ErrorAction Continue
            }
        }
    }

    $gaRole = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=DisplayName eq 'Global Administrator'&`$select=rolePermissions" -Method GET
    if (!$gaRole) { Throw "Global admin role not found!" }

    $userRoles = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($spn.Id)/transitiveMemberOf" -Method GET | Where-Object { $_.'@odata.type' -eq "#microsoft.graph.directoryRole" }
    if (!$userRoles -or $userRoles.roleTemplateId -notcontains $gaRole.id) {
        Write-LogMessage -message "assigning GA role..."
        $desiredState = @{
            '@odata.type'    = "#microsoft.graph.unifiedRoleAssignment"
            roleDefinitionId = $gaRole.id
            principalId      = $spn.Id
            directoryScopeId = "/"
        }
        $null = New-GraphQuery -Uri "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments" -Body ($desiredState | ConvertTo-Json) -Method POST

        Write-LogMessage -message "GA role assigned"
    }else {
        Write-LogMessage -message "SPN role is already configured correctly"
    }

    try{
        new-SpnAuthCert -tenantId $spn.appOwnerOrganizationId -importToEntraAppId $app.Id
    }catch{
        Write-Error $_ -ErrorAction Continue
        Throw "Cannot continue, exiting..."
    }

    #"logout" so we can re-authenticate with the new SPN
    $global:octo.connection = "Pending"

    if($switchToSPNAuth){
        set-M365PermissionsConfig -authMode ServicePrincipal -LCTenantId $spn.appOwnerOrganizationId -LCClientId $spn.appId
        connect-M365 -ServicePrincipal
    }
}