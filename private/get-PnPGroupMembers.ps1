Function Get-PnPGroupMembers{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)]$group,
        $parentId,
        [Parameter(Mandatory=$true)]$siteConn
    )

    Write-LogMessage -level 5 -message "Getting members for group $($group.Title)"

    if($Null -eq $global:octo.PnPGroupCache){
        $global:octo.PnPGroupCache = @{}
    }

    if($global:octo.PnPGroupCache.Keys -contains $($group.Title)){
        return $global:octo.PnPGroupCache.$($group.Title)
    }else{
        [Array]$global:octo.PnPGroupCache.$($group.Title) = @()
    }

    try{$groupGuid = $Null; $groupGuid = $group.LoginName.Split("|")[2].Split("_")[0]}catch{$groupGuid = $Null}

    $harmonizedMember = $Null; $harmonizedMember = Get-SpOHarmonizedEntity -entity $group
    if($harmonizedMember){
        $global:octo.PnPGroupCache.$($group.Title) += $harmonizedMember
    }elseif($groupGuid -and [guid]::TryParse($groupGuid, $([ref][guid]::Empty))){
        try{
            $graphMembers = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/groups/$groupGuid/transitiveMembers" -Method GET -ErrorAction Stop | Where-Object { $_."@odata.type" -eq "#microsoft.graph.user" }
        }catch{
            $graphMembers = @(
                [PSCustomObject]@{
                    "displayName" = $group.Title
                    "userPrincipalName" = $groupGuid
                    "mail" = "FAILED TO ENUMERATE (DELETED?) GROUP MEMBERS!"
                }
            )
        }
        foreach($graphMember in $graphMembers){
            if(!($global:octo.PnPGroupCache.$($group.Title).LoginName | Where-Object {$_ -and $_.EndsWith($graphMember.userPrincipalName)})){
                Write-LogMessage -level 5 -message "Found $($graphMember.displayName) in graph group"
                $global:octo.PnPGroupCache.$($group.Title) += [PSCustomObject]@{
                    "Title" = $graphMember.displayName
                    "LoginName" = "i:0#.f|membership|$($graphMember.userPrincipalName)"
                    "PrincipalType" = "User"
                    "Email" = $graphMember.mail
                }
            }
        }
    }else{
        try{
            $members=$Null; $members = (New-RetryCommand -Command 'Get-PnPGroupMember' -Arguments @{Group = $group.Title; Connection =(Get-SpOConnection -Type User -Url $site.Url)})
        }catch{
            Write-Error "Failed to get members for $($group.Title) because $_" -ErrorAction Continue
        }
        foreach($member in $members){   
            $groupGuid = $Null; try{$groupGuid = $member.LoginName.Split("|")[2].Split("_")[0]}catch{$groupGuid = $Null}
            $harmonizedMember = $Null; $harmonizedMember = Get-SpOHarmonizedEntity -entity $member
            if($harmonizedMember){
                $global:octo.PnPGroupCache.$($group.Title) += $harmonizedMember
                continue
            }

            if($groupGuid -and [guid]::TryParse($groupGuid, $([ref][guid]::Empty))){
                try{
                    $graphMembers = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/groups/$groupGuid/transitiveMembers" -Method GET -ErrorAction Stop | Where-Object { $_."@odata.type" -eq "#microsoft.graph.user" }
                }catch{
                    $graphMembers = @(
                        [PSCustomObject]@{
                            "displayName" = $group.Title
                            "userPrincipalName" = $groupGuid
                            "mail" = "FAILED TO ENUMERATE (DELETED?) GROUP MEMBERS!"
                        }
                    )
                }
                foreach($graphMember in $graphMembers){
                    if(!($global:octo.PnPGroupCache.$($group.Title).LoginName | Where-Object {$_ -and $_.EndsWith($graphMember.userPrincipalName)})){
                        Write-LogMessage -level 5 -message "Found $($graphMember.displayName) in graph group"
                        $global:octo.PnPGroupCache.$($group.Title) += [PSCustomObject]@{
                            "Title" = $graphMember.displayName
                            "LoginName" = "i:0#.f|membership|$($graphMember.userPrincipalName)"
                            "PrincipalType" = "User"
                            "Email" = $graphMember.mail
                        }
                    }
                }
                continue
            }
            if($member.Id -ne $parentId){
                if($member.PrincipalType -eq "User" -and $global:octo.PnPGroupCache.$($group.Title) -notcontains $member){
                    Write-LogMessage -level 5 -message "Found $($member.Title) in sec group"
                    $global:octo.PnPGroupCache.$($group.Title) += $member
                    continue
                }
                if($member.PrincipalType -eq "SecurityGroup" -or $member.PrincipalType -eq "SharePointGroup"){
                    $subMembers = Get-PnPGroupMembers -name $member.Title -parentId $member.Id -siteConn $siteConn
                    foreach($subMember in $subMembers){
                        if($global:octo.PnPGroupCache.$($group.Title) -notcontains $subMember){
                            Write-LogMessage -level 5 -message "Found $($subMember.Title) in sub sec group"
                            $global:octo.PnPGroupCache.$($group.Title) += $subMember
                        }
                    }
                }
            }
        }
    }   

    return $global:octo.PnPGroupCache.$($group.Title)
}