
function New-GraphQuery {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method,    
        
        [Parameter(Mandatory = $false)]
        [string]$Body,        

        [Parameter(Mandatory = $false)]
        [Switch]$NoPagination,

        [Parameter(Mandatory = $false)]
        [Switch]$ComplexFilter,

        [Parameter(Mandatory = $false)]
        [Switch]$NoRetry,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 5,

        [Parameter(Mandatory = $false)]
        [int]$MaxResults = -1,        

        [Parameter(Mandatory = $false)]
        [String]$resource = $global:octo.graphUrl,

        [Parameter(Mandatory = $false)]
        [Int]$expectedTotalResults = 0,

        [Parameter(Mandatory = $false)]
        [String]$ContentType = 'application/json; charset=utf-8',

        [Parameter(Mandatory = $false)]
        [String[]]$ignoreableErrors,

        [Parameter(Mandatory = $false)]
        [Array]$extraHeaders = @()
    )

    $headers = get-AccessToken -resource $resource -returnHeader

    $headers['Accept-Language'] = "en-US"
    foreach($extraHeader in $extraHeaders){
        $headers[$($extraHeader.Name)] = $extraHeader.Value
    }
    
    if($expectedTotalResults -gt 0){
        Write-Progress -Id 10 -Activity "Querying $resource API" -Status "Retrieving initial batch of $expectedTotalResults expected records" -PercentComplete 0
    }

    if($resource -like "*$($global:octo.sharepointUrl)*"){
        $headers['Accept'] = "application/json;odata=nometadata"
    }    

    if($resource -like "*$($global:octo.outlookUrl)*"){
        $headers['Accept'] = "application/json;odata.metadata=minimal"
        $ContentType = "application/json;odata.metadata=minimal"
    } 

    if ($ComplexFilter) {
        $headers['ConsistencyLevel'] = 'eventual'
        if ($uri -notlike "*`$count*") {
            $uri = $uri.Replace("?", "?`$count=true&")
        }
    }
    $nextURL = $uri

    if ($NoRetry) {
        $MaxAttempts = 1
    }

    $powerBiSkip = 0

    if($Method -in ('POST', 'PATCH')){
        try {
            $attempts = 0
            while ($attempts -lt $MaxAttempts) {
                $attempts ++
                try {
                    [System.GC]::GetTotalMemory($true) | out-null   
                    $Data = (Invoke-RestMethod -Uri $nextURL -Method $Method -Headers $headers -Body $Body -ContentType $ContentType -ErrorAction Stop -Verbose:$False)
                    $attempts = $MaxAttempts
                }catch {
                    if($_.Exception.Message -like "*404 (Not Found)*" -or $_.Exception.Message -like "*Request_ResourceNotFound*" -or $_.Exception.Message -like "*Resource*does not exist*"){
                        Write-LogMessage -level 6 -message "Not retrying: $($_)"
                        $nextUrl = $Null
                        throw $_
                    }                    
                    if($ignoreableErrors){
                        foreach($ignoreableError in $ignoreableErrors){
                            if($_.Exception.Message -like "*$ignoreableError*"){
                                Write-LogMessage -level 6 -message "Ignoring error: $($_)"
                                $nextUrl = $Null
                                throw $_
                            }
                        }
                    }                   
                    if ($attempts -ge $MaxAttempts) { 
                        Throw $_
                    }
                    $delay = 0
                    if ($_.Exception.Response.StatusCode -eq 429){
                        try {
                            $retryAfter = $_.Exception.Response.Headers.GetValues("Retry-After")
                            if ($retryAfter -and $retryAfter.Count -gt 0) {
                                $delay = [int]$retryAfter[0]
                            }
                        }catch {}
                    }
                    if($delay -le 0){
                        $delay = [math]::Pow(5, $attempts)
                    }
                    Start-Sleep -Seconds (1 + $delay)
                }     
            }
        }catch {
            $Message = ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue).error.message
            if ($null -eq $Message) { $Message = $($_.Exception.Message) }
            throw $Message
        }                               
        return $Data
    }else{
        $totalResults = 0
        $ReturnedData = do {
            try {
                $attempts = 0
                while ($attempts -lt $MaxAttempts) {
                    $attempts ++
                    try {
                        [System.GC]::GetTotalMemory($true) | out-null
                        $Data = (Invoke-RestMethod -Uri $nextURL -Method $Method -Headers $headers -ContentType $ContentType -ErrorAction Stop -Verbose:$false)
                        $attempts = $MaxAttempts
                    }
                    catch {
                        if($_.Exception.Message -like "*404 (Not Found)*" -or $_.Exception.Message -like "*Request_ResourceNotFound*" -or $_.Exception.Message -like "*Resource*does not exist*"){
                            Write-LogMessage -level 6 -message "Not retrying: $($_)"
                            $nextUrl = $Null
                            throw $_
                        }                        
                        if($ignoreableErrors){
                            foreach($ignoreableError in $ignoreableErrors){
                                if($_.Exception.Message -like "*$ignoreableError*"){
                                    Write-LogMessage -level 6 -message "Ignoring error: $($_)"
                                    $nextUrl = $Null
                                    throw $_
                                }
                            }
                        }                        
                        if ($attempts -ge $MaxAttempts) { 
                            $nextURL = $null
                            Throw $_
                        }
                        $delay = 0
                        if ($_.Exception.Response.StatusCode -eq 429){
                            try {
                                $retryAfter = $_.Exception.Response.Headers.GetValues("Retry-After")
                                if ($retryAfter -and $retryAfter.Count -gt 0) {
                                    $delay = [int]$retryAfter[0]
                                }
                            }catch {}
                        }
                        if($delay -le 0){
                            $delay = [math]::Pow(5, $attempts)
                        }
                        Start-Sleep -Seconds (1 + $delay)
                    }
                }
                if($resource -like "*$($global:octo.sharepointUrl)*" -and $Data.PSObject.TypeNames -notcontains "System.Management.Automation.PSCustomObject"){
                    $Data = $Data | ConvertFrom-Json -AsHashtable
                }

                if($Data.psobject.properties.name -icontains 'value' -or $Data.Keys -icontains 'value'){
                    $totalResults+=$Data.value.count
                    ($Data.value)
                }else{
                    $totalResults+=$Data.count                
                    ($Data)
                }
                if($expectedTotalResults -gt 0){
                    Try {$percentComplete = [math]::Min(100,($totalResults / $expectedTotalResults * 100))}Catch{$percentComplete = 0}
                    Write-Progress -Id 10 -Activity "Querying $resource API" -Status "Retrieved $totalResults of $expectedTotalResults items" -PercentComplete $percentComplete
                }         
                
                if($NoPagination){
                    $nextURL = $null
                }elseif($Data.'@odata.nextLink'){
                    $nextURL = $Data.'@odata.nextLink'  
                }elseif($Data.'odata.nextLink'){
                    $nextURL = $Data.'odata.nextLink'  
                }elseif($Data.psobject.properties.name -icontains '@odata.count' -or $Data.Keys -icontains '@odata.count'){
                    if($Data.Count -ge 5000){
                        $powerBiSkip += 5000
                        if($nextUrl.Contains("skip=")){
                            $nextUrl = $nextUrl -replace "skip=\d+","skip=$powerBiSkip"
                        }else{
                            $nextUrl = $nextUrl + "&`$skip=$powerBiSkip"
                        }
                    }else{
                        $nextURL = $null
                    }
                }else{
                    $nextURL = $null
                }

                if($MaxResults -ne -1 -and $totalResults -gt $MaxResults){
                    $nextURL = $null
                }
            }
            catch {
                throw $_
            }
        } until ($null -eq $nextURL)
        Write-Progress -Id 10 -Completed -Activity "Querying $resource API"
        if ($ReturnedData -and !$ReturnedData.value -and $ReturnedData.PSObject.Properties["value"]) { return $null }
        [System.GC]::GetTotalMemory($true) | out-null

        return $ReturnedData
    }
}