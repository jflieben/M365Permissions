
function New-RetryCommand {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [hashtable]$Arguments,

        [Parameter(Mandatory = $false)]
        [int]$MaxNumberOfRetries = 10,

        [Parameter(Mandatory = $false)]
        [int]$RetryDelayInSeconds = 30,

        [Parameter(Mandatory = $false)]
        [String[]]$ignoreableErrors
    )

    $RetryCommand = $true
    $RetryCount = 0
    $RetryMultiplier = 1

    Write-LogMessage -level 6 -message "$Command called with arguments: $($Arguments.Keys)"

    while ($RetryCommand) {
        try {
            & $Command @Arguments
            $RetryCommand = $false
            Write-LogMessage -level 6 -message "$Command succeeded at attempt $RetryCount"
        }catch {
            if ($RetryCount -le $MaxNumberOfRetries) {
                if($ignoreableErrors){
                    foreach($ignoreableError in $ignoreableErrors){
                        if($_ -like "*$ignoreableError*"){
                            Write-LogMessage -level 6 -message "Ignoring error: $($_)"
                            throw $_
                        }
                    }
                }
                Write-LogMessage -level 5 -message "$Command failed, retrying in $($RetryDelayInSeconds * $RetryMultiplier) seconds. Reason: $_"
                Start-Sleep -Seconds ($RetryDelayInSeconds * $RetryMultiplier)
                $RetryMultiplier *= 1.2
                $RetryCount++
            }else {
                Write-LogMessage -level 5 -message "$Command failed permanently after $RetryCount attempts"
                throw $_
            }
        }
    }
}