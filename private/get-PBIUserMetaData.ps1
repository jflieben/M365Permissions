function get-PBIUserMetaData{
    Param(
        [Parameter(Mandatory=$true)]$user
    )
    $retVal = [PSCustomObject]@{
        principalType = "Internal User"
        principalEntraId = $user.graphId
        principalEntraUpn = $user.identifier
    }
    if($user.identifier -like "*#EXT#@*"){
        $retVal.principalType = "External User"
    }
    if($user.displayName -eq "Whole Organization"){
        $retVal.principalType = "AllInternalUsers"
        $retVal.principalEntraId = "AllInternalUsers"
    }
    if($user.PrincipalType -eq "Group"){
        $retVal.principalType = "EntraSecurityGroup"
    }

    return $retVal
}