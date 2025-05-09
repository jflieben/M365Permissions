function Get-CurrentUser {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     

    if($global:octo.userConfig.authMode -eq "Delegated"){
        return New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/me" -NoPagination -Method GET
    }elseif($global:octo.userConfig.authMode -eq "ServicePrincipal"){
        $spnMetaData = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/servicePrincipals(appId='$($global:octo.userConfig.LCClientId)')" -NoPagination -Method GET 
        return @{
            userPrincipalName = $spnMetaData.displayName
        }
    }else{
        if($global:octo.autDetectedClientId){
            $spnMetaData = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/servicePrincipals(appId='$($global:octo.autDetectedClientId)')" -NoPagination -Method GET 
            return @{
                userPrincipalName = $spnMetaData.displayName
            }
        }else{
            return @{
                userPrincipalName = "ManagedIdentity-$($Env:COMPUTERNAME)"
            }
        }

    }

}