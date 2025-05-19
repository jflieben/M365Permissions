function get-aadObject{
    Param(
        [Parameter(Mandatory=$true)][String]$id
    )
    
    if(!$global:aadObjectCache){
        $global:aadObjectCache = @{}
    }
    if($global:aadObjectCache.Keys -contains $id){
        if($False -eq $global:aadObjectCache.$id){
            return $null
        }else{
            return $global:aadObjectCache.$id
        }
    }else{
        if($id.IndexOf("@") -ne -1){
            $aadObj = $Null; $aadObj = try{(new-GraphQuery -Method GET -Uri "$($global:octo.graphUrl)/v1.0/users/$($id)?`$select=id,userPrincipalName,displayName")}catch{}
        }else{
            $aadObj = $Null; $aadObj = try{(new-GraphQuery -Method GET -Uri "$($global:octo.graphUrl)/v1.0/directoryObjects/$($id)?`$select=id,userPrincipalName,displayName")}catch{}
        }
        if($aadObj){
            $global:aadObjectCache.$id = $aadObj
            return $aadObj
        }else{
            $global:aadObjectCache.$id = $False
            return $null
        }
    }
}