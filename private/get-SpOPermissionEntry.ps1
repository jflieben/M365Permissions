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

    if($localEntity.AadObjectId -eq "AllUsers" -and !$global:siteSharingMode.External){
        $localEntity.AadObjectId = "AllInternalUsers"
        Write-LogMessage -level 5 -message "Adjusting permission on $($objectId) from AllUsers to AllInternalUsers as the site does not allow external sharing"
    }
    if($localEntity.AadObjectIdd -eq "Anonymous" -and !$global:siteSharingMode.Anonymous){
        Write-LogMessage -level 5 -message "Skipping permission on $($objectId) because this site does not allow anonymous sharing"
        return $Null
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