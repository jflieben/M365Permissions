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
    $count = 0
    foreach($uniqueUser in $assignedManagementRoles | Select-Object -ExpandProperty EffectiveUserName -Unique){
        $count++
        Write-Progress -Id 3 -PercentComplete (($count/$assignedManagementRoles.Count)*100) -Activity "Scanning Roles" -Status "Examining role $($count) of $($assignedManagementRoles.Count)"
        
        $identifierEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($uniqueUser))   
        try{
            $mailbox = $Null; $mailbox = New-GraphQuery -resource "https://outlook.office365.com" -Method GET -Uri "https://outlook.office365.com/adminapi/beta/$($global:octo.OnMicrosoft)/Mailbox('$($identifierEncoded)')?isEncoded=true" -MaxAttempts 2 | select -first 1
        }catch{
            $mailbox = $null;
        }
        if($mailbox){
            #process role group assignments
            $groupAssignments = $assignedManagementRoles | Where-Object { $_.EffectiveUserName -eq $uniqueUser -and $_.RoleAssigneeType -eq "RoleGroup" -and $_.Enabled} | Group-Object -Property RoleAssignee
            foreach($group in $groupAssignments){
                $assignment = $group.Group | select-object -first 1
                $scopes = @($assignment.RecipientReadScope, $assignment.RecipientWriteScope) | select-object -Unique
                foreach($scope in $scopes){      
                    Update-StatisticsObject -category "ExoRoles" -subject "AdminRoles"             
                    $splat = @{
                        targetPath = "/ExchangeOnline/$scope"
                        targetType = "ExchangeRole"
                        targetId = $assignment.RoleAssigneeName
                        principalEntraId = $mailbox.ExternalDirectoryObjectId
                        principalEntraUpn = $mailbox.UserPrincipalName
                        principalSysId = $mailbox.Guid
                        principalSysName = $mailbox.DisplayName
                        principalType = $mailbox.RecipientTypeDetails                
                        principalRole = $assignment.RoleAssigneeName
                        through = "Role Group"
                    }
                    New-ExOPermissionEntry @splat
                }
            }

            #process direct assignments
            $directAssignments = $assignedManagementRoles | Where-Object { $_.EffectiveUserName -eq $uniqueUser -and $_.RoleAssigneeType -ne "RoleGroup" -and $_.Enabled} | Group-Object -Property Role
            foreach($group in $directAssignments){
                $assignment = $group.Group | select-object -first 1
                $scopes = @($assignment.RecipientReadScope, $assignment.RecipientWriteScope) | select-object -Unique
                foreach($scope in $scopes){
                    Update-StatisticsObject -category "ExoRoles" -subject "AdminRoles"
                    $splat = @{
                        targetPath = "/ExchangeOnline/$scope"
                        targetType = "ExchangeRole"
                        targetId = $assignment.Role
                        principalEntraId = $mailbox.ExternalDirectoryObjectId
                        principalEntraUpn = $mailbox.UserPrincipalName
                        principalSysId = $mailbox.Guid
                        principalSysName = $mailbox.DisplayName
                        principalType = $mailbox.RecipientTypeDetails                
                        principalRole = $assignment.Role
                        through = "Direct"
                    }
                    New-ExOPermissionEntry @splat
                }
            }
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