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
        [Array]$extraHeaders = @(),

        [Parameter(Mandatory = $false)]
        [Array]$BatchItems,
        
        [Parameter(Mandatory = $false)]
        [int]$BatchSize = 20,
        
        [Parameter(Mandatory = $false)]
        [scriptblock]$BatchUrlGenerator,
        
        [Parameter(Mandatory = $false)]
        [scriptblock]$BatchIdGenerator = { param($index) return "batch_$index" },
        
        [Parameter(Mandatory = $false)]
        [int]$ProgressId = 2,
        
        [Parameter(Mandatory = $false)]
        [string]$BatchActivity = "Processing batch requests",
        
        [Parameter(Mandatory = $false)]
        [switch]$UseBatchApi
    )

    if ($BatchItems -and $BatchItems.Count -gt 0 -and $BatchUrlGenerator) {
        Write-LogMessage -level 4 -message "Processing $($BatchItems.Count) items in batch mode"
        
        $batchResults = @()
        
        # Process items in batches
        for ($i = 0; $i -lt $BatchItems.Count; $i += $BatchSize) {
            $currentBatchSize = [math]::Min($BatchSize, $BatchItems.Count - $i)
            $currentBatch = $BatchItems[$i..($i + $currentBatchSize - 1)]
            
            # Show progress
            $progressPercent = [math]::Min(100, ($i / $BatchItems.Count) * 100)
            Write-Progress -Id $ProgressId -PercentComplete $progressPercent -Activity $BatchActivity -Status "Processing items $i to $($i + $currentBatchSize - 1) of $($BatchItems.Count)"
            
            if ($UseBatchApi) {
                # Create batch requests
                $batchRequests = @()
                foreach ($j in 0..($currentBatch.Count - 1)) {
                    $id = & $BatchIdGenerator $j
                    $url = & $BatchUrlGenerator $currentBatch[$j]
                    
                    $batchRequests += @{
                        id = $id
                        method = "GET"  # Default to GET
                        url = $url
                    }
                }
                
                # Initial batch request
                $batchApiUrl = "$($global:octo.graphbatchUrl)"
                $batchBody = @{"requests" = @($batchRequests) } | ConvertTo-Json -Depth 10
                
                $maxBatchRetries = 3
                $batchRetryCount = 0
                $batchSuccess = $false
                
                # Retry logic for the whole batch if needed (e.g., the entire batch request is throttled)
                while (-not $batchSuccess -and $batchRetryCount -le $maxBatchRetries) {
                    try {
                        if ($batchRetryCount -gt 0) {
                            Write-LogMessage -level 3 -message "Retrying entire batch (attempt $batchRetryCount of $maxBatchRetries)"
                        }
                        
                        $batchResponse = New-GraphQuery -Method POST -Uri $batchApiUrl -Body $batchBody -NoRetry -ErrorVariable batchError
                        $batchSuccess = $true
                    }
                    catch {
                        $batchRetryCount++
                        
                        # Check if this was a throttling error (429)
                        if ($_.Exception.Response.StatusCode -eq 429) {
                            # Get Retry-After header if available
                            $retryAfterSeconds = 0
                            try {
                                $retryAfter = $_.Exception.Response.Headers.GetValues("Retry-After")
                                if ($retryAfter -and $retryAfter.Count -gt 0) {
                                    $retryAfterSeconds = [int]$retryAfter[0]
                                    Write-LogMessage -level 3 -message "Batch throttled. Waiting for $retryAfterSeconds seconds as specified by Retry-After header"
                                }
                            }
                            catch {
                                # No Retry-After header, use exponential backoff
                                $retryAfterSeconds = [math]::Pow(2, $batchRetryCount)
                                Write-LogMessage -level 3 -message "Batch throttled. No Retry-After header. Using exponential backoff: $retryAfterSeconds seconds"
                            }
                            
                            # Wait before retrying
                            Start-Sleep -Seconds $retryAfterSeconds
                        }
                        elseif ($batchRetryCount -ge $maxBatchRetries) {
                            Write-LogMessage -level 2 -message "Batch request failed after $maxBatchRetries attempts: $_"
                            throw $_  # Re-throw the error after max retries
                        }
                        else {
                            # For non-throttling errors, use standard exponential backoff
                            $backoffSeconds = [math]::Pow(2, $batchRetryCount)
                            Write-LogMessage -level 3 -message "Batch error (non-throttling). Retrying in $backoffSeconds seconds: $_"
                            Start-Sleep -Seconds $backoffSeconds
                        }
                    }
                }
                
                # Track items that need retrying (status 429 or other failures)
                $retryRequired = @()
                $retryMapping = @{}
                $retryHeaderValues = @{}
                
                # Check for failed requests
                foreach ($response in $batchResponse.responses) {
                    if ($response.status -eq 429) {
                        # Throttled
                        $itemIndex = [int]($response.id -replace "^.*?_(\d+)$", '$1')
                        $retryRequired += $currentBatch[$itemIndex]
                        $retryMapping[$response.id] = $response
                        
                        # Extract Retry-After header if available
                        $retryAfter = $null
                        if ($response.headers -and $response.headers.'Retry-After') {
                            $retryAfter = [int]$response.headers.'Retry-After'
                            $retryHeaderValues[$response.id] = $retryAfter
                            Write-LogMessage -level 3 -message "Will retry throttled item $($response.id) after $retryAfter seconds"
                        }
                        else {
                            Write-LogMessage -level 3 -message "Will retry throttled item $($response.id) using exponential backoff"
                        }
                    }
                    elseif ($response.status -ne 200) {
                        # Other error status code
                        $itemIndex = [int]($response.id -replace "^.*?_(\d+)$", '$1')
                        $retryRequired += $currentBatch[$itemIndex]
                        $retryMapping[$response.id] = $response
                        Write-LogMessage -level 3 -message "Will retry failed item $($response.id) (status: $($response.status))"
                    }
                }
                
                # Find the longest Retry-After value to use as a base delay
                $baseRetryDelay = 0
                foreach ($delay in $retryHeaderValues.Values) {
                    if ($delay -gt $baseRetryDelay) {
                        $baseRetryDelay = $delay
                    }
                }
                
                # Retry logic for failed/throttled items
                $retryAttempt = 1
                $maxItemRetries = 3
                
                while ($retryRequired.Count -gt 0 -and $retryAttempt -le $maxItemRetries) {
                    
                    if ($baseRetryDelay -gt 0) {
                        Write-LogMessage -level 3 -message "Waiting $baseRetryDelay seconds before retry attempt $retryAttempt (as specified by Retry-After)"
                        Start-Sleep -Seconds $baseRetryDelay
                    }
                    else {
                        $backoffDelay = [math]::Pow(2, $retryAttempt)
                        Write-LogMessage -level 3 -message "Waiting $backoffDelay seconds before retry attempt $retryAttempt (exponential backoff)"
                        Start-Sleep -Seconds $backoffDelay
                    }
                    
                    Write-LogMessage -level 3 -message "Retry attempt $retryAttempt for $($retryRequired.Count) items"
                    
                    # Create retry batch requests
                    $retryBatchRequests = @()
                    $retryItemsMap = @{}
                    
                    foreach ($j in 0..($retryRequired.Count - 1)) {
                        $id = "retry_${retryAttempt}_$j"
                        $url = & $BatchUrlGenerator $retryRequired[$j]
                        
                        $retryBatchRequests += @{
                            id = $id
                            method = "GET"
                            url = $url
                        }
                        $retryItemsMap[$id] = $j
                    }
                    
                    # Skip retry if no items to retry
                    if ($retryBatchRequests.Count -eq 0) {
                        break
                    }
                    
                    # Execute retry batch with throttling awareness
                    $retryBody = @{"requests" = @($retryBatchRequests) } | ConvertTo-Json -Depth 10
                    $retrySuccess = $false
                    $retryBatchAttempt = 0
                    
                    while (-not $retrySuccess -and $retryBatchAttempt -le $maxBatchRetries) {
                        try {
                            $retryResponse = New-GraphQuery -Method POST -Uri $batchApiUrl -Body $retryBody -NoRetry
                            $retrySuccess = $true
                        }
                        catch {
                            $retryBatchAttempt++
                            
                            # Check if this was a throttling error (429)
                            if ($_.Exception.Response.StatusCode -eq 429) {
                                # Get Retry-After header if available
                                $retryAfterSeconds = 0
                                try {
                                    $retryAfter = $_.Exception.Response.Headers.GetValues("Retry-After")
                                    if ($retryAfter -and $retryAfter.Count -gt 0) {
                                        $retryAfterSeconds = [int]$retryAfter[0]
                                        Write-LogMessage -level 3 -message "Retry batch throttled. Waiting for $retryAfterSeconds seconds as specified by Retry-After header"
                                    }
                                }
                                catch {
                                    # No Retry-After header, use exponential backoff
                                    $retryAfterSeconds = [math]::Pow(2, $retryBatchAttempt + $retryAttempt)
                                    Write-LogMessage -level 3 -message "Retry batch throttled. No Retry-After header. Using exponential backoff: $retryAfterSeconds seconds"
                                }
                                
                                # Wait before retrying
                                Start-Sleep -Seconds $retryAfterSeconds
                            }
                            elseif ($retryBatchAttempt -ge $maxBatchRetries) {
                                Write-LogMessage -level 2 -message "Retry batch failed after $maxBatchRetries attempts: $_"
                                break  # Move to next retry attempt
                            }
                            else {
                                # For non-throttling errors, use standard exponential backoff
                                $backoffSeconds = [math]::Pow(2, $retryBatchAttempt + $retryAttempt)
                                Write-LogMessage -level 3 -message "Retry batch error (non-throttling). Retrying in $backoffSeconds seconds: $_"
                                Start-Sleep -Seconds $backoffSeconds
                            }
                        }
                    }
                    
                    if (-not $retrySuccess) {
                        Write-LogMessage -level 2 -message "Failed to process retry batch on attempt $retryAttempt"
                        $retryAttempt++
                        continue  # Try next retry attempt
                    }
                    
                    # Process retry results
                    $stillFailedItems = @()
                    $longestRetryAfter = 0
                    
                    foreach ($response in $retryResponse.responses) {
                        $retryIndex = $retryItemsMap[$response.id]
                        $originalItem = $retryRequired[$retryIndex]
                        
                        if ($response.status -eq 200) {
                            # Find the original id this retry corresponds to
                            $originalId = $null
                            foreach ($key in $retryMapping.Keys) {
                                $keyIndex = [int]($key -replace "^.*?_(\d+)$", '$1')
                                if ($keyIndex -lt $currentBatch.Count -and $originalItem -eq $currentBatch[$keyIndex]) {
                                    $originalId = $key
                                    break
                                }
                            }
                            
                            if ($originalId) {
                                # Replace the failed response with successful one
                                $successIndex = $batchResponse.responses.IndexOf($retryMapping[$originalId])
                                if ($successIndex -ge 0) {
                                    $batchResponse.responses[$successIndex] = $response
                                    $batchResponse.responses[$successIndex].id = $originalId
                                    Write-LogMessage -level 4 -message "Successfully retried item $originalId on attempt $retryAttempt"
                                }
                            }
                        } 
                        else {
                            # Check if it's a throttling response
                            if ($response.status -eq 429) {
                                # Extract Retry-After if available
                                if ($response.headers -and $response.headers.'Retry-After') {
                                    $retryAfter = [int]$response.headers.'Retry-After'
                                    if ($retryAfter -gt $longestRetryAfter) {
                                        $longestRetryAfter = $retryAfter
                                    }
                                }
                            }
                            
                            # Still failed, might need another retry
                            $stillFailedItems += $originalItem
                        }
                    }
                    
                    # Update for next retry
                    $retryRequired = $stillFailedItems
                    $retryAttempt++
                    $baseRetryDelay = $longestRetryAfter
                }
                
                # Log any items that failed all retries
                foreach ($failedItem in $retryRequired) {
                    Write-LogMessage -level 2 -message "Item failed after all $maxItemRetries retry attempts: $failedItem"
                }
                
                # Add results to collection
                $batchResults += $batchResponse
            }
            # Otherwise process items individually
            else {
                $batchResult = @{
                    responses = @()
                }
                
                foreach ($j in 0..($currentBatch.Count - 1)) {
                    $id = & $BatchIdGenerator $j
                    $url = & $BatchUrlGenerator $currentBatch[$j]
                    
                    # Apply retry logic for individual items with throttling awareness
                    $retryAttempt = 0
                    $maxRetries = 3
                    $success = $false
                    
                    while ($retryAttempt -le $maxRetries -and -not $success) {
                        try {
                            if ($retryAttempt -gt 0) {
                                Write-LogMessage -level 3 -message "Retry attempt $retryAttempt for item $id"
                            }
                            
                            $result = New-GraphQuery -Method GET -Uri $url -ErrorVariable apiError
                            $batchResult.responses += @{
                                id = $id
                                status = 200
                                body = $result
                            }
                            $success = $true
                        }
                        catch {
                            $retryAttempt++
                            
                            # Check if this is a throttling error
                            if ($_.Exception.Response.StatusCode -eq 429) {
                                # Get Retry-After header if available
                                $retryAfterSeconds = 0
                                try {
                                    $retryAfter = $_.Exception.Response.Headers.GetValues("Retry-After")
                                    if ($retryAfter -and $retryAfter.Count -gt 0) {
                                        $retryAfterSeconds = [int]$retryAfter[0]
                                        Write-LogMessage -level 3 -message "Item $id throttled. Waiting for $retryAfterSeconds seconds as specified by Retry-After header"
                                    }
                                }
                                catch {
                                    # No Retry-After header, use exponential backoff
                                    $retryAfterSeconds = [math]::Pow(2, $retryAttempt)
                                    Write-LogMessage -level 3 -message "Item $id throttled. No Retry-After header. Using exponential backoff: $retryAfterSeconds seconds"
                                }
                                
                                # Wait before retrying
                                Start-Sleep -Seconds $retryAfterSeconds
                            }
                            elseif ($retryAttempt -gt $maxRetries) {
                                Write-LogMessage -level 2 -message "Failed to process item $id after $maxRetries attempts: $_"
                                $batchResult.responses += @{
                                    id = $id
                                    status = 404
                                    body = $null
                                }
                            }
                            else {
                                # For non-throttling errors, use standard exponential backoff
                                $backoffSeconds = [math]::Pow(2, $retryAttempt)
                                Write-LogMessage -level 3 -message "Error processing item $id. Retrying in $backoffSeconds seconds: $_"
                                Start-Sleep -Seconds $backoffSeconds
                            }
                        }
                    }
                }
                
                $batchResults += $batchResult
            }
        }
        
        # Complete progress bar
        Write-Progress -Id $ProgressId -Completed -Activity $BatchActivity
        
        # Return results
        return $batchResults
    }
    
    # Original function logic starts here
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
                }
                catch {
                    if($_.Exception.Message -like "*404 (Not Found)*"){
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
                    Start-Sleep -Seconds (1 + (3 * $attempts))
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
                        if($_.Exception.Message -like "*404 (Not Found)*"){
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
                        Start-Sleep -Seconds (1 + (3 * $attempts))
                    }
                }
                if($resource -like "*$($global:octo.sharepointUrl)*" -and $Data.PSObject.TypeNames -notcontains "System.Management.Automation.PSCustomObject"){
                    $Data = $Data | ConvertFrom-Json -AsHashtable
                }

                if($NoPagination){
                    $totalResults+=$Data.count                
                    ($Data)
                }elseif($Data.psobject.properties.name -icontains 'value' -or $Data.Keys -icontains 'value'){
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