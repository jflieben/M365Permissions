function get-PBIUserMetaData{
    Param(
        [Parameter(Mandatory=$true)]$user
    )
  
    $retVal = [PSCustomObject]@{
        principalType = "Internal User"
        principalEntraId = $user.graphId
        principalEntraUpn = $user.identifier
    }
    if($user.identifier -like "*#EXT#@*" -or $user.PrincipalType -like "*Guest*"){
        $retVal.principalType = "External User"
    }
    if($user.userType -eq ""){ #special groups
        $retVal.principalType = $user.displayName
        $retVal.principalEntraId = $user.displayName
    }
    if($user.PrincipalType -eq "Group"){
        $retVal.principalType = "EntraSecurityGroup"
    }
    if($user.PrincipalType -eq "App"){
        $retVal.principalEntraId = $user.identifier #we want the object ID since that is the 'true' object ID, the graphId points to the appId
        $retVal.principalEntraUpn = $user.graphId
        $retVal.principalType = "Service Principal"
    }
    if($user.displayName -eq "Whole Organization"){
        $retVal.principalType = "AllInternalUsers"
        $retVal.principalEntraId = "AllInternalUsers"
    }    

    return $retVal
}