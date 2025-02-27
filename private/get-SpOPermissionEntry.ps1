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
        $through,
        $parent,
        $linkCreationDate,
        $linkExpirationDate
    )
    
    $localEntity = (Get-SpOHarmonizedEntity -entity $entity -alwaysReturn)

    $name = $localEntity.Title
    $type = $localEntity.PrincipalType

    $objectType = $object.Type ? $object.Type : "root"
    
    if([string]::IsNullOrEmpty($parent)){
        $parent = ""
    }

    if([string]::IsNullOrEmpty($linkCreationDate)){
        $linkCreationDate = ""
    }

    if([string]::IsNullOrEmpty($linkExpirationDate)){
        $linkExpirationDate = ""
    }    

    return [PSCustomObject]@{
        "Object" = $objectType
        "Name" = $name
        "Identity" = $localEntity.LoginName
        "Email" = $localEntity.Email
        "Type" = $type
        "Permission" = $permission
        "Through" = $through
        "Parent" = $parent
        "LinkCreationDate" = $linkCreationDate
        "LinkExpirationDate" = $linkExpirationDate
    }
}