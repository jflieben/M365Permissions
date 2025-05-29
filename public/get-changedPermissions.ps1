Function Get-ChangedPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        oldPermissionsReportFolder: the path to the previous report folder you want to compare against, auto-detected if not specified
        newPermissionsReportFolder: the path to the new report folder you want to compare against, auto-detected if not specified
        resources: the resources to compare, default is all resources
    #>        
    Param(
        [Parameter(Mandatory = $false)][String]$oldPermissionsReportFolder,
        [Parameter(Mandatory = $false)][String]$newPermissionsReportFolder,
        [String[]]$resources = @("SharePoint","Onedrive","Teams","O365Group","PowerBI","GroupsAndMembers","Entra","ExoRecipients","ExoRoles","Azure","PowerPlatform")
    )

    $excludeProps = @{
        All = @()
        "Entra" = @("principalName","startDateTime","endDateTime")
        "ExoRecipients" = @("PrincipalName")
        "ExoRoles" = @("PrincipalName")
        "GroupsAndMembers" = @("MemberName","GroupName")
        "O365Group" = @("Name")
        "OneDrive" = @("Name")
        "Teams" = @("Name")
        "SharePoint" = @("Name")
        "PowerBI" = @("createdDateTime","modifiedDateTime")
        "Azure" = @("createdDateTime","modifiedDateTime")
        "PowerPlatform" = @("createdDateTime","modifiedDateTime")
    }

    #register version specific exclusions here to avoid generating large numbers of falsely detected changed permissions.
    #if comparing different versions, the NEW version's one time exclusions will be applied when comparing differences
    $versionChangeTransitionalExclusions = @{
        "1.1.5" = @{"All" = @("ObjectId")}
    }

    if(!$oldPermissionsReportFolder -and !$newPermissionsReportFolder){
        if($global:octo.connection -eq "Connected"){
            Write-LogMessage -Level 4 -message "No report folders specified, auto-detecting changes since last run based on session identifier $($global:octo.userConfig.sessionIdentifier)"
        }else{
            Throw "Please run connect-M365 before using this function, OR specify the report folders manually using -oldPermissionsReportFolder and -newPermissionsReportFolder"
        }
        $newPermissionsReportFolder = $global:octo.userConfig.outputFolder
        $newReportFiles = Get-ChildItem -Path $newPermissionsReportFolder -Filter "*.json" | Where-Object { $_.Name -notlike "*delta*" }
        $allSessions = Get-ChildItem -Path (Split-Path -Path $newPermissionsReportFolder -Parent) -Filter "$($global:octo.tenantName)_*" | Sort-Object -Property Name -Descending
        if($allSessions.Count -lt 2){
            Throw "Less than 2 sessions found for `"$($global:octo.tenantName)`" in $(Split-Path -Path $global:octo.userConfig.outputFolder -Parent), please run a second scan first or specify the report folders manually using -oldPermissionsReportFolder and -newPermissionsReportFolder"
        }
        $oldPermissionsReportFolder = $allSessions[1].FullName
        $oldReportFiles = Get-ChildItem -Path $oldPermissionsReportFolder -Filter "*.json" | Where-Object { $_.Name -notlike "*delta*" }
    }elseif($newPermissionsReportFolder -and $oldPermissionsReportFolder){
        $newReportFiles = Get-ChildItem -Path $newPermissionsReportFolder -Filter "*.json" | Where-Object { $_.Name -notlike "*delta*" }
        $oldReportFiles = Get-ChildItem -Path $oldPermissionsReportFolder -Filter "*.json" | Where-Object { $_.Name -notlike "*delta*" }
    }

    if($newReportFiles.Count -lt 1){
        Throw "Less than 1 JSON reports found in $($newPermissionsReportFolder). Please run a scan first or specify the report folder using -newPermissionsReportFolder"
    }

    if($oldReportFiles.Count -lt 1){
        Throw "Less than 1 JSON reports found in $($oldPermissionsReportFolder). Please run a scan first or specify the report folder using -oldPermissionsReportFolder"
    }

    $currentRunVersion = $null
    Select-String -Path ($newReportFiles | where{$_.Name -like '*statistics.json'} | select -first 1).FullName -Pattern '"Module version"\s*:\s*"([^"]+)"' | Select-Object -First 1 | 
    ForEach-Object { $currentRunVersion = $_.Matches.Groups[1].Value }

    $previousRunVersion = $Null
    Select-String -Path ($oldReportFiles | where{$_.Name -like '*statistics.json'} | select -first 1).FullName -Pattern '"Module version"\s*:\s*"([^"]+)"' | Select-Object -First 1 | 
    ForEach-Object { $previousRunVersion = $_.Matches.Groups[1].Value }

    if($currentRunVersion -and $previousRunVersion){
        if($currentRunVersion -ne $previousRunVersion){
            Write-LogMessage -Level 4 -message "Detected version change from $($previousRunVersion) to $($currentRunVersion), checking transitional exclusions"
            $versionChangeExclusions = $versionChangeTransitionalExclusions.$currentRunVersion
            if($versionChangeExclusions){
                foreach($key in $versionChangeExclusions.Keys){
                    Write-LogMessage -Level 4 -message "Applying transitional exclusions for $($key): $($versionChangeExclusions.$key -join ', ')"
                    $excludeProps.$key += $versionChangeExclusions.$key
                }
            }else{
                Write-LogMessage -Level 4 -message "No transitional exclusions found for $($previousRunVersion) to $($currentRunVersion)"
            }
        }
    }

    Write-LogMessage -Level 3 -message "Comparing $($newPermissionsReportFolder) with $($oldPermissionsReportFolder)"

    $count = 0
    foreach($newReportFile in $newReportFiles){
        $count++
        $diffResults = @()
        $targetFileName = $newReportFile.FullName.Replace(".json","_delta.json")
        $oldReportFile = $oldReportFiles | Where-Object { $_.Name -eq $newReportFile.Name }        
        try{$percentComplete = (($count  / ($newReportFiles.Count)) * 100)}catch{$percentComplete = 0}
        $resource = $newReportFile.Name.Split(".")[0].Split("_")[1]
        if($resources -notcontains $resource){
            continue
        }

        $applicableExclusions = $excludeProps.All + $excludeProps.$resource
        #create the actual regex with the final list of excluded properties
        $pattern = '"(' + ($applicableExclusions -join '|') + ')"'

        Write-Progress -Id 1 -Activity "Comparing reports" -Status "$count / $($newReportFiles.Count) $resource Loading previous permissions..." -PercentComplete $percentComplete        
        $oldTab = $Null; 
        if($oldReportFile){
            $oldTab = ConvertFrom-JsonToHash -path $oldReportFile.FullName -exclusionPattern $pattern
        }

        Write-Progress -Id 1 -Activity "Comparing reports" -Status "$count / $($newReportFiles.Count) $resource Loading current permissions..." -PercentComplete $percentComplete      
        $newTab = $Null; 
        if($newReportFile){
            $newTab = ConvertFrom-JsonToHash -path $newReportFile.FullName -exclusionPattern $pattern
        }  
        
        if(!$oldTab -or $oldTab.Count -eq 0){
            $oldTab = @()
            Write-LogMessage -Level 4 -message "No previous permissions found for $resource"
        }
        if(!$newTab -or $newTab.Count -eq 0){
            $newTab = @()
            Write-LogMessage -Level 4 -message "No current permissions found in $($newReportFile.Name)"
        }     

        Write-Progress -Id 1 -Activity "Comparing reports" -Status "$count / $($newReportFiles.Count) $resource Processing removals..." -PercentComplete $percentComplete

        #current workload found, check for removals
        $i = 0
        foreach($oldObject in $oldTab.Keys){
            try{$percentComplete = ((($i+1)  / ($oldTab.Keys.Count+1)) * 100)}catch{$percentComplete = 0}
            Write-Progress -Id 2 -Activity "Processing removals for $resource" -Status "$($i+1) / $($oldTab.Keys.Count))" -PercentComplete $percentComplete
            $existed = $newTab.ContainsKey($oldObject)
            if (!$existed) {
                if($oldTab[$oldObject] -eq $True){
                    [PSCustomObject]$diffItem = $oldObject | ConvertFrom-Json -Depth 10
                }else{
                    [PSCustomObject]$diffItem = $oldTab[$oldObject] | ConvertFrom-Json -Depth 10
                }                
                $diffItem | Add-Member -MemberType NoteProperty -Name Action -Value "Removed"
                $diffResults += $diffItem
            }
            $i++
        }

        $removedCount = $diffResults.count
        Write-LogMessage -message "Found $($removedCount) removed permissions for $resource"
        Write-Progress -Id 2 -Activity "Processing removals for $resource" -Completed  
        
        Write-Progress -Id 1 -Activity "Comparing reports" -Status "$count / $($newReportFiles.Count) $resource Processing additions / updates..." -PercentComplete $percentComplete

        #current workload found, check for additions
        $i = 0
        foreach($newObject in $newTab.Keys){
            try{$percentComplete = ((($i+1)  / ($newTab.Keys.Count+1)) * 100)}catch{$percentComplete = 0}
            Write-Progress -Id 2 -Activity "Processing additions for $resource" -Status "$($i+1) / $($newTab.Keys.Count))" -PercentComplete $percentComplete
            $existed = $oldTab.ContainsKey($newObject)
            if (!$existed) {
                if($newTab[$newObject] -eq $True){
                    [PSCustomObject]$diffItem = $newObject | ConvertFrom-Json -Depth 10
                }else{
                    [PSCustomObject]$diffItem = $newTab[$newObject] | ConvertFrom-Json -Depth 10
                }
                $diffItem | Add-Member -MemberType NoteProperty -Name Action -Value "New or Updated"
                $diffResults += $diffItem
            }
            $i++
        }
        
        Write-LogMessage -message "Found $($diffResults.count - $removedCount) new or updated permissions for $resource"
        Write-Progress -Id 2 -Activity "Processing additions for $resource" -Completed          

        Write-Progress -Id 1 -Activity "Comparing reports" -Status "$count / $($newReportFiles.Count) $resource storing delta file..." -PercentComplete $percentComplete
        Write-LogMessage -message ""
        if($diffResults.count -eq 0){
            continue
        }
        
        $diffResults | ConvertTo-Json -Depth 100 | Out-File -Path $targetFileName -Force
    }

    Write-Progress -Id 1 -Completed
    Remove-Variable -Name diffResults -Force -Confirm:$False
    [System.GC]::GetTotalMemory($true) | out-null
}