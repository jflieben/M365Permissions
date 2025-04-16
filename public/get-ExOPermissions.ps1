Function get-ExOPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -includeFolderLevelPermissions: if set, folder level permissions for each mailbox will be retrieved. This can be (very) slow
    #>        
    Param(
        [Switch]$includeFolderLevelPermissions,
        [parameter(Mandatory=$true)][String]$recipientIdentity,
        [Boolean]$isParallel=$False
    )

    $global:ExOPermissions = @{}

    if(!$global:octo.recipients){
        Write-Progress -Id 2 -PercentComplete 1 -Activity "Scanning Recipient" -Status "Retrieving recipients for cache..."
        $global:octo.recipients = (New-ExOQuery -cmdlet "Get-Recipient" -cmdParams @{"ResultSize" = "Unlimited"}) | Where-Object{$_ -and !$_.Identity.StartsWith("DiscoverySearchMailbox")}
    }

    $recipient = $global:octo.recipients | Where-Object {$_.Identity -eq $recipientIdentity}

    if(!$recipient){
        Write-Error "Recipient $recipientIdentity not found, skipping..." -ErrorAction Continue
        return $Null
    }
    
    New-StatisticsObject -category "ExoRecipients" -subject $recipient.displayName

    Update-StatisticsObject -category "ExoRecipients" -subject $recipient.displayName
    if(!$recipient.PrimarySmtpAddress){
        Write-LogMessage -level 2 -message "skipping $($recipient.identity) as it has no primary smtp address"
        return $Null
    }
    
    #mailboxes have mailbox permissions
    if($recipient.RecipientTypeDetails -like "*Mailbox*" -and $recipient.RecipientTypeDetails -ne "GroupMailbox"){
        Write-Progress -Id 2 -PercentComplete 5 -Activity "Scanning $($recipient.Identity)" -Status "Checking SendOnBehalf permissions..."
        #get mailbox meta for SOB permissions
        $identifierEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($recipient.Guid))   
        $mailbox = $Null; $mailbox = New-GraphQuery -resource "https://outlook.office365.com" -Method GET -Uri "https://outlook.office365.com/adminapi/beta/$($global:octo.OnMicrosoft)/Mailbox('$($identifierEncoded)')?isEncoded=true" -MaxAttempts 3
        #add root level permission
        if($mailbox.ExternalDirectoryObjectId){
            $splat = @{
                targetPath = "/$($recipient.PrimarySmtpAddress)"
                targetType = $recipient.RecipientTypeDetails
                targetId = $mailbox.Guid
                principalEntraId = $mailbox.ExternalDirectoryObjectId
                principalEntraUpn = if($mailbox.PrimarySmtpAddress){$mailbox.PrimarySmtpAddress}else{$mailbox.windowsLiveId}
                principalSysId = $mailbox.Guid
                principalSysName = $mailbox.DisplayName
                principalType = "Internal User"
                principalRole = "Owner"
                through = "Direct"
                accessType = "Allow"
                tenure = "Permanent"
            }
            New-ExOPermissionEntry @splat
        }        
        if($mailbox.GrantSendOnBehalfTo){
            foreach($sendOnBehalf in $mailbox.GrantSendOnBehalfTo){
                $identifierEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($sendOnBehalf))
                $extraHeaders = @(
                    @{"Name" = "XParameter-Identity"; "Value" = "$($identifierEncoded)"}
                )
                $entity = $Null; $entity= New-GraphQuery -extraHeaders $extraHeaders -resource "https://outlook.office365.com" -Method GET -Uri "https://outlook.office365.com/adminapi/beta/$($global:octo.OnMicrosoft)/Recipient?`$select=displayName,Identity,PrimarySmtpAddress,RecipientTypeDetails,Guid,ExternalDirectoryObjectId&ReadIdsAndParamsFromHeaders=True" -MaxAttempts 2 | select -First 1            
                $splat = @{
                    targetPath = "/$($recipient.PrimarySmtpAddress)"
                    targetType = $recipient.RecipientTypeDetails
                    targetId = $mailbox.Guid
                    principalEntraId = $entity.ExternalDirectoryObjectId
                    principalEntraUpn = if($entity.PrimarySmtpAddress){$entity.PrimarySmtpAddress}else{$entity.windowsLiveId}
                    principalSysId = $entity.Guid
                    principalSysName = $entity.DisplayName
                    principalType = $entity.RecipientTypeDetails
                    principalRole = "SendOnBehalf"
                    through = "Direct"
                    accessType = "Allow"
                    tenure = "Permanent"
                }
                New-ExOPermissionEntry @splat
            }
        }           
        
        if($mailbox){
            Write-LogMessage -level 5 -message "Got mailbox $($mailbox.Guid) for $($recipient.Identity)"
            Write-Progress -Id 2 -PercentComplete 15 -Activity "Scanning $($recipient.Identity)" -Status "Checking Mailbox permissions..."
            $identifierEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($mailbox.Guid))
            $mailboxPermissions = $Null; $mailboxPermissions= New-GraphQuery -resource "https://outlook.office365.com" -Method GET -Uri "https://outlook.office365.com/adminapi/beta/$($global:octo.OnMicrosoft)/Mailbox('$($identifierEncoded)')/MailboxPermission?isEncoded=true" | Where-Object {$_.User -like "*@*"}
            foreach($mailboxPermission in $mailboxPermissions){
                foreach($permission in $mailboxPermission.PermissionList){
                    $identifierEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($mailboxPermission.User))
                    $extraHeaders = @(
                        @{"Name" = "XParameter-Identity"; "Value" = "$($identifierEncoded)"}
                    )
                    $entity = $Null; $entity= New-GraphQuery -extraHeaders $extraHeaders -resource "https://outlook.office365.com" -Method GET -Uri "https://outlook.office365.com/adminapi/beta/$($global:octo.OnMicrosoft)/Recipient?`$select=displayName,Identity,PrimarySmtpAddress,RecipientTypeDetails,Guid,ExternalDirectoryObjectId&ReadIdsAndParamsFromHeaders=True" -MaxAttempts 2 | select -First 1            
                    $splat = @{
                        targetPath = "/$($recipient.PrimarySmtpAddress)"
                        targetType = $recipient.RecipientTypeDetails
                        targetId = $mailbox.Guid
                        principalEntraId = $entity.ExternalDirectoryObjectId
                        principalEntraUpn = if($entity.PrimarySmtpAddress){$entity.PrimarySmtpAddress}else{$entity.windowsLiveId}
                        principalSysId = $entity.Guid
                        principalSysName = $entity.DisplayName
                        principalType = $entity.RecipientTypeDetails
                        principalRole = $permission.AccessRights -Join ","
                        through = $(if($permission.IsInherited){ "Inherited" }else{ "Direct" })
                        accessType = $(if($permission.Deny -eq "False"){ "Allow" }else{ "Deny" })
                        tenure = "Permanent"
                    }
                    New-ExOPermissionEntry @splat
                }
            }
        }
        
        #retrieve individual folder permissions if -includeFolderLevelPermissions is set
        if($mailbox.Guid -and $includeFolderLevelPermissions){
            Write-Progress -Id 2 -PercentComplete 25 -Activity "Scanning $($recipient.Identity)" -Status "Checking folder permissions..."

            Write-Progress -Id 3 -PercentComplete 1 -Activity "Scanning folders $($recipient.Identity)" -Status "Retrieving folder list for $($mailbox.UserPrincipalName)"
            $guidEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($mailbox.Guid.ToString()))
            try{
                $folders = $Null; $folders = New-GraphQuery -resource "https://outlook.office365.com" -Method GET -Uri "https://outlook.office365.com/adminapi/beta/$($global:octo.OnMicrosoft)/Mailbox('$guidEncoded')/MailboxFolder/Exchange.GetMailboxFolderStatistics(folderscope=Exchange.ElcFolderType'All')?isEncoded=true"
                Write-LogMessage -level 5 -message "Got $($folders.count) folders for for $($recipient.Identity)"
            }catch{
                Write-LogMessage -level 2 -message "Failed to retrieve folder list for $($mailbox.UserPrincipalName)"
            }      

            $ignoredFolderTypes = @("PersonMetadata","ConversationActions","RecipientCache","RecoverableItemsSubstrateHolds","RecoverableItemsPurges","RecoverableItemsVersions","RecoverableItemsDeletions","RecoverableItemsDiscoveryHolds","Audits","CalendarLogging","RecoverableItemsRoot","SyncIssues","Conflicts","LocalFailures","ServerFailures")
            $ignoredFolderNames = @("SearchDiscoveryHoldsFolder")
            $folderCounter = 0
            foreach($folder in $folders){
                Update-StatisticsObject -category "ExoRecipients" -subject $recipient.displayName
                $folderCounter++
                Write-Progress -Id 3 -PercentComplete (($folderCounter/$folders.Count)*100) -Activity "Scanning folders $($recipient.Identity)" -Status "Examining $($folder.Name) ($($folderCounter) of $($folders.Count))"
                if($ignoredFolderTypes -contains $folder.FolderType -or $ignoredFolderNames -contains $folder.Name){
                    Write-LogMessage -level 5 -message "Ignoring folder $($folder.Name) as it is in the ignored list"
                    continue
                }
                if($folder.ItemsInFolder -lt 1){
                    Write-LogMessage -level 5 -message "Ignoring folder $($folder.Name) as it is empty"
                    continue
                }           
                
                try{
                    $folderIdEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($folder.FolderId))
                    $folderPermissions = $Null; $folderPermissions = New-GraphQuery -resource "https://outlook.office365.com" -Method GET -Uri "https://outlook.office365.com/adminapi/beta/$($global:octo.OnMicrosoft)/Mailbox('$guidEncoded')/MailboxFolder('$folderIdEncoded')/MailboxFolderPermission?IsUsingMailboxFolderId=True&isEncoded=true"
                    foreach($folderPermission in $folderPermissions){
                        if($folderPermission.User.StartsWith("NT:S-1-5-21-")){
                            Write-LogMessage -level 6 -message "Ignoring pre-migration orphaned permissions $($folderPermission.User)"
                            continue
                        }                                 
                        if($folderPermission.User -eq "Default"){
                            $entity = [PSCustomObject]@{
                                ExternalDirectoryObjectId = "AllInternalUsers"
                                PrimarySmtpAddress = "AllInternalUsers"
                                RecipientTypeDetails = "AllInternalUsers"
                                Guid = "AllInternalUsers"
                            }   
                        }elseif($folderPermission.User -eq "Anonymous"){
                            $entity =[PSCustomObject] @{
                                ExternalDirectoryObjectId = "Anonymous"
                                PrimarySmtpAddress = "Anonymous"
                                RecipientTypeDetails = "Anonymous"
                                Guid = "Anonymous"
                            }      
                        }elseif($folderPermission.User.StartsWith("ExchangePublishedUser")){
                            $entity = [PSCustomObject]@{
                                PrimarySmtpAddress = $folderPermission.User.Replace("ExchangePublishedUser.","")
                                ExternalDirectoryObjectId = ""
                                RecipientTypeDetails = "External User"
                                Guid = $folderPermission.User
                            }
                        }elseif($folderPermission.MailboxFolderUser.UserPrincipalName){
                            if($folderPermission.MailboxFolderUser.UserPrincipalName -like "*#EXT#@*"){
                                $userType = "External User"
                            }else{
                                $userType = "Internal User"
                            }
                            $entity = $Null; $entity= @{
                                UserPrincipalName = $folderPermission.MailboxFolderUser.UserPrincipalName
                                ExternalDirectoryObjectId = get-aadObjectId -upn $folderPermission.MailboxFolderUser.UserPrincipalName
                                RecipientTypeDetails = $userType
                                Guid = $folderPermission.MailboxFolderUser.UserPrincipalName
                            }
                        }else{
                            try{
                                $identifierEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($folderPermission.User))
                                $extraHeaders = @(
                                    @{"Name" = "XParameter-Identity"; "Value" = "$($identifierEncoded)"}
                                )
                                $entity = $Null; $entity= New-GraphQuery -extraHeaders $extraHeaders -resource "https://outlook.office365.com" -Method GET -Uri "https://outlook.office365.com/adminapi/beta/$($global:octo.OnMicrosoft)/Recipient?`$select=displayName,Identity,PrimarySmtpAddress,RecipientTypeDetails,Guid,ExternalDirectoryObjectId&ReadIdsAndParamsFromHeaders=True" -MaxAttempts 2 | select -First 1            
                            }catch{
                                Write-LogMessage -level 5 -message "Failed to get entity for $($folderPermission.User) with error $($_.Exception.Message), skipping..."
                                continue
                            }
                        }

                        if($entity -and ($entity.Identity -eq $recipient.Identity -or $entity.UserPrincipalName -eq $mailbox.UserPrincipalName)){
                            Write-LogMessage -level 5 -message "Skipping permission $($folderPermission.AccessRights) scoped at $($mailbox.UserPrincipalName)$($folder.FolderPath) for $($recipient.Identity) as it is the owner"
                            continue
                        }
                        if($folderPermission.AccessRights -notcontains "None"){
                            foreach($AccessRight in $folderPermission.AccessRights.Split(",").Trim()){
                                $splat = @{
                                    targetPath = "/$($recipient.PrimarySmtpAddress)$($folder.FolderPath)"
                                    targetType = "MailboxFolder"
                                    targetId = $folder.FolderId
                                    principalEntraId = $entity.ExternalDirectoryObjectId
                                    principalEntraUpn = if($entity.PrimarySmtpAddress){$entity.PrimarySmtpAddress}else{$entity.windowsLiveId}
                                    principalSysId = $entity.Guid
                                    principalSysName = $folderPermission.User
                                    principalType = $entity.RecipientTypeDetails
                                    principalRole = $AccessRight
                                    through = "Direct"
                                    accessType = "Allow"
                                    tenure = "Permanent"
                                }
                                New-ExOPermissionEntry @splat
                            }
                        }
                    }
                }catch{
                    Write-LogMessage -level 2 -message "Failed to retrieve folder permissions for $($mailbox.UserPrincipalName)$($folder.FolderPath)"
                }
            }
            Write-Progress -Id 3 -Completed -Activity "Scanning folders $($recipient.Identity)"
        }
    }
    
    #all recipients can have recipient permissions
    Write-Progress -Id 2 -PercentComplete 85 -Activity "Scanning $($recipient.Identity)" -Status "Checking SendAs permissions..."
    $identifierEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($recipient.Guid))   
    $recipientPermissions = $Null; $recipientPermissions = New-GraphQuery -resource "https://outlook.office365.com" -Method GET -Uri "https://outlook.office365.com/adminapi/beta/$($global:octo.OnMicrosoft)/Recipient('$($identifierEncoded)')?`$expand=RecipientPermission&isEncoded=true&`$select=RecipientPermission,%20ExternalDirectoryObjectId" -MaxAttempts 3
    foreach($recipientPermission in $recipientPermissions.RecipientPermission){
        if($recipientPermission.Trustee -eq "NT AUTHORITY\SELF"){
            continue
        }
        $identifierEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($recipientPermission.Trustee))
        $extraHeaders = @(
            @{"Name" = "XParameter-Identity"; "Value" = "$($identifierEncoded)"}
        )
        try{
            $entity = $Null; $entity= New-GraphQuery -extraHeaders $extraHeaders -resource "https://outlook.office365.com" -Method GET -Uri "https://outlook.office365.com/adminapi/beta/$($global:octo.OnMicrosoft)/Recipient?`$select=displayName,Identity,PrimarySmtpAddress,RecipientTypeDetails,Guid,ExternalDirectoryObjectId&ReadIdsAndParamsFromHeaders=True" -MaxAttempts 2 | select -First 1            
        }catch{
            $entity = $Null
        }
        foreach($AccessRight in $recipientPermission.AccessRights.Split(",").Trim()){
            $splat = @{
                targetPath = "/$($recipient.PrimarySmtpAddress)"
                targetType = $recipient.RecipientTypeDetails
                targetId = $recipient.Guid
                principalEntraId = $entity.ExternalDirectoryObjectId
                principalEntraUpn = $recipientPermission.Trustee
                principalSysId = $entity.Guid
                principalSysName = $entity.displayName
                principalType = $entity.RecipientTypeDetails
                principalRole = $AccessRight
                through = $(if($recipientPermission.IsInherited){ "Inherited" }else{ "Direct" })
                accessType = $recipientPermission.AccessControlType
                tenure = "Permanent"
            }
            New-ExOPermissionEntry @splat
        }
    } 

    Write-Progress -Id 2 -PercentComplete 95 -Activity "Scanning $($recipient.Identity)" -Status "Writing report..."
    Stop-StatisticsObject -category "ExoRecipients" -subject $recipient.displayName

    $permissionRows = foreach($row in $global:ExOPermissions.Keys){
        foreach($permission in $global:ExOPermissions.$row){
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
                "accessType" = $permission.accessType
                "tenure" = $permission.tenure
                "startDateTime" = $permission.startDateTime
                "endDateTime" = $permission.endDateTime
                "createdDateTime" = $permission.createdDateTime
                "modifiedDateTime" = $permission.modifiedDateTime
            }
        }
    }
    
    Add-ToReportQueue -permissions $permissionRows -category "ExoRecipients"
    Remove-Variable -Name permissionRows -Force -Confirm:$False
    Remove-Variable -Name ExOPermissions -Scope Global -Force -Confirm:$False
    Write-Progress -Id 2 -Completed -Activity "Scanning $($recipient.Identity)"
    if(!$isParallel){
        Write-Report         
    }else{
        [System.GC]::GetTotalMemory($true) | out-null         
    }     
}