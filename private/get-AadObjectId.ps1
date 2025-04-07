function get-aadObjectId{
    Param(
        [Parameter(Mandatory=$true)][String]$upn
    )
    
    if($upn -match '@.*\.'){
        if(!$global:aadUserIdCache){
            $global:aadUserIdCache = @{}
        }
        if($global:aadUserIdCache.Keys -contains $upn){
            if($False -eq $global:aadUserIdCache.$upn){
                return $null
            }else{
                return $global:aadUserIdCache.$upn
            }
        }else{
            $aadUserId = $Null; $aadUserId = try{(new-GraphQuery -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$($upn)?`$select=id").id}catch{}
            if($aadUserId){
                $global:aadUserIdCache.$upn = $aadUserId
                return $aadUserId
            }else{
                $global:aadUserIdCache.$upn = $False
                return $null
            }
        }
    }else{
        return $null
    }
}