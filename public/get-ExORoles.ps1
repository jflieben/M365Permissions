Function get-ExORoles{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -includeFolderLevelPermissions: if set, folder level permissions for each mailbox will be retrieved. This can be (very) slow
    #>        
    Param(
    )

    Write-LogMessage -message "Starting Exo role scan..." -level 4
    
    Write-Progress -Id 2 -PercentComplete 0 -Activity "Scanning Exchange Roles" -Status "Retrieving all role assignments"
    $global:ExOPermissions = @{}
    New-StatisticsObject -category "ExoRoles" -subject "AdminRoles"

    $assignedManagementRoles = $Null;$assignedManagementRoles = (New-ExOQuery -cmdlet "Get-ManagementRoleAssignment" -cmdParams @{GetEffectiveUsers = $True;Enabled = $True})

    Write-Progress -Id 2 -PercentComplete 5 -Activity "Scanning Exchange Roles" -Status "Parsing role assignments"

    $identityCache = @{}
    $count = 0
    foreach($assignedManagementRole in $assignedManagementRoles){
        $count++
        Write-Progress -Id 3 -PercentComplete (($count/$assignedManagementRoles.Count)*100) -Activity "Scanning Roles" -Status "Examining role $($count) of $($assignedManagementRoles.Count)"
        Update-StatisticsObject -category "ExoRoles" -subject "AdminRoles"
        try{
            $mailbox = $Null; $mailbox = $identityCache.$($assignedManagementRole.EffectiveUserName)
            if($Null -eq $mailbox){
                $identifierEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($assignedManagementRole.EffectiveUserName))   
                $mailbox = $Null; $mailbox = New-GraphQuery -resource "https://$($global:octo.outlookUrl)" -Method GET -Uri "https://$($global:octo.outlookUrl)/adminapi/beta/$($global:octo.OnMicrosoft)/Mailbox('$($identifierEncoded)')?isEncoded=true" -MaxAttempts 1 | select -first 1
                if(!$mailbox){
                    $identityCache.$($assignedManagementRole.EffectiveUserName) = $False
                }else{
                    $identityCache.$($assignedManagementRole.EffectiveUserName) = $mailbox
                }
            }
        }catch{
            $identityCache.$($assignedManagementRole.EffectiveUserName) = $False
        }
        if($false -eq $identityCache.$($assignedManagementRole.EffectiveUserName)){
            #mailbox not found, but its a guid (instead of e.g. a group) which are deleted mailboxes and can be ignored
            Write-LogMessage -level 5 -message "Skipping role assignment for $($assignedManagementRole.EffectiveUserName) as it is an orphaned guid (deleted)"
        }else{
            $splat = @{
                targetPath = "/"
                targetType = "ExchangeRole"
                targetId = $assignedManagementRole.Id
                principalEntraId = $mailbox.ExternalDirectoryObjectId
                principalEntraUpn = $mailbox.UserPrincipalName
                principalSysId = $mailbox.Guid
                principalSysName = $mailbox.DisplayName
                principalType = $mailbox.RecipientTypeDetails                
                principalRole = "$($assignedManagementRole.Role) ($($assignedManagementRole.RoleAssignmentDelegationType))"
                through = "$($assignedManagementRole.RoleAssignee)"
            }
            New-ExOPermissionEntry @splat
        }
        
    }

    Write-Progress -Id 3 -Completed -Activity "Scanning Roles"

    Stop-StatisticsObject -category "ExoRoles" -subject "AdminRoles"

    Write-Progress -Id 2 -PercentComplete 75 -Activity "Scanning Exchange Roles" -Status "Writing report..."

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

    Add-ToReportQueue -permissions $permissionRows -category "ExoRoles"
    Remove-Variable -Name permissionRows -Force -Confirm:$False
    Remove-Variable -Name ExOPermissions -Scope Global -Force -Confirm:$False
    Reset-ReportQueue
    Write-Progress -Id 2 -Completed -Activity "Scanning Exchange Roles"
}