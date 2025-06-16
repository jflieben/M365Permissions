Function get-SpOPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -teamName: the name of the Team to scan
        -siteUrl: the URL of the Team (or any sharepoint location) to scan (e.g. if name is not unique)
    #>        
    Param(
        [parameter(Mandatory=$true,
        ParameterSetName="ByName")]
        [String]
        $teamName,
    
        [parameter(Mandatory=$true,
        ParameterSetName="BySite")]
        [String]
        $siteUrl, 
        
        [Boolean]$isParallel=$False
    )

    $env:PNPPOWERSHELL_UPDATECHECK="off"

    Write-LogMessage -message "Starting SpO Scan of $($teamName)$($siteUrl)" -level 4

    $spoBaseAdmUrl = "https://$($global:octo.tenantName)-admin.$($global:octo.sharepointUrl)"
    Write-LogMessage -level 5 -message "Using Sharepoint base URL: $spoBaseAdmUrl"

    $ignoredSiteTypes = @("REDIRECTSITE#0","SRCHCEN#0", "SPSMSITEHOST#0", "APPCATALOG#0", "POINTPUBLISHINGHUB#0", "EDISC#0", "STS#-1","EHS#1","POINTPUBLISHINGTOPIC#0")
    if($siteUrl){
        $site = @(New-RetryCommand -Command 'Get-PnPTenantSite' -Arguments @{Connection= (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl); Identity =$siteUrl})
    }
    if(!$site){
        $site = @(New-RetryCommand -Command 'Get-PnPTenantSite' -Arguments @{IncludeOneDriveSites = $True; Connection = (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl)} | Where-Object {`
            $_.Template -NotIn $ignoredSiteTypes -and
            ($Null -ne $teamName -and $_.Title -eq $teamName) -or ($Null -ne $siteUrl -and $_.Url -eq $siteUrl)
        })
    }

    if($site.Count -gt 1){
        Throw "Failed to find a single Team using $teamName. Found: $($site.Url -join ","). Please use the Url to specify the correct Team"
    }elseif($site.Count -eq 0 -or $Null -eq $site){
        Throw "Failed to find a Team using $teamName $siteUrl. Please check the name and try again"
    }

    $site = $site | Select-Object -First 1

    Write-LogMessage -message "Site sharing mode: $($site.SharingCapability)" -level 4
    $global:siteSharingMode = @{
        "Anonymous" = $false
        "External" = $false
    }

    switch($site.SharingCapability){
        "ExternalUserAndGuestSharing" {
                $global:siteSharingMode["External"] = $true
                $global:siteSharingMode["Anonymous"] = $true
        }
        "ExternalUserSharingOnly" {
                $global:siteSharingMode["External"] = $true
                $global:siteSharingMode["Anonymous"] = $false
        }
        "ExistingExternalUserSharingOnly" {
                $global:siteSharingMode["External"] = $true
                $global:siteSharingMode["Anonymous"] = $false
        }
        "Disabled" {
                $global:siteSharingMode["External"] = $false
                $global:siteSharingMode["Anonymous"] = $false
        }
    }

    if($site.IsTeamsConnected -and !$isParallel){
        try{
            Write-LogMessage -message "Retrieving channels for this site/team..." -level 4
            $channels = New-GraphQuery -Uri "$($global:octo.graphUrl)/beta/teams/$($site[0].GroupId.Guid)/channels" -Method GET -NoRetry
            Write-LogMessage -message "Found $($channels.Count) channels" -level 4
        }catch{
            Write-LogMessage -level 4 -message "Failed to retrieve channels for $($site[0].Url), the connected group was probably deleted. No additional sub sites to scan"
            $channels = @()
        }
        foreach($channel in $channels){
            if($channel.filesFolderWebUrl){
                $targetUrl = $Null; $targetUrl ="https://$($global:octo.tenantName).$($global:octo.sharepointUrl)/$($channel.filesFolderWebUrl.Split("/")[3])/$($channel.filesFolderWebUrl.Split("/")[4])"
            }
            if($targetUrl -and $site.Url -ne $targetUrl){
                try{
                    Write-LogMessage -message "This team has sub channels, we recommend also scanning: $targetUrl" -level 4
                }catch{
                    Write-Error "Failed to add Channel $($channel.displayName) with URL $targetUrl to scan list. It may have been deleted, because Get-PnPTenantSite failed with $_" -ErrorAction Continue
                }
            }          
        }
    }

    $global:SPOPermissions = @{}
    $siteCategory = "SharePoint"
    if($site.GroupId.Guid -and $site.GroupId.Guid -ne "00000000-0000-0000-0000-000000000000"){
        $siteCategory = "O365Group"
    }
    if($site.IsTeamsConnected -or $site.IsTeamsChannelConnected){
        $siteCategory = "Teams"
        Write-LogMessage -message "Site is connected to a Team will be categorized as Teams site" -level 4
    }
    if($site.Url -like "*-my.$($global:octo.sharepointUrl)*"){
        $siteCategory = "OneDrive"
        Write-LogMessage -message "Site is a OneDrive site" -level 4
    }

    New-StatisticsObject -Category $siteCategory -Subject $site.Url
       
    try{
        $oldLockState = $False
        $wasOwner = $True
        if($site.LockState -in @("NoAccess","ReadOnly")){
            if($global:octo.userConfig.respectSiteLocks){
                Throw "Site is locked and you've configured respectSiteLocks to `$True, skipping this site."
            }
            if($site.LockState -eq "ReadOnly"){
                Write-LogMessage -message "Site is locked in read-only mode, unlocking..." -level 4
                New-RetryCommand -Command 'Set-PnPTenantSite' -Arguments @{Identity = $site.Url; LockState = "Unlock"; Connection = (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl); WarningAction = "SilentlyContinue"; ErrorAction ="Stop"}
                $oldLockState = $site.LockState
                Write-LogMessage -message "Site unlocked, waiting 5 minutes..." -level 4
                Start-Sleep -Seconds 300
            }else{
                Write-LogMessage -message "Site is locked in no-access mode and will be skipped as no one currently has access to it" -level 3
                continue
            }
        }

        if($site.Owner -ne $global:octo.currentUser.userPrincipalName -and $site.Owners -notcontains $global:octo.currentUser.userPrincipalName -and $global:octo.userConfig.authMode -eq "Delegated"){
            Write-LogMessage -message "Adding you as site collection owner to ensure all permissions can be read from $($site.Url)..." -level 4
            New-RetryCommand -Command 'Set-PnPTenantSite' -Arguments @{Identity = $site.Url; Owners = $global:octo.currentUser.userPrincipalName; Connection = (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl); WarningAction = "SilentlyContinue"; ErrorAction ="Stop"}
            $wasOwner = $False
            Write-LogMessage -message "Owner added and marked for removal upon scan completion" -level 4
        }else{
            Write-LogMessage -message "Site collection ownership verified for $($site.Url) :)" -level 4
        }   
        
        Write-LogMessage -message "Scanning root permissions on $($site.Url)..." -level 4
        $spoSiteAdmins = (New-RetryCommand -Command 'Get-PnPSiteCollectionAdmin' -Arguments @{Connection = (Get-SpOConnection -Type User -Url $site.Url)})
        foreach($spoSiteAdmin in $spoSiteAdmins){
            Update-StatisticsObject -Category $siteCategory -Subject $site.Url
            $aadId = $Null; $aadId = get-SpOAadObjectId -loginName $spoSiteAdmin.LoginName
            if($spoSiteAdmin.PrincipalType -eq "DistributionList"){
                Throw "Unsupported site admin type: distributionList, please log a ticket"
            }
            if($spoSiteAdmin.LoginName -and $spoSiteAdmin.LoginName.EndsWith("_o")){
                #special case where the group is an AAD group but the loginname ends with _o which means the OWNERS of the group are the owners of the site, we should always retrieve those
                $members = $Null; $members = Get-PnPGroupMembers -group $spoSiteAdmin -parentId $spoSiteAdmin.Id -siteConn (Get-SpOConnection -Type User -Url $site.Url) | Where-Object {$_}
                foreach($member in $members){
                    New-SpOPermissionEntry -targetPath $site.Url -Permission (get-spopermissionEntry -entity $member -object $site -permission "Full Control" -through "EntraSecurityGroupOwners" -parentId $aadId)
                }
            }elseif($spoSiteAdmin.PrincipalType -eq "SharepointGroup"){ #always enumerate sharepoint groups
                $members = $Null; $members = Get-PnPGroupMembers -group $spoSiteAdmin -parentId $spoSiteAdmin.Id -siteConn (Get-SpOConnection -Type User -Url $site.Url) | Where-Object {$_}
                foreach($member in $members){
                    New-SpOPermissionEntry -targetPath $site.Url -Permission (get-spopermissionEntry -entity $member -object $site -permission "Full Control" -through "SharePointGroup" -parentId $spoSiteAdmin.Id)
                }
            }else{ #never enumerate entra groups since we have a mapping for current users
                if($spoSiteAdmin.PrincipalType -eq "SecurityGroup"){
                    New-SpOPermissionEntry -targetPath $site.Url -Permission (get-spopermissionEntry -entity $spoSiteAdmin -object $site -permission "Full Control" -through "EntraSecurityGroup")                 
                }else{
                    New-SpOPermissionEntry -targetPath $site.Url -Permission (get-spopermissionEntry -entity $spoSiteAdmin -object $site -permission "Full Control" -through "Direct")                 
                }       
            }
        }    
        
        try{       
            $spoWebs = (New-RetryCommand -Command 'Get-PnPSubWeb' -Arguments @{IncludeRoot = $True;Recurse = $True;Connection = (Get-SpOConnection -Type User -Url $site.Url)})
        }catch{
            Throw $_
        }
        
        foreach($spoWeb in $spoWebs){
            Write-LogMessage -message "Scanning permissions inside $($spoWeb.Url)..." -level 4
            $global:SPOPermissions.$($spoWeb.Url) = @()        
            try{
                get-PnPObjectPermissions -Object $spoWeb -Category $siteCategory #$Object= $spoWeb;$Category= $siteCategory
            }catch{
                Write-Error "Failed to retrieve permissions for $($spoWeb.Url) because $_" -ErrorAction Continue
            }
        }

        Stop-StatisticsObject -Category $siteCategory -Subject $site.Url
    }catch{
        Throw $_
    }finally{
        if(!$wasOwner){
            Write-LogMessage -message "Cleanup: Removing you as site collection owner of $($site.Url)..." -level 4
            try{
                (New-RetryCommand -Command 'Remove-PnPSiteCollectionAdmin' -Arguments @{Owners = $global:octo.currentUser.userPrincipalName; Connection = (Get-SpOConnection -Type User -Url $site.Url)})
                Write-LogMessage -message "Cleanup: Owner removed" -level 4
            }catch{
                Write-Error "Cleanup: Failed to remove you as site collection owner of $($site.Url) because $_" -ErrorAction Continue
            }
        }    
        
        if($oldLockState){
            Write-LogMessage -message "Cleanup: Locking site back to $oldLockState..." -level 4
            try{
                (New-RetryCommand -Command 'Set-PnPTenantSite' -Arguments @{Identity = $site.Url; LockState = $oldLockState; Connection = (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl); WarningAction = "SilentlyContinue"; ErrorAction ="Stop"})
                Write-LogMessage -message "Cleanup: Site locked" -level 4
            }catch{
                Write-Error "Cleanup: Failed to lock site back to $oldLockState because $_" -ErrorAction Continue
            }
        }
    }

    Write-LogMessage -message "Finalizing data and adding to report queue..." -level 4
    
    $permissionRows = foreach($row in $global:SPOPermissions.Keys){
        foreach($permission in $global:SPOPermissions.$row){
            [PSCustomObject]@{
                "targetPath" = $row
                "targetType" = $permission.targetType
                "targetId" = $permission.targetId
                "principalEntraId" = $permission.principalEntraId
                "principalSysId" = $permission.principalSysId
                "principalSysName" = $permission.principalSysName
                "principalType" = $permission.principalType
                "principalRole" = $permission.principalRole
                "through" = $permission.through
                "parentId" = $permission.parentId
                "accessType" = "Allow"
                "tenure" = "Permanent"
                "startDateTime" = $permission.startDateTime
                "endDateTime" = $permission.endDateTime
                "createdDateTime" = $permission.createdDateTime
                "modifiedDateTime" = $permission.modifiedDateTime
            }
        }
    }

    Add-ToReportQueue -permissions $permissionRows -category $siteCategory
    Remove-Variable -Name SPOPermissions -Scope Global -Force -Confirm:$False
    Remove-Variable -Name permissionRows -Force -Confirm:$False

    if(!$isParallel){
        Write-Report      
    }else{
        [System.GC]::GetTotalMemory($true) | out-null
    }    
    
    Write-LogMessage -message "Done" -level 4
}