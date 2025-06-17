Function get-AllPBIPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -excludeGroupsAndUsers: exclude group and user memberships from the report, only show role assignments
    #>        
    Param(
        [Switch]$skipReportGeneration
    )

    $activity = "Scanning PowerBI"

    #check if user has a powerbi license or this function will fail
    if($global:octo.userConfig.authMode -eq "Delegated"){
        $powerBIServicePlans = @("PBI_PREMIUM_EM1_ADDON","PBI_PREMIUM_EM2_ADDON","BI_AZURE_P_2_GOV","PBI_PREMIUM_P1_ADDON_GCC","PBI_PREMIUM_P1_ADDON","BI_AZURE_P3","BI_AZURE_P2","BI_AZURE_P1")
        $hasPowerBI = $False
        $licenses = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/users/$($global:octo.currentUser.userPrincipalName)/licenseDetails" -Method GET
        if($licenses){
            foreach($servicePlan in $licenses.servicePlans.servicePlanName){
                if($powerBIServicePlans -contains $servicePlan){
                    $hasPowerBI = $True
                    break
                }
            }
        }

        if(!$hasPowerBI){
            Write-Error "You do not have a PowerBI license, this function requires a PowerBI license assigned to the user you're logged in with unless using a Service Principal" -ErrorAction Continue
            return $Null
        }
    }

    Write-LogMessage -message "Starting PowerBI scan..." -level 4
    New-StatisticsObject -category "PowerBI" -subject "Securables"
    Write-Progress -Id 1 -PercentComplete 0 -Activity $activity -Status "Retrieving workspaces..."

    $global:PBIPermissions = @{}

    try{
        $workspaces = New-GraphQuery -Uri "$($global:octo.powerbiUrl)/v1.0/myorg/admin/groups?`$top=5000" -resource $global:octo.fabricUrl -method "GET" -maxAttempts 2
    }catch{
        if($_.Exception.Message -like "*401*"){
            Write-Error "You have not (yet) configured the correct permissions in PowerBI, aborting scan of PowerBI. See https://www.lieben.nu/liebensraum/2025/03/allowing-a-service-principal-to-scan-powerbi/ for instructions!" -ErrorAction Continue
            return $Null
        }else{
            Throw $_
        }
    }

    $workspaceParts = [math]::ceiling($workspaces.Count / 100)

    if($workspaceParts -gt 50){
        Throw "More than 5000 workspaces detected, this module does not support environments with > 5000 workspaces. Please use the MSSQL/.NET backed M365Permissions Cloud"
    }

    Write-Progress -Id 1 -PercentComplete 5 -Activity $activity -Status "Submitting $workspaceParts scanjobs for $($workspaces.count) workspaces..."

    $scanJobs = @()
    for($i=0;$i -lt $workspaceParts;$i++){
        $body = @{"workspaces" = $workspaces.id[($i*100)..($i*100+99)]} | ConvertTo-Json
        if($i/16 -eq 1){
            Write-LogMessage -message "Sleeping for 60 seconds to prevent throttling..." -level 4
            Start-Sleep -Seconds 60
        }
        $scanJobs += New-GraphQuery -Uri "$($global:octo.powerbiUrl)/v1.0/myorg/admin/workspaces/getInfo?datasourceDetails=True&getArtifactUsers=True" -Method POST -Body $body -resource $global:octo.fabricUrl
    }

    if($global:octo.userConfig.authMode -eq "Delegated"){
        Write-Progress -Id 1 -PercentComplete 10 -Activity $activity -Status "Retrieving gateways..."
        $gateways = New-GraphQuery -Uri "$($global:octo.powerbiUrl)/v2.0/myorg/gatewayclusters?`$expand=permissions&`$skip=0&`$top=5000" -resource $global:octo.fabricUrl -method "GET"
        for($g = 0; $g -lt $gateways.count; $g++){
            Update-StatisticsObject -category "PowerBI" -subject "Securables"
            Write-Progress -Id 2 -PercentComplete $(Try{ ($g/$gateways.count)*100 } catch {0}) -Activity "Analyzing gateways..." -Status "$($g+1)/$($gateways.count) $($gateways[$g].id)"
            foreach($user in $gateways[$g].permissions){
                $permissionSplat = @{
                    targetPath = "/gateways/$($gateways[$g].type)/$($gateways[$g].id)"
                    targetType = "Gateway"
                    targetId = $gateways[$g].id
                    principalRole = $user.role
                }
                
                if($user.principalType -eq "Group"){
                    $permissionSplat["principalEntraId"] = $user.graphId
                    $permissionSplat["principalEntraUpn"] = ""
                    $permissionSplat["principalSysId"] = $user.graphId
                    $permissionSplat["principalSysName"] = $user.displayName
                    $permissionSplat["principalType"] = "EntraSecurityGroup"
                    $permissionSplat["through"] = "EntraSecurityGroup"
                    New-PBIPermissionEntry @permissionSplat
                }else{
                    $userId = $Null; $userId = $user.id.Replace("app-","")
                    if($user.id.startsWith("app-")){
                        $userMetaData = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/serviceprincipals(appId='$userId')" -Method GET
                    }else{
                        try{
                            $userMetaData = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/users/$userId" -Method GET -maxAttempts 2
                        }catch{
                            Write-LogMessage -level 2 -message "Failed to retrieve user metadata for $($user.id), user was likely deleted, skipping..."
                            continue
                        }
                    }
                    $permissionSplat["principalEntraId"] = $userId
                    $permissionSplat["principalEntraUpn"] = $userMetaData.userPrincipalName
                    $permissionSplat["principalSysId"] = $userMetaData.id
                    $permissionSplat["principalSysName"] = $userMetaData.displayName
                    $permissionSplat["principalType"] = $($user.principalType)
                    New-PBIPermissionEntry @permissionSplat
                }
            }
        }

        Write-Progress -Id 2 -Completed -Activity "Analyzing gateways..."
    }else{
        Write-LogMessage -level 2 -message "Skipping gateway analysis, this function requires delegated authentication mode"
    }

    Write-Progress -Id 1 -PercentComplete 15 -Activity $activity -Status "Waiting for scan jobs to complete..."
    foreach($scanJob in $scanJobs){
        do{
            $res = New-GraphQuery -Uri "$($global:octo.powerbiUrl)/v1.0/myorg/admin/workspaces/scanStatus/$($scanJob.id)" -Method GET -resource $global:octo.fabricUrl
            if($res.status -ne "Succeeded"){
                Write-LogMessage -message "Scan job $($scanJob.id) status $($res.status), sleeping for 30 seconds..." -level 4
                Start-Sleep -Seconds 30
            }
        }until($res.status -eq "Succeeded")
        Write-LogMessage -message "Scan job $($scanJob.id) completed" -level 4
    }

    Write-Progress -Id 1 -PercentComplete 25 -Activity $activity -Status "Receiving scan job results..."
    $scanResults = @()
    foreach($scanJob in $scanJobs){
        $scanResults += (New-GraphQuery -Uri "$($global:octo.powerbiUrl)/v1.0/myorg/admin/workspaces/scanResult/$($scanJob.id)" -Method GET -resource $global:octo.fabricUrl).workspaces
    }
    
    Write-Progress -Id 1 -PercentComplete 45 -Activity $activity -Status "Processing PowerBI securables..."
    $secureableTypes = @{
        "reports" = @{
            "Type" = "Report"
            "UserAccessRightProperty" = "reportUserAccessRight"
            "CreatedProperty" = "createdDateTime"
            "ModifiedProperty" = "modifiedDateTime"
        }
        "datasets" = @{
            "Type" = "Dataset"
            "UserAccessRightProperty" = "datasetUserAccessRight"
            "CreatedProperty" = "createdDate"
            "ModifiedProperty" = "N/A"
        }    
        "Lakehouse" = @{
            "Type" = "Lakehouse"
            "UserAccessRightProperty" = "artifactUserAccessRight"
            "CreatedProperty" = "createdDate"
            "ModifiedProperty" = "lastUpdatedDate"
        } 
        "warehouses" = @{
            "Type" = "Warehouse"
            "UserAccessRightProperty" = "datamartUserAccessRight"
            "CreatedProperty" = "N/A"
            "ModifiedProperty" = "modifiedDateTime"
        }                                              
    }
    for($s=0;$s -lt $scanResults.count; $s++){
        Write-Progress -Id 2 -PercentComplete $(Try{ ($s/$scanResults.count)*100 } catch {0}) -Activity "Analyzing securables..." -Status "$($s+1)/$($scanResults.count) $($scanResults[$s].name)"
        foreach($secureableType in $secureableTypes.Keys){ #$secureableType = "reports"
            foreach($secureable in $scanResults[$s].$secureableType){ #$secureable = $scanResults[$s].$secureableType[0]
                Update-StatisticsObject -category "PowerBI" -subject "Securables"
                $created = $secureableTypes.$secureableType.CreatedProperty -eq "N/A" ? $Null : $secureable.$($secureableTypes.$secureableType.CreatedProperty)
                $modified = $secureableTypes.$secureableType.ModifiedProperty -eq "N/A" ? $Null : $secureable.$($secureableTypes.$secureableType.ModifiedProperty)
                foreach($user in $secureable.users){ #$user = $secureable.users[0]
                    $metaData = $Null;$metaData = get-PBIUserMetaData -user $user
                    $permissionSplat = @{
                        targetPath = "/workspaces/$($scanResults[$s].name)/$secureableType/$($secureable.name)"
                        targetType = $secureableTypes.$secureableType.Type
                        targetId = $secureable.id
                        createdDateTime = $created
                        modifiedDateTime = $modified
                        principalEntraId = $metaData.principalEntraId
                        principalEntraUpn = ""
                        principalSysId = $user.graphId
                        principalSysName = $user.displayName
                        principalType = $metaData.principalType
                        principalRole = $user.$($secureableTypes.$secureableType.UserAccessRightProperty)
                        through = if($metaData.principalType -eq "EntraSecurityGroup"){$metaData.principalType}else{"Direct"}           
                    }
                    New-PBIPermissionEntry @permissionSplat 
                }                  
            }
        }
    }

    Write-Progress -Id 2 -Completed -Activity "Analyzing securables..."

    $anonPublishedReports = New-GraphQuery -Uri "https://api.powerbi.com/v1.0/myorg/admin/widelySharedArtifacts/publishedToWeb?`$top=5000'" -Method GET -resource "https://api.fabric.microsoft.com"
    for($s = 0; $s -lt $anonPublishedReports.ArtifactAccessEntities.count; $s++){
        Write-Progress -Id 2 -PercentComplete $(Try{ ($s/$anonPublishedReports.ArtifactAccessEntities.count)*100 } catch {0}) -Activity "Analyzing anonymous reports..." -Status "$($s+1)/$($anonPublishedReports.ArtifactAccessEntities.count) $($anonPublishedReports.ArtifactAccessEntities[$s].displayName)"
        $metaData = $Null;$metaData = get-PBIUserMetaData -user $user
        $permissionSplat = @{
            targetPath = "/webpublished/$($anonPublishedReports.ArtifactAccessEntities[$s].displayName)"
            targetType = $anonPublishedReports.ArtifactAccessEntities[$s].artifactType
            targetId = $anonPublishedReports.ArtifactAccessEntities[$s].artifactId
            principalEntraId = "Anonymous"
            principalEntraUpn = "Anonymous"
            principalSysId = "Anonymous"
            principalSysName = "Anonymous"
            principalType = $anonPublishedReports.ArtifactAccessEntities[$s].shareType
            principalRole = if($anonPublishedReports.ArtifactAccessEntities[$s].accessRight -eq "None"){"Read"}else{$anonPublishedReports.ArtifactAccessEntities[$s].accessRight}
            through = $anonPublishedReports.ArtifactAccessEntities[$s].shareType
        }
        New-PBIPermissionEntry @permissionSplat    
    }
    
    Write-Progress -Id 2 -Completed -Activity "Analyzing anonymous reports..."

    Stop-StatisticsObject -category "PowerBI" -subject "Securables"

    Write-Progress -Id 1 -PercentComplete 90 -Activity $activity -Status "Writing report..."

    $permissionRows = foreach($row in $global:PBIPermissions.Keys){
        foreach($permission in $global:PBIPermissions.$row){
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
   
    Add-ToReportQueue -permissions $permissionRows -category "PowerBI"
    Remove-Variable -Name PBIPermissions -Scope Global -Force -Confirm:$False
    if(!$skipReportGeneration){
        Write-LogMessage -message "Generating report..." -level 4
        Write-Report
    }else{
        Reset-ReportQueue
    }
    Write-Progress -Id 1 -Completed -Activity $activity
}