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

    $spoBaseAdmUrl = "https://$($global:octo.tenantName)-admin.sharepoint.com"
    Write-LogMessage -level 5 -message "Using Sharepoint base URL: $spoBaseAdmUrl"

    $ignoredSiteTypes = @("REDIRECTSITE#0","SRCHCEN#0", "SPSMSITEHOST#0", "APPCATALOG#0", "POINTPUBLISHINGHUB#0", "EDISC#0", "STS#-1","EHS#1","POINTPUBLISHINGTOPIC#0")
    if($siteUrl){
        $sites = @(New-RetryCommand -Command 'Get-PnPTenantSite' -Arguments @{Connection= (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl); Identity =$siteUrl})
    }
    if(!$sites){
        $sites = @(New-RetryCommand -Command 'Get-PnPTenantSite' -Arguments @{IncludeOneDriveSites = $True; Connection = (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl)} | Where-Object {`
            $_.Template -NotIn $ignoredSiteTypes -and
            ($Null -ne $teamName -and $_.Title -eq $teamName -and $_.Template -notlike "*CHANNEL*") -or ($Null -ne $siteUrl -and $_.Url -eq $siteUrl)
        })
    }

    if($sites.Count -gt 1){
        Throw "Failed to find a single Team using $teamName. Found: $($sites.Url -join ","). Please use the Url to specify the correct Team"
    }elseif($sites.Count -eq 0 -or $Null -eq $sites){
        Throw "Failed to find a Team using $teamName $siteUrl. Please check the name and try again"
    }

    if($sites[0].IsTeamsConnected){
        try{
            Write-LogMessage -message "Retrieving channels for this site/team..." -level 4
            $channels = New-GraphQuery -Uri "https://graph.microsoft.com/beta/teams/$($sites[0].GroupId.Guid)/channels" -Method GET -NoRetry
            Write-LogMessage -message "Found $($channels.Count) channels" -level 4
        }catch{
            Write-LogMessage -level 4 -message "Failed to retrieve channels for $($sites[0].Url), the connected group was probably deleted. No additional sub sites to scan"
            $channels = @()
        }
        foreach($channel in $channels){
            if($channel.filesFolderWebUrl){
                $targetUrl = $Null; $targetUrl ="https://$($global:octo.tenantName).sharepoint.com/$($channel.filesFolderWebUrl.Split("/")[3])/$($channel.filesFolderWebUrl.Split("/")[4])"
            }
            if($targetUrl -and $sites.Url -notcontains $targetUrl){
                try{
                    Write-LogMessage -message "Adding Channel $($channel.displayName) with URL $targetUrl to scan list as it has its own site" -level 4
                    $extraSite = $Null; $extraSite = New-RetryCommand -Command 'Get-PnPTenantSite' -Arguments @{Connection = (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl); Identity = $targetUrl} -ignoreableErrors @("Cannot get site")
                    if($extraSite -and $extraSite.Template -NotIn $ignoredSiteTypes){
                        $sites += $extraSite
                    }
                }catch{
                    Write-Error "Failed to add Channel $($channel.displayName) with URL $targetUrl to scan list. It may have been deleted, because Get-PnPTenantSite failed with $_" -ErrorAction Continue
                }
            }          
        }
    }

    foreach($site in $sites){
        $global:SPOPermissions = @{}
        $siteCategory = "SharePoint"
        if($site.GroupId.Guid -and $site.GroupId.Guid -ne "00000000-0000-0000-0000-000000000000"){
            $siteCategory = "O365Group"
        }
        if($site.IsTeamsConnected -or $site.IsTeamsChannelConnected){
            $siteCategory = "Teams"
            Write-LogMessage -message "Site is connected to a Team will be categorized as Teams site" -level 4
        }
        if($site.Url -like "*-my.sharepoint.com*"){
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

            try{       
                $spoWeb = (New-RetryCommand -Command 'Get-PnPWeb' -Arguments @{Connection = (Get-SpOConnection -Type User -Url $site.Url); ErrorAction = "Stop"})
            }catch{
                if($sites.Count -le 1){
                    Throw $_
                }else{
                    Write-Error "Failed to parse site $($site.Url) because $_" -ErrorAction Continue
                }
                continue
            }
            
            Write-LogMessage -message "Scanning root $($spoWeb.Url)..." -level 4
            $spoSiteAdmins = (New-RetryCommand -Command 'Get-PnPSiteCollectionAdmin' -Arguments @{Connection = (Get-SpOConnection -Type User -Url $site.Url)})
            $global:SPOPermissions.$($spoWeb.Url) = @()

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
                        New-SpOPermissionEntry -targetPath $spoWeb.Url -Permission (get-spopermissionEntry -entity $member -object $spoWeb -permission "Full Control" -through "EntraSecurityGroupOwners" -parentId $aadId)
                    }
                }elseif($spoSiteAdmin.PrincipalType -eq "SharepointGroup"){ #always enumerate sharepoint groups
                    $members = $Null; $members = Get-PnPGroupMembers -group $spoSiteAdmin -parentId $spoSiteAdmin.Id -siteConn (Get-SpOConnection -Type User -Url $site.Url) | Where-Object {$_}
                    foreach($member in $members){
                        New-SpOPermissionEntry -targetPath $spoWeb.Url -Permission (get-spopermissionEntry -entity $member -object $spoWeb -permission "Full Control" -through "SharePointGroup" -parentId $spoSiteAdmin.Id)
                    }
                }else{ #never enumerate entra groups since we have a mapping for current users
                    New-SpOPermissionEntry -targetPath $spoWeb.Url -Permission (get-spopermissionEntry -entity $spoSiteAdmin -object $spoWeb -permission "Full Control" -through "Direct")                 
                }
            }        

            get-PnPObjectPermissions -Object $spoWeb -Category $siteCategory #$Object= $spoWeb;$Category= $siteCategory

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
}