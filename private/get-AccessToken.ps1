function get-AccessToken{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)]$resource,
        [Switch]$returnHeader
    )   

    if(!$global:octo.LCRefreshToken){
        if($global:octo.authMode -eq "Delegated"){
            get-AuthorizationCode
        }        
    }

    if(!$global:octo.LCCachedTokens.$resource){
        $global:octo.LCCachedTokens.$resource = @{
            "validFrom" = Get-Date
            "accessToken" = $Null
        }
    }

    if(!$global:octo.LCCachedTokens.$($resource).accessToken -or $global:octo.LCCachedTokens.$($resource).validFrom -lt (Get-Date).AddMinutes(-25)){
        Write-Verbose "Token cache miss, refreshing $($global:octo.authMode) V1 token for $resource..."
        if($global:octo.authMode -eq "ServicePrincipal"){
            $assertion = Get-Assertion
            $response = (Invoke-RestMethod "https://login.microsoftonline.com/$($global:octo.LCTenantId)/oauth2/token" -Method POST -Body "resource=$([System.Web.HttpUtility]::UrlEncode($resource))&grant_type=client_credentials&client_id=$([System.Web.HttpUtility]::UrlEncode($global:octo.LCClientId))&client_assertion=$([System.Web.HttpUtility]::UrlEncode($assertion))&client_assertion_type=$([System.Web.HttpUtility]::UrlEncode('urn:ietf:params:oauth:client-assertion-type:jwt-bearer'))" -ErrorAction Stop -Verbose:$false)
        }elseif($global:octo.authMode -eq "ManagedIdentity"){   
            $endpoint = "$($env:IDENTITY_ENDPOINT)?resource=$($resource)"
            $response = Invoke-RestMethod -Uri $endpoint -Headers @{"X-IDENTITY-HEADER"=$env:IDENTITY_HEADER;Metadata="true"} -Method GET
        }else{
            $response = (Invoke-RestMethod "https://login.microsoftonline.com/common/oauth2/token" -Method POST -Body "resource=$([System.Web.HttpUtility]::UrlEncode($resource))&grant_type=refresh_token&refresh_token=$($global:octo.LCRefreshToken)&client_id=$($global:octo.LCClientId)&scope=openid" -ErrorAction Stop -Verbose:$false)
        }
        
        if($response.access_token){
            if($response.refresh_token){ 
                Write-Verbose "Refresh token received, updating cache..."
                $global:octo.LCRefreshToken = $response.refresh_token 
            }                
            $global:octo.LCCachedTokens.$($resource).accessToken = $response.access_token
            $global:octo.LCCachedTokens.$($resource).validFrom = Get-Date
            if($global:octo.authMode -ne "Delegated"){
                #see if we can get a client ID from the token
                try{
                    $global:octo.autDetectedClientId = ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($response.access_token.Split('.')[1])) | convertfrom-json).appid
                }catch{$Null}
            }
        }else{
            Write-Error "Failed to retrieve access and/or refresh token! Please reload PowerShell / this module to refresh or google this error: $_" -ErrorAction Stop
        }
    }else{
        Write-Verbose "Token cache hit, using cached token :)"
    }

    if($returnHeader){
        return @{
            Authorization = "Bearer $($global:octo.LCCachedTokens.$($resource).accessToken)"
        }
    }else{
        return $global:octo.LCCachedTokens.$($resource).accessToken
    }
}
