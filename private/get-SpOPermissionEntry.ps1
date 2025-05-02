function get-SpOPermissionEntry{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)]$entity,
        [Parameter(Mandatory=$true)]$object,
        [Parameter(Mandatory=$true)]$permission,
        $through="Direct",
        $parentId,
        $linkCreationDate,
        $linkExpirationDate
    )
    
    $localEntity = Get-SpOHarmonizedEntity -entity $entity -alwaysReturn

    $objectType = $object.Type ? $object.Type : "Site"
    
    if([string]::IsNullOrEmpty($parentId)){
        $parentId = ""
    }

    if([string]::IsNullOrEmpty($linkCreationDate)){
        $linkCreationDate = ""
    }

    if([string]::IsNullOrEmpty($linkExpirationDate)){
        $linkExpirationDate = ""
    }    

    if($object.SiteId.Guid){
        $objectId = $object.SiteId.Guid
    }elseif($object.Id.Guid){
        $objectId = $object.Id.Guid
    }else{
        $objectId = $object.Id
    }

    return [PSCustomObject]@{
        "targetType" = $objectType
        "targetId" = $objectId
        "principalEntraId" = $localEntity.AadObjectId
        "principalSysId" = $localEntity.LoginName
        "principalSysName" = $localEntity.Title
        "principalType" = $localEntity.PrincipalType
        "principalRole" = $permission
        "through" = $through
        "parentId" = $parentId
        "endDateTime" = $linkExpirationDate
        "createdDateTime" = $linkCreationDate
    }
}