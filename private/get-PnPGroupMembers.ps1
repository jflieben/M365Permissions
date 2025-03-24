Function Get-PnPGroupMembers{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)]$group,
        $topLevelGroupName,
        $parentId,
        [Parameter(Mandatory=$true)]$siteConn
    )

    if($topLevelGroupName){
        $localGroupName = $topLevelGroupName
    }else{
        $localGroupName = $group.Title
    }

    if($Null -eq $global:octo.PnPGroupCache){
        $global:octo.PnPGroupCache = @{}
    }

    if($group.LoginName -and $group.LoginName.EndsWith("_o")){ #$string -match '\b[\da-f]{8}-([\da-f]{4}-){3}[\da-f]{12}\b'
        $group.Title = $group.Title + "_ENTRAOWNERS"
    }
    
    if(!$topLevelGroupName){
        if($global:octo.PnPGroupCache.Keys -contains $localGroupName){
            return $global:octo.PnPGroupCache.$($localGroupName)
        }else{
            [Array]$global:octo.PnPGroupCache.$($localGroupName) = @()
        }
    }

    if($group.LoginName -and $group.LoginName.EndsWith("_o")){
        Write-LogMessage -level 5 -message "Getting OWNERS for group $($group.Title)" 
        $groupGuid = $group.LoginName.Split("|")[-1].Split("_")[0]
        if($groupGuid -and [guid]::TryParse($groupGuid, $([ref][guid]::Empty))){
            $groupOwners = Get-EntraGroupOwners -groupId $groupGuid
            foreach($graphMember in $groupOwners){
                if(!($global:octo.PnPGroupCache.$($localGroupName).LoginName | Where-Object {$_ -and $_.EndsWith($graphMember.userPrincipalName)})){
                    Write-LogMessage -level 5 -message "Found $($graphMember.displayName) in graph group"
                    $global:octo.PnPGroupCache.$($localGroupName) += [PSCustomObject]@{
                        "Title" = $graphMember.displayName
                        "AadObjectId"= $graphMember.id
                        "LoginName" = "i:0#.f|membership|$($graphMember.userPrincipalName)"
                        "PrincipalType" = "User"
                        "Email" = $graphMember.mail
                    }
                }
            }   
            return $global:octo.PnPGroupCache.$($localGroupName)         
        }
    }
    
    Write-LogMessage -level 5 -message "Getting members for group $($group.Title)"  

    $harmonizedMember = $Null; $harmonizedMember = Get-SpOHarmonizedEntity -entity $group
    if($harmonizedMember -and $global:octo.PnPGroupCache.$($localGroupName).LoginName -notcontains $harmonizedMember.LoginName){
        Write-LogMessage -level 5 -message "Found $($harmonizedMember.Title) in group"
        $global:octo.PnPGroupCache.$($localGroupName) += $harmonizedMember
        return $global:octo.PnPGroupCache.$($localGroupName)
    }    

    $groupAadObjectId = $Null; $groupAadObjectId = Get-SpOAadObjectId -loginName $group.LoginName
    
    #AAD Backend Group, just return the group
    if($groupAadObjectId){
        $newObj = $null; $newObj = Get-SpOHarmonizedEntity -entity $group -alwaysReturn
        if($global:octo.PnPGroupCache.$($localGroupName).LoginName -notcontains $newObj.LoginName){
            Write-LogMessage -level 5 -message "Found $($newObj.Title) in group"
            $global:octo.PnPGroupCache.$($localGroupName) += $newObj
        }
    }else{
        #SPO Group
        try{
            $spoGroupMembers=$Null; $spoGroupMembers = (New-RetryCommand -Command 'Get-PnPGroupMember' -Arguments @{Group = $group.Title; Connection =(Get-SpOConnection -Type User -Url $site.Url)})
        }catch{
            Throw "Failed to get members for $($group.Title) because $_"
        }
        foreach($spoGroupMember in $spoGroupMembers){
            if($spoGroupMember.PrincipalType -like "*group*"){
                Get-PnPGroupMembers -group $spoGroupMember -parentId $spoGroupMember.Id -siteConn $siteConn -topLevelGroupName $localGroupName | Out-Null
                #$group =$spoGroupMember;$parentId = $spoGroupMember.Id;$topLevelGroupName= $localGroupName 
            }else{
                $newObj = $null; $newObj = Get-SpOHarmonizedEntity -entity $spoGroupMember -alwaysReturn
                if($global:octo.PnPGroupCache.$($localGroupName).LoginName -notcontains $newObj.LoginName){
                    Write-LogMessage -level 5 -message "Found $($newObj.Title) in group"
                    $global:octo.PnPGroupCache.$($localGroupName) += $newObj
                }
            }
        }
    }

    return $global:octo.PnPGroupCache.$($localGroupName)
}