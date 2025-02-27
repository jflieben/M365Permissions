Function get-M365PermissionsConfig{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -maxThreads: the maximum amount of threads to use for parallel processing, by default 5. Ensure you've read my blog before increasing this.
        -outputFolder: the path to the folder where you want to save permissions. By default it'll create the file in AppData\Roaming\LiebenConsultancy\M365Permissions
        -outputFormat: XLSX or CSV
        -Verbose: if set, verbose output will be shown everywhere (=very chatty)
        -includeCurrentUser: add entries for the user performing the audit (as this user will have all access, it'll clutter the report)
        -defaultTimeoutMinutes: the default timeout in minutes for all parallelized jobs, by default 120 minutes
        -maxJobRetries: the amount of times a job will be retried if it fails, by default 3
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