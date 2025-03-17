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
                "LoginName" = $entity.LoginName
                "PrincipalType" = "ANYONE"
                "Email" = "N/A"
            }      
        }
        if($entity.LoginName.Split("|")[0] -eq "c:0-.f"){
            Write-LogMessage -level 5 -message "Found $($entity.Title) special group"
            return [PSCustomObject]@{
                "Title" = $entity.Title
                "LoginName" = $entity.LoginName
                "PrincipalType" = "ORG-WIDE"
                "Email" = "N/A"
            }      
        }
        if($entity.LoginName.Split("|")[0] -eq "c:0t.c"){
            Write-LogMessage -level 5 -message "Found $($entity.Title) special group"
            return [PSCustomObject]@{
                "Title" = $entity.Title
                "LoginName" = $entity.LoginName
                "PrincipalType" = "Role"
                "Email" = "N/A"
            }      
        }
    }

    if($alwaysReturn){
        $type = $entity.PrincipalType
        if($type.GetType().BaseType.Name -eq "Enum" -and $type.value__){
            $type = $type.value__
        }
        if([int]::TryParse($type, [ref]$null)){
            switch($type){
                0 { $type = "Unknown" }
                1 { $type = "User" }
                2 { $type = "DistributionList" }
                4 { $type = "SecurityGroup" }
                8 { $type = "SharePointGroup" }
                default { $type = "Unrecognized principle type: $type"}
            }
        }
        if($type -eq "User"){
            if($entity.Title -eq "External User" -or $entity.LoginName -like "*#EXT#*"){
                $type = "Guest User"
            }else{
                $type = "Internal User"
            }
        }
        return [PSCustomObject]@{
            "Title" = $entity.Title
            "LoginName" = $entity.LoginName
            "PrincipalType" = $type
            "Email" = if($entity.Email){$entity.Email}else{"N/A"}
        }      
    }

    return $Null
}