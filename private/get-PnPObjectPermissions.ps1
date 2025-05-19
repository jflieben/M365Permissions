Function get-PnPObjectPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)]$Object,
        $siteUrl,
        $Category
    )

    $ignoreablePermissions = @(0,1,9) #None (0), Limited Access (1), Web-Only Limited Access (9)

    $obj = [PSCustomObject]@{
        "Title" = $null
        "Type" = $null
        "Url" = $Null
        "id" = $Null
    }    

    function aclTypeToString{
        param(
            [Parameter(Mandatory=$true)]$acl
        )
        switch($acl.Id){
            1073741829{"Full Control"}
            1073741828{"Design"}
            1073741830{"Edit"}
            1073741827{"Contribute"}
            1073741826{"Read"}
            1073741825{"Limited"}
            1073741926{"LimitedView"}
            1073741927{"LimitedEdit"}
            1073741924{"Create subsites"}
            1073741925{"View Only"}
            default{$acl.Name}
        }
    }

    if($Object.ListGuid){
        $itemData = New-GraphQuery -resource "https://www.$($global:octo.sharepointUrl)" -Uri "$($siteUrl)/_api/web/lists/getbyid('$($Object.ListGuid)')/items($($Object.ID))?`$expand=File,Folder,RoleAssignments/Member,RoleAssignments/RoleDefinitionBindings&`$select=FileSystemObjectType,Folder,File,Id,Title,RoleAssignments&`$format=json" -Method GET
        If($itemData.FileSystemObjectType -eq 1){
            $obj.Title = $itemData.Folder.Name
            $obj.Url = "$($siteUrl.Split($global:octo.sharepointUrl)[0])$($global:octo.sharepointUrl)$($itemData.Folder.ServerRelativeUrl)"
            $obj.Type = "Folder"
            $obj.id = $Object.ID
        }Else{
            If($Null -ne $itemData.File.Name){
                $obj.Title = $itemData.File.Name
                $obj.Url = "$($siteUrl.Split($global:octo.sharepointUrl)[0])$($global:octo.sharepointUrl)$($itemData.File.ServerRelativeUrl)"
                $obj.Type = "File"
                $obj.id = $Object.ID
            }else{
                $obj.Title = $itemData.Title
                $obj.Url = "$($siteUrl)/$($Object.displayFormUrl)?ID=$($Object.ID)"
                $obj.Type = "List Item" 
                $obj.id = $Object.ID        
            }
        }
        $ACLs = $itemData.RoleAssignments
    }else{
        Switch($Object.TypedObject.ToString()){
            "Microsoft.SharePoint.Client.Web"  { 
                $siteUrl = $Object.Url
                $obj.Title = $Object.Title
                $obj.Url = $Object.Url
                $obj.Type = "Site"
                $obj.id = $Object.Id
                Update-StatisticsObject -Category $Category -Subject $siteUrl
                $graphSite = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/sites/$($Object.Url.Replace("https://",'').Replace($global:octo.sharepointUrl,"$($global:octo.sharepointUrl):"))" -Method GET
                $graphSiteLevelPermissions = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/sites/$($graphSite.id)/permissions" -Method GET
                foreach($graphSiteLevelPermission in $graphSiteLevelPermissions){
                    if($graphSiteLevelPermission.id){
                        #grab the associated role
                        $permissionInfo = $Null; $permissionInfo = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/sites/$($graphSite.id)/permissions/$($graphSiteLevelPermission.id)" -Method GET
                        if($permissionInfo){
                            foreach($identity in $permissionInfo.grantedToIdentitiesV2.application){
                                #we need the actual SPN to determine if it is internal or external and get the objectId, which the spo api does not return
                                $spn = $Null; $spn = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/servicePrincipals(appId='$($identity.id)')" -Method GET
                                if(!$spn){
                                    Write-LogMessage -level 5 -message "Failed to get service principal for $($identity.id) because $_" -ErrorAction Continue
                                    continue
                                }
                                if($spn.appOwnerOrganizationId -ne $global:octo.tenantId){
                                    $principalType = "External Service Principal"
                                }else{
                                    $principalType = "Internal Service Principal"
                                }
                                foreach($role in $permissionInfo.roles){
                                    $splat = @{
                                        targetPath = $obj.Url
                                        Permission = [PSCustomObject]@{
                                            targetType = "Site"
                                            targetId = $obj.id.Guid
                                            principalEntraId = $spn.id
                                            principalSysId = $identity.id
                                            principalSysName = $identity.displayName
                                            principalType = $principalType
                                            principalRole = $role
                                        }
                                    }
                                    New-SpOPermissionEntry @splat
                                }
                            }
                        }
                    }
                }
                $Null = (New-RetryCommand -Command 'Get-PnPProperty' -Arguments @{ClientObject = $Object;Property =@("HasUniqueRoleAssignments", "RoleAssignments");Connection = (Get-SpOConnection -Type User -Url $siteUrl)})
                if($Object.HasUniqueRoleAssignments -eq $False -and $graphSiteLevelPermissions.Count -eq 0){
                    Write-LogMessage -level 5 -message "Skipping $($obj.Title) as it fully inherits permissions from parent"
                    continue
                }else{
                    $ACLs = New-GraphQuery -resource "https://www.$($global:octo.sharepointUrl)" -Uri "$($Object.Url)/_api/web/roleAssignments?`$expand=Member,RoleDefinitionBindings&`$top=5000&`$format=json" -Method GET -expectedTotalResults $Object.RoleAssignments.Count
                }
            }
            Default{ 
                $rootFolder = (New-RetryCommand -Command 'Get-PnPProperty' -Arguments @{ClientObject = $Object;Property ="RootFolder"; Connection =(Get-SpOConnection -Type User -Url $siteUrl)})
                $obj.Title = $Object.Title
                $obj.Url = "$($siteUrl.Split($global:octo.sharepointUrl)[0])$($global:octo.sharepointUrl)$($rootFolder.ServerRelativeUrl)"
                $obj.Type = "List or Library"
                $obj.id = $Object.Id
                Update-StatisticsObject -Category $Category -Subject $siteUrl
                $Null = (New-RetryCommand -Command 'Get-PnPProperty' -Arguments @{ClientObject = $Object;Property = @("HasUniqueRoleAssignments", "RoleAssignments");Connection = (Get-SpOConnection -Type User -Url $siteUrl)})
                if($Object.HasUniqueRoleAssignments -eq $False){
                    Write-LogMessage -level 5 -message "Skipping $($obj.Title) as it fully inherits permissions from parent"
                    continue
                }else{            
                    $ACLs = New-GraphQuery -resource "https://www.$($global:octo.sharepointUrl)" -Uri "$($siteUrl)/_api/web/lists/getbyid('$($Object.Id)')/roleassignments?`$expand=Member,RoleDefinitionBindings&`$top=5000&`$format=json" -Method GET -expectedTotalResults $Object.RoleAssignments.Count
                }
            }
        }   
    } 

    #processes all ACL's on the object
    Foreach($member in $ACLs){
        foreach($permission in $member.RoleDefinitionBindings){
            $permissionName = (aclTypeToString -acl $permission)
            Write-LogMessage -level 5 -message "Detected: $($member.Member.Title) $($permissionName) ($($permission.RoleTypeKind))"
            if($ignoreablePermissions -contains $permission.RoleTypeKind -or $member.Member.IsHiddenInUI){
                Write-LogMessage -level 5 -message "Ignoring $($permissionName) permission type for $($member.Member.Title) because it is only relevant at a deeper level or hidden"
                continue
            }
            $principalType = get-SpOPrincipalType -type $member.Member.PrincipalType
            
            if($member.Member.LoginName -like "SharingLinks*"){
                $sharingLinkInfo = $Null; $sharingLinkInfo = get-SpOSharingLinkInfo -sharingLinkGuid $member.Member.LoginName.Split(".")[3]
                $permissionSplat = @{
                    targetPath = $obj.Url
                }
                if($sharingLinkInfo){
                    switch([Int]$sharingLinkInfo.LinkKind){
                        {$_ -in (2,3)}  { #Org wide
                            $entity = @{LoginName = "AllInternalUsers"; Title = "AllInternalUsers";PrincipalType="SharingLink"}
                            $permissionSplat["Permission"] = get-spopermissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity $entity -object $obj -permission $permissionName -Through "SharingLink" -parentId $sharingLinkInfo.ShareId
                            New-SpOPermissionEntry @permissionSplat
                        }                            
                        {$_ -in (4,5)}  { #Anonymous
                            $entity = @{LoginName = "Anonymous";Title = "Anonymous";PrincipalType="SharingLink"} 
                            $permissionSplat["Permission"] = get-spopermissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity $entity -object $obj -permission $permissionName -Through "SharingLink" -parentId $sharingLinkInfo.ShareId
                            New-SpOPermissionEntry @permissionSplat
                        }                            
                        {$_ -in (1,6)}  { #direct, flexible
                            foreach($invitee in $sharingLinkInfo.invitees){
                                $entity = get-spoInvitee -invitee $invitee -siteUrl $siteUrl
                                $permissionSplat["Permission"] = get-spopermissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity $entity -object $obj -permission $permissionName -Through "SharingLink" -parentId $sharingLinkInfo.ShareId
                                New-SpOPermissionEntry @permissionSplat
                            }
                        }
                    }
                }else{
                    $permissionSplat["Permission"] = (get-spopermissionEntry -entity $member.Member -object $obj -permission $permissionName)
                    New-SpOPermissionEntry @permissionSplat
                }
                continue
            }
            
            if($principalType -like "*Group*"){
                if($principalType -eq "SharePointGroup"){
                    $parentId = $member.Member.Id
                }else{
                    $parentId = get-SpOAadObjectId -loginName $member.Member.LoginName
                }
                Get-PnPGroupMembers -Group $member.Member -parentId $member.Member.Id -siteConn (Get-SpOConnection -Type User -Url $siteUrl) | Where-Object { $_ } | ForEach-Object {
                    #$Group= $member.Member;$parentId= $member.Member.Id;$siteConn= (Get-SpOConnection -Type User -Url $siteUrl)
                    New-SpOPermissionEntry -targetPath $obj.Url -Permission (get-spopermissionEntry -entity $_ -object $obj -permission $permissionName -through $principalType -parentId $parentId)
                }
            }else{
                New-SpOPermissionEntry -targetPath $obj.Url -Permission (get-spopermissionEntry -entity $member.Member -object $obj -permission $permissionName)
            }
        }
    }

    #retrieve permissions for any (if present) child objects and recursively call this function for each
    If(!$Object.ListGuid -and $Object.TypedObject.ToString() -eq "Microsoft.SharePoint.Client.Web"){
        Write-Progress -Id 2 -PercentComplete 0 -Activity $($siteUrl.Split("/")[4]) -Status "Getting child lists..."
        $childObjects = $Null; $childObjects = (New-RetryCommand -Command 'Get-PnPProperty' -Arguments @{ClientObject = $Object; Property = "Lists"; Connection = (Get-SpOConnection -Type User -Url $siteUrl)})
        $ExcludedListTitles = @("Access Requests","App Packages","appdata","appfiles","Apps in Testing","Cache Profiles","Composed Looks","Content and Structure Reports","Content type publishing error log","Converted Forms",
        "Device Channels","Form Templates","fpdatasources","Get started with Apps for Office and SharePoint","List Template Gallery", "Long Running Operation Status","Maintenance Log Library", "Images", "site collection images"
        ,"Master Docs","Master Page Gallery","MicroFeed","NintexFormXml","Quick Deploy Items","Relationships List","Reusable Content","Reporting Metadata", "Reporting Templates", "Search Config List","Site Assets","Preservation Hold Library",
        "Site Pages", "Solution Gallery","Style Library","Suggested Content Browser Locations","Theme Gallery", "TaxonomyHiddenList","User Information List","Web Part Gallery","wfpub","wfsvc","Workflow History","Workflow Tasks", "Pages")
        $ExcludedListFeatureIDs = @("00000000-0000-0000-0000-000000000000","a0e5a010-1329-49d4-9e09-f280cdbed37d","d11bc7d4-96c6-40e3-837d-3eb861805bfa","00bfea71-c796-4402-9f2f-0eb9a6e71b18","de12eebe-9114-4a4a-b7da-7585dc36a907")

        $sharedLinksList = $Null; $sharedLinksList = $childObjects | Where-Object{$_.TemplateFeatureId -eq "d11bc7d4-96c6-40e3-837d-3eb861805bfa" -and $_}
        if($sharedLinksList){
            $global:sharedLinks = @()
            foreach($listId in $sharedLinksList.Id.Guid){ 
                try{
                    $global:sharedLinks += (New-RetryCommand -Command 'Get-PnPListItem' -Arguments @{List = $listId; PageSize = 500;Fields = ("ID","AvailableLinks"); Connection = (Get-SpOConnection -Type User -Url $siteUrl)}) | Where-Object { $_ } | ForEach-Object {
                        $_.FieldValues["AvailableLinks"] | ConvertFrom-Json
                    }
                    Write-LogMessage -message "Cached $($sharedLinks.Count) shared links in $($Object.Title)..." -level 4
                }catch{
                    Write-Error "Failed to retrieve shared links in $($Object.Title) because $_" -ErrorAction Continue
                }
            }
        }else{
            Write-LogMessage -message "No shared links in $($Object.Title) discovered" -level 4
        }

        $counter = 0
        ForEach($List in $childObjects){
            Update-StatisticsObject -Category $Category -Subject $siteUrl -Amount $List.ItemCount
            If($List.Hidden -eq $False -and $ExcludedListTitles -notcontains $List.Title -and $List.ItemCount -gt 0 -and $List.TemplateFeatureId -notin $ExcludedListFeatureIDs){
                if($List.ItemCount -gt 250000){
                    Throw "List $($List.Title) has too many items (250k+). Please use the MSSQL/.NET backed M365Permissions Cloud as it can handle unlimited items."
                }
                $counter++
                Write-Progress -Id 2 -PercentComplete ($Counter / ($childObjects.Count) * 100) -Activity $($siteUrl.Split("/")[4]) -Status "'$($List.Title)': $($List.ItemCount) items (List $counter of $($childObjects.Count))"
                #grab top level info of the list first
                get-PnPObjectPermissions -Object $List -siteUrl $siteUrl -Category $Category

                try{
                    (New-RetryCommand -Command 'Get-PnPProperty' -Arguments @{ClientObject = $List;Property = @("Title", "HasUniqueRoleAssignments", "DefaultDisplayFormUrl"); Connection = (Get-SpOConnection -Type User -Url $siteUrl)})
                }catch{
                    (New-RetryCommand -Command 'Get-PnPProperty' -Arguments @{ClientObject = $List;Property = @("Title", "HasUniqueRoleAssignments", "RootFolder"); Connection = (Get-SpOConnection -Type User -Url $siteUrl)})
                    $List.DefaultDisplayFormUrl = "Lists/$($List.RootFolder.Name)"
                }

                if($List.HasUniqueRoleAssignments -eq $False){
                    Write-LogMessage -level 5 -message "Skipping $($List.Title) List as it fully inherits permissions from parent"
                    continue
                }     

                Write-LogMessage -level 5 -message "List contains $($List.ItemCount) items"
                $allListItems = $Null; $allListItems = New-GraphQuery -resource "https://www.$($global:octo.sharepointUrl)" -Uri "$($Object.Url)/_api/web/lists/getbyid('$($List.Id.Guid)')/items?`$select=ID,HasUniqueRoleAssignments&`$top=5000&`$format=json" -Method GET -expectedTotalResults $List.ItemCount
                $allUniqueListItemIDs = $Null; $allUniqueListItemIDs = @($allListItems | Where-Object { $_.HasUniqueRoleAssignments -eq $True }) | select -ExpandProperty Id
                if($allUniqueListItemIDs.Count -gt 10000){
                    Throw "List $($List.Title) has too many ($($allUniqueListItemIDs.Count)) items with unique permissions. Please use the MSSQL/.NET backed M365Permissions Cloud as it can handle unlimited items."
                }

                for($a=0;$a -lt $allUniqueListItemIDs.Count;$a++){
                    Write-Progress -Id 3 -PercentComplete ((($a+1) / $allUniqueListItemIDs.Count) * 100) -Activity $($siteUrl.Split("/")[4]) -Status "$a / $($allUniqueListItemIDs.Count) processing unique permissions"
                    $uniqueObject = [PSCustomObject]@{
                        "ID" = $allUniqueListItemIDs[$a]
                        "ListGuid" = $List.Id.Guid
                        "displayFormUrl" = $List.DefaultDisplayFormUrl
                    }
                    get-PnPObjectPermissions -Object $uniqueObject -siteUrl $siteUrl -Category $Category
                }
                Write-Progress -Id 3 -Completed -Activity $($siteUrl.Split("/")[4])
            }else{
                Write-LogMessage -level 5 -message "Skipping $($List.Title) as it is hidden, empty or excluded"
            }
        }
        Write-Progress -Id 2 -Completed -Activity $($siteUrl.Split("/")[4])            
    }      
}