function get-SpOAadObjectId{
    Param(
        [Parameter(Mandatory=$true)][String]$loginName
    )
    
    try{
        $aadObjectId = $loginName.Split("|")[-1].Replace("_o","") #owner notation in SPO should be stripped as this invalidates the GUID
    }catch{
        return $Null
    }
    if([guid]::TryParse($aadObjectId, $([ref][guid]::Empty))){
        return $aadObjectId
    }elseif($aadObjectId -match '@.*\.'){
        if(!$global:aadUserIdCache){
            $global:aadUserIdCache = @{}
        }
        if($global:aadUserIdCache.Keys -contains $aadObjectId){
            if($False -eq $global:aadUserIdCache.$aadObjectId){
                return $null
            }else{
                return $global:aadUserIdCache.$aadObjectId
            }
        }else{
            $aadUserId = $Null; $aadUserId = try{(new-GraphQuery -Method GET -Uri "$($global:octo.graphUrl)/v1.0/users/$($aadObjectId.replace('#ext#',''))?`$select=id").id}catch{}
            if($aadUserId){
                $global:aadUserIdCache.$aadObjectId = $aadUserId
                return $aadUserId
            }else{
                $global:aadUserIdCache.$aadObjectId = $False
                return $null
            }
        }
    }elseif($loginName.StartsWith("c:0-.f")){
        return "AllInternalUsers"
    }elseif($loginName.StartsWith("c:0(.s|true")){
        return "AllUsers"
    }elseif($loginName -eq "Anonymous"){
        return "Anonymous"
    }else{
        return $null
    }
}