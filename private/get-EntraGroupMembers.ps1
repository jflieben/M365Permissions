function get-entraGroupMembers {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     
    Param(
        [Parameter(Mandatory=$true)]$groupId,
        [switch]$includeNonUsers
    )

    try{
        if($includeNonUsers){
            [Array]$groupMembers = new-GraphQuery -Method GET -Uri "https://graph.microsoft.com/beta/groups/$groupId/transitiveMembers" | Where-Object {$_ -and $_."@odata.type" -ne "#microsoft.graph.group" }
        }else{
            [Array]$groupMembers = new-GraphQuery -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/transitiveMembers" | Where-Object {$_ -and $_."@odata.type" -ne "#microsoft.graph.group" }
        }
    }catch{
        [Array]$groupMembers = @()
    }


    for($i=0;$i -lt $groupMembers.count;$i++){
        if($groupmembers[$i]."@odata.type" -eq "#microsoft.graph.user"){
            if($groupMembers[$i].userPrincipalName -like "*#EXT#@*"){
                $groupMembers[$i] | Add-Member -MemberType NoteProperty -Name "principalType" -Value "External User" -Force
            }else{
                $groupMembers[$i] | Add-Member -MemberType NoteProperty -Name "principalType" -Value "Internal User" -Force
            }
        }else{
            $groupMembers[$i] | Add-Member -MemberType NoteProperty -Name "principalType" -Value $groupmembers[$i]."@odata.type".Split(".")[2] -Force
        }
    }
    return $groupMembers
}