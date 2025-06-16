function New-GraphBatchQuery {
    <#
    .SYNOPSIS
        Executes Microsoft Graph API requests in batch mode with built-in retry logic and throttling handling.
    
    .DESCRIPTION
        This function processes multiple Microsoft Graph API requests either in batches or individually.
        It implements retry logic for handling throttling (429) errors and other transient failures.
        The function supports the Graph Batch API for improved performance with large numbers of requests.
        
    .PARAMETER BatchItems
        Array of items to be processed in batches. These could be user objects, groups, or any other entities.
        
    .PARAMETER BatchSize
        Maximum number of items to include in each batch. Default is 20, which is the Graph API limit.
        
    .PARAMETER BatchUrlGenerator
        Script block that generates the URL for each batch item. This script block receives the current item as a parameter.
        Example: { param($item) return "/users/$($item.id)" }
        
    .PARAMETER BatchIdGenerator
        Script block that generates a unique ID for each request within a batch. Default generates "batch_X" where X is the index.
        Example: { param($index) return "user_$index" }
        
    .PARAMETER ProgressId
        ID to use for the PowerShell progress bar. Default is 2.
        
    .PARAMETER BatchActivity
        Text to display in the PowerShell progress bar. Default is "Processing batch requests".
        
    .PARAMETER Uri
        Base URI for the Graph API batch endpoint. Defaults to the global batch URL.
    
    .PARAMETER maxRetries
        Maximum number of retry attempts for each request on failed attempts. Default is 3.
        
    .EXAMPLE
        # Process user owned objects in batches
        # This example retrieves owned objects for all users in batches of 20.
        $allUsers = New-GraphQuery -Uri "$($global:octo.graphUrl)/v1.0/users?`$select=id,userPrincipalName,displayName" -Method GET
        $batchOwnedObjectsSplat = @{
            batchItems = $allUsers
            batchSize = 20
            batchActivity = "Processing user owned objects"
            batchUrlGenerator = {
                param($user)
                return "/users/$($user.id)/ownedObjects?`$select=id,displayName,groupTypes,mailEnabled,securityEnabled,membershipRule&`$top=999"
            }
            batchIdGenerator = {
                param($index)
                return "owned_$index"
            }
            progressId = 2
        }
        $ownedObjectsBatchResults = new-GraphBatchQuery @batchOwnedObjectsSplat
        
        
    .NOTES
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [Array]$BatchItems,

        [Parameter(Mandatory = $false)]
        [int]$BatchSize = 20,

        [Parameter(Mandatory = $true)]
        [scriptblock]$BatchUrlGenerator,

        [Parameter(Mandatory = $false)]
        [scriptblock]$BatchIdGenerator = { param($index) return "batch_$index" },

        [Parameter(Mandatory = $false)]
        [int]$ProgressId = 2,

        [Parameter(Mandatory = $false)]
        [string]$BatchActivity = "Processing batch requests",

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri = $global:octo.graphbatchUrl,

        [Parameter(Mandatory = $false)]
        [int]$maxRetries = 3
    )

    Write-LogMessage -level 4 -message "Processing $($BatchItems.Count) items in batch mode"
    $batchApiUrl = "$($global:octo.graphbatchUrl)"
    $batchResults = @()

    for ($i = 0; $i -lt $BatchItems.Count; $i += $BatchSize) {
        $currentBatchSize = [math]::Min($BatchSize, $BatchItems.Count - $i)
        $currentBatch = $BatchItems[$i..($i + $currentBatchSize - 1)]

        $progressPercent = [math]::Min(100, ($i / $BatchItems.Count) * 100)
        Write-Progress -Id $ProgressId -PercentComplete $progressPercent -Activity $BatchActivity -Status "Processing items $i to $($i + $currentBatchSize - 1) of $($BatchItems.Count)"

        # Create batch requests
        $batchRequests = @()
        foreach ($j in 0..($currentBatch.Count - 1)) {
            $id = & $BatchIdGenerator $j
            $url = & $BatchUrlGenerator $currentBatch[$j]

            $batchRequests += @{
                id     = $id
                method = "GET"
                url    = $url
            }
        }

        $batchBody = @{"requests" = @($batchRequests) } | ConvertTo-Json -Depth 10

        # Execute batch request with retry function
        $batchResponse = New-GraphQuery -Method POST -Uri $batchApiUrl -Body $batchBody

        if ($null -eq $batchResponse) {
            # Create an empty response to maintain indexing
            $emptyResponse = @{
                responses = @(foreach ($req in $batchRequests) {
                        @{ id = $req.id; status = 500; body = $null }
                    })
            }
            $batchResults += $emptyResponse
            continue
        }

        # Process any failed items individually
        $failedItems = @()
        foreach ($response in $batchResponse.responses) {
            if ($response.status -ne 200) {
                $itemIndex = [int]($response.id -replace "^.*?_(\d+)$", '$1')
                if ($itemIndex -lt $currentBatch.Count) {
                    $failedItems += @{
                        item          = $currentBatch[$itemIndex]
                        responseId    = $response.id
                        originalIndex = $batchResponse.responses.IndexOf($response)
                    }
                }
            }
        }

        # Retry failed items individually so we do not run the same call more than once
        if ($failedItems.Count -gt 0) {
            Write-LogMessage -level 3 -message "Retrying $($failedItems.Count) failed items individually"

            # Wait a bit before retrying to avoid immediate throttling
            Start-Sleep -Seconds 2

            foreach ($failedItem in $failedItems) {
                $url = & $BatchUrlGenerator $failedItem.item

                # Ensure URL is absolute
                if ($url.StartsWith("/")) {
                    $url = "$($global:octo.graphUrl)/v1.0$url"
                    Write-LogMessage -level 3 -message "Retrying failed item $($failedItem.responseId) with URL: $url"
                }

                $retryResult = New-GraphQuery -Uri $url -Method GET

                # Handle the retry result properly
                if ($null -ne $retryResult) {
                    # Check if it's our special "resource not found" marker
                    if ($retryResult -is [hashtable] -and $retryResult.ContainsKey('status') -and $retryResult.status -eq 404) {
                        # Update with 404 status but don't crash
                        $batchResponse.responses[$failedItem.originalIndex] = @{
                            id     = $failedItem.responseId
                            status = 404
                            body   = $null
                            error  = $retryResult.error
                        }
                        Write-LogMessage -level 2 -message "Resource not found for item $($failedItem.responseId)"
                    }
                    else {
                        # Normal successful retry
                        $batchResponse.responses[$failedItem.originalIndex] = @{
                            id     = $failedItem.responseId
                            status = 200
                            body   = $retryResult
                        }
                        Write-LogMessage -level 4 -message "Successfully retried item $($failedItem.responseId)"
                    }
                }
            }
        }

        $batchResults += $batchResponse
    }

    Write-Progress -Id $ProgressId -Completed -Activity $BatchActivity

    return $batchResults
}