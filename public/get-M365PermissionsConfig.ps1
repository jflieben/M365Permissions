Function get-M365PermissionsConfig{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param()

    $configLocation = Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy\M365Permissions.conf"
    if(!(Test-Path $configLocation)){
        $preferredConfig = @{}
    }else{
        $preferredConfig = Get-Content -Path $configLocation | ConvertFrom-Json -AsHashtable
    }

    $output = @()

    foreach($key in $preferredConfig.Keys){
        $output += [PSCustomObject]@{
            "Option" = $key
            "Value" = $preferredConfig.$key
            "IsDefault" = $false
        }
    }


    foreach($key in $global:octo.userConfig.Keys){
        if($Null -eq $preferredConfig.$key){
            $output += [PSCustomObject]@{
                "Option" = $key
                "Value" = $global:octo.userConfig[$key]
                "IsDefault" = $true
            }
        }
    }
    return $output
}