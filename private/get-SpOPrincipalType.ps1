function get-SpOPrincipalType{
    Param(
        [Parameter(Mandatory=$true)]$type
    )
    if($type.GetType().BaseType.Name -eq "Enum" -and $type.value__){
        $type = $type.value__
    }
    if([int]::TryParse($type, [ref]$null)){
        switch($type){
            0 { $type = "Unknown" }
            1 { $type = "User" }
            2 { $type = "DistributionList" }
            4 { $type = "EntraSecurityGroup" }
            8 { $type = "SharePointGroup" }
            default { $type = "Unrecognized principle type: $type"}
        }
    }
    return $type
}