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
        [String[]]$resources = @("Onedrive","Teams","O365Group","PowerBI","GroupsAndMembers","Entra","ExoRecipients","ExoRoles")
    )

    $excludeProps = @("modified","endDateTime")

    if(!$oldPermissionsReportFolder -and !$newPermissionsReportFolder){
        if($global:octo.connection -eq "Connected"){
            Write-LogMessage -Level 4 -message "No report folders specified, auto-detecting based on session identifier $($global:octo.userConfig.sessionIdentifier)"
        }else{
            Throw "Please run connect-M365 before using this function, OR specify the report folders manually using -oldPermissionsReportFolder and -newPermissionsReportFolder"
        }
        $newPermissionsReportFolder = $global:octo.userConfig.outputFolder
        $newReportFiles = Get-ChildItem -Path $newPermissionsReportFolder -Recurse -Filter "*.json" | Where-Object { $_.Name -notlike "*delta*" }
        $allSessions = Get-ChildItem -Path (Split-Path -Path $newPermissionsReportFolder -Parent) -Filter "$($global:octo.tenantName)_*" | Sort-Object -Property Name -Descending
        if($allSessions.Count -lt 2){
            Throw "Less than 2 sessions found for `"$($global:octo.tenantName)`" in $(Split-Path -Path $global:octo.userConfig.outputFolder -Parent), please run a second scan first or specify the report folders manually using -oldPermissionsReportFolder and -newPermissionsReportFolder"
        }
        $oldPermissionsReportFolder = $allSessions[1].FullName
        $oldReportFiles = Get-ChildItem -Path $oldPermissionsReportFolder -Recurse -Filter "*.json" | Where-Object { $_.Name -notlike "*delta*" }
    }elseif($newPermissionsReportFolder -and $oldPermissionsReportFolder){
        $newReportFiles = Get-ChildItem -Path $newPermissionsReportFolder -Recurse -Filter "*.json" | Where-Object { $_.Name -notlike "*delta*" }
        $oldReportFiles = Get-ChildItem -Path $oldPermissionsReportFolder -Recurse -Filter "*.json" | Where-Object { $_.Name -notlike "*delta*" }
    }

    if($newReportFiles.Count -lt 1){
        Throw "Less than 1 JSON reports found in $($newPermissionsReportFolder). Please run a scan first or specify the report folder using -newPermissionsReportFolder"
    }

    if($oldReportFiles.Count -lt 1){
        Throw "Less than 1 JSON reports found in $($oldPermissionsReportFolder). Please run a scan first or specify the report folder using -oldPermissionsReportFolder"
    }

    Write-LogMessage -Level 4 -message "Comparing $($newPermissionsReportFolder.Name) with $($oldPermissionsReportFolder.Name)"

    $count = 0
    foreach($newReportFile in $newReportFiles){
        $count++
        $diffResults = @()
        $targetFileName = $newReportFile.FullName.Replace(".json","_delta.json")
        $oldReportFile = $oldReportFiles | Where-Object { $_.Name -eq $newReportFile.Name }        
        try{$percentComplete = (($count  / ($resources.Count)) * 100)}catch{$percentComplete = 0}
        $resource = $newReportFile.Name.Split(".")[0].Split("_")[1]
        if($resources -notcontains $resource){
            continue
        }
        Write-Progress -Id 1 -Activity "Comparing reports" -Status "$count / $($resources.Count) $resource Loading previous permissions..." -PercentComplete $percentComplete        
        $oldTab = $Null; $oldTab = Get-Content -Path $oldReportFile.FullName | ConvertFrom-Json
        Write-Progress -Id 1 -Activity "Comparing reports" -Status "$count / $($resources.Count) $resource Loading current permissions..." -PercentComplete $percentComplete        
        $newTab = $Null; $newTab = Get-Content -Path $newReportFile.FullName | ConvertFrom-Json
        Write-Progress -Id 1 -Activity "Comparing reports" -Status "$count / $($resources.Count) $resource Hashing data..." -PercentComplete $percentComplete
        if(!$oldTab -or $oldTab.Count -eq 0){
            $oldTab = @()
            Write-LogMessage -Level 4 -message "No previous permissions found in $($oldReportFile.Name)"
        }
        if(!$newTab -or $newTab.Count -eq 0){
            $newTab = @()
            Write-LogMessage -Level 4 -message "No previous permissions found in $($newReportFile.Name)"
        }     

        $newJsonSet = @{}
        foreach ($item in $newTab) {
            $json = $item | Select-Object -Property ($item.PSObject.Properties.Name | Where-Object { $_ -notin $excludeProps }) | ConvertTo-Json -Depth 10
            $newJsonSet[$json] = $true  # Store JSON as keys in a hash table
        }    
        
        $oldJsonSet = @{}
        foreach ($item in $oldTab) {
            $json = $item | Select-Object -Property ($item.PSObject.Properties.Name | Where-Object { $_ -notin $excludeProps }) | ConvertTo-Json -Depth 10
            $oldJsonSet[$json] = $true  # Store JSON as keys in a hash table
        }      

        Write-Progress -Id 1 -Activity "Comparing reports" -Status "$count / $($resources.Count) $resource Processing removals..." -PercentComplete $percentComplete

        #current workload found, check for removals
        for($i=0;$i -lt $oldTab.Count;$i++){
            try{$percentComplete = ((($i+1)  / ($oldTab.Count+1)) * 100)}catch{$percentComplete = 0}
            Write-Progress -Id 2 -Activity "Processing removals for $resource" -Status "$($i+1) / $($oldTab.Count))" -PercentComplete $percentComplete
        
            $oldRow = $oldTab[$i] | Select-Object -Property ($oldTab[$i].PSObject.Properties.Name | Where-Object { $_ -notin $excludeProps })  | ConvertTo-Json -Depth 10
            
            $existed = $newJsonSet.ContainsKey($oldRow)  
            if (!$existed) {
                [PSCustomObject]$diffItem = $oldTab[$i]
                $diffItem | Add-Member -MemberType NoteProperty -Name Action -Value "Removed"
                $diffResults += $diffItem
            }
        }
        $removedCount = $diffResults.count
        Write-LogMessage -message "Found $($removedCount) removed permissions for $resource"
        Write-Progress -Id 2 -Activity "Processing removals for $resource" -Completed  
        
        Write-Progress -Id 1 -Activity "Comparing reports" -Status "$count / $($resources.Count) $resource Processing additions / updates..." -PercentComplete $percentComplete

        #current workload found, check for additions
        for($i=0;$i -lt $newTab.Count;$i++){
            try{$percentComplete = ((($i+1)  / ($newTab.Count+1)) * 100)}catch{$percentComplete = 0}
            Write-Progress -Id 2 -Activity "Processing additions for $resource" -Status "$($i+1) / $($newTab.Count))" -PercentComplete $percentComplete            
            $newRow = $newTab[$i] | Select-Object -Property ($newTab[$i].PSObject.Properties.Name | Where-Object { $_ -notin $excludeProps })  | ConvertTo-Json -Depth 10
            
            $existed = $oldJsonSet.ContainsKey($newRow)                      
            if (!$existed) {
                [PSCustomObject]$diffItem = $newTab[$i]
                $diffItem | Add-Member -MemberType NoteProperty -Name Action -Value "New or Updated"
                $diffResults += $diffItem
            }
        }
        Write-LogMessage -message "Found $($diffResults.count - $removedCount) added or updated permissions for $resource"
        Write-Progress -Id 2 -Activity "Processing additions for $resource" -Completed          

        Write-Progress -Id 1 -Activity "Comparing reports" -Status "$count / $($resources.Count) $resource storing delta file..." -PercentComplete $percentComplete
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