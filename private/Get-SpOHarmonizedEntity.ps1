Function Get-SpOHarmonizedEntity{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)][Object]$entity,
        [Switch]$alwaysReturn
    )

    if($entity.LoginName){
        if($entity.LoginName.Split("|")[0] -eq "c:0(.s"){
            Write-LogMessage -level 5 -message "Found $($entity.Title) special group"
            return [PSCustomObject]@{
                "Title" = $entity.Title
                "AadObjectId"= get-SpOAadObjectId -loginName $entity.LoginName
                "LoginName" = $entity.LoginName
                "PrincipalType" = "AllUsers"
                "Email" = "N/A"
            }      
        }
        if($entity.LoginName.Split("|")[0] -eq "c:0-.f"){
            Write-LogMessage -level 5 -message "Found $($entity.Title) special group"
            return [PSCustomObject]@{
                "Title" = $entity.Title
                "AadObjectId"= get-SpOAadObjectId -loginName $entity.LoginName
                "LoginName" = $entity.LoginName
                "PrincipalType" = "AllInternalUsers"
                "Email" = "N/A"
            }      
        }
        <#if($entity.LoginName.Split("|")[0] -eq "c:0t.c"){
            Write-LogMessage -level 5 -message "Found $($entity.Title) special group"
            return [PSCustomObject]@{
                "Title" = $entity.Title
                "AadObjectId"= get-SpOAadObjectId -loginName $spoSiteAdmin.LoginName
                "LoginName" = $entity.LoginName
                "PrincipalType" = "EntraSecurityGroup"
                "Email" = "N/A"
            }      
        }#>
    }

    if($alwaysReturn){
        if($entity.ObjType -and $entity.ObjType -eq "Invitee"){
            return [PSCustomObject]@{
                "Title" = $entity.Title
                "AadObjectId"= ""
                "LoginName" = $entity.LoginName
                "PrincipalType" = $entity.PrincipalType
                "Email" = $entity.Email
            }
        }
        $aadObjectId = $Null; try{$aadObjectId = Get-SpOAadObjectId -loginName $entity.LoginName}catch{}
        $type = get-SpOPrincipalType -type $entity.PrincipalType
        if($type -eq "User"){
            if($entity.Title -eq "External User" -or $entity.LoginName -like "*#EXT#*"){
                $type = "External User"
            }else{
                $type = "Internal User"
            }
        }else{
            if($aadObjectId){
                $type = "EntraSecurityGroup"
            }
        }
        if($entity.LoginName.StartsWith("SharingLinks.")){
            $type = "SharingLink"
        }

        if($entity.LoginName -in @("Anonymous","AllInternalUsers")){
            $aadObjectId = $entity.LoginName
            $type = "SharingLink"
        }

        return [PSCustomObject]@{
            "Title" = $entity.Title
            "AadObjectId"= $aadObjectId
            "LoginName" = $entity.LoginName
            "PrincipalType" = $type
            "Email" = if($entity.Email){$entity.Email}else{$Null}
        }      
    }

    return $Null
}