function Start-ScanJobs {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>
       
    Param(        
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Title
    )
    
    # Helper function to create a deep copy of hashtables
    function Copy-Hashtable {
        param([hashtable]$Source)
        $copy = @{}
        foreach ($key in $Source.Keys) {
            # Skip ScanJobs
            if ($key -eq "ScanJobs") { continue }
            
            $value = $Source[$key]
            if ($value -is [hashtable]) {
                $copy[$key] = Copy-Hashtable -Source $value
            }
            elseif ($value -is [System.Collections.ICollection] -and $value -isnot [string]) {
                # Handle arrays/collections, but skip complex objects
                if ($value.Count -eq 0 -or $value[0] -is [string] -or $value[0] -is [int]) {
                    $copy[$key] = $value.Clone()
                }
                else {
                    # For complex object collections, just reference the original
                    # This is safe as long as the jobs don't modify these
                    $copy[$key] = $value
                }
            }
            else {
                # Simple values and objects that can't be cloned
                $copy[$key] = $value
            }
        }
        
        # Add an empty ScanJobs hashtable to prevent errors
        $copy["ScanJobs"] = @{}
        
        return $copy
    }

    $originalJobCount = $global:octo.ScanJobs.$($Title).Jobs.Count
    Write-LogMessage -level 4 -message "Locking job processing to original $originalJobCount jobs"
    
    # Store initial jobs in a separate array to ensure we only track these
    $originalJobs = $global:octo.ScanJobs.$($Title).Jobs[0..($originalJobCount-1)]
    
    $baseScriptBlock = {
        param (
            [string]$ModulePath,
            [string]$FunctionName,
            [hashtable]$Arguments,
            [hashtable]$octo
        )
        $global:octo = $octo
        Import-Module -Name $ModulePath -Force
        & $FunctionName @Arguments
    }

    Write-LogMessage -level 5 -message "Start multithreading $Title $originalJobCount jobs $($global:octo.userConfig.maxThreads) at a time using $($global:octo.ScanJobs.$($Title).FunctionToRun)"

    $startTime = Get-Date

    Write-Progress -Id 1 -Activity $Title -Status "Starting initial threads" -PercentComplete 0
    
    [Int]$batchSize = 50
    [Int]$doneUntil = $batchSize
    [Array]$failedJobs = @()
    while ($true) {
        $previousJobCount = $global:octo.ScanJobs.$($Title).Jobs.Count
        
        # Only count status of original jobs
        [Int]$queuedJobs = ($originalJobs | Where-Object { $_.Status -eq "Queued" }).Count
        [Int]$runningJobs = ($originalJobs | Where-Object { $_.Status -eq "Running" }).Count
        [Int]$failedJobsCount = ($originalJobs | Where-Object { $_.Status -eq "Failed" }).Count
        [Int]$totalJobs = $originalJobCount
        [Int]$completedJobs = $totalJobs - $queuedJobs - $runningJobs
        try { $percentComplete = (($completedJobs / $totalJobs) * 100) }catch { $percentComplete = 0 }

        <#
        Might need to revisit this logic as it does not correctly estimate on the batch requests.
        It just keeps going up in estimated time left, which is not very helpful.
        #>
        $elapsedTime = $(Get-Date) - $startTime
        if ($completedJobs -gt 0) {
            $estimatedTotalTime = $elapsedTime.TotalSeconds / $completedJobs * $totalJobs
            $remainingTime = [TimeSpan]::FromSeconds($estimatedTotalTime - $elapsedTime.TotalSeconds)
            $remainingTimeFormatted = $remainingTime.ToString("hh\:mm\:ss")
        }
        else {
            $remainingTimeFormatted = "??:??:??"
        }
        
        Write-Progress -Id 1 -Activity $Title -Status "$completedJobs/$totalJobs done. $failedJobsCount failed, $runningJobs active, $queuedJobs queued. $remainingTimeFormatted est time left" -PercentComplete $percentComplete
        
        if ($queuedJobs -eq 0 -and $runningJobs -eq 0) {
            Write-LogMessage -level 5 -message "All original jobs for $Title have finished"
            break
        }

        if ($doneUntil -le $completedJobs) {
            $doneUntil += $batchSize
            Reset-ReportQueue
        }

        #cycle over all original jobs only
        # Had issues where new jobs were added while processing, which caused the loop to run indefinitely
        for ($i = 0; $i -lt $originalJobCount; $i++) {
            # Only process jobs up to the original count
            if ($i -ge $global:octo.ScanJobs.$($Title).Jobs.Count) {
                Write-LogMessage -level 2 -message "Job index $i exceeds total job count $($global:octo.ScanJobs.$($Title).Jobs.Count). This shouldn't happen!"
                break
            }
            
            #if job is running, check if it has completed
            if ($global:octo.ScanJobs.$($Title).Jobs[$i].Status -eq "Running") {             
                #handle timed out jobs
                if ((Get-Date) -gt $global:octo.ScanJobs.$($Title).Jobs[$i].StartTime.AddMinutes($global:octo.userConfig.defaultTimeoutMinutes)) {
                    $failedJobs += $global:octo.ScanJobs.$($Title).Jobs[$i].Target
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Failed"
                    Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has been running for more than $($global:octo.userConfig.defaultTimeoutMinutes) minutes, killing it :(" -level 1
                }
                
                #handle completed jobs
                if ($global:octo.ScanJobs.$($Title).Jobs[$i].Handle -and $global:octo.ScanJobs.$($Title).Jobs[$i].Handle.IsCompleted -eq $True) {
                    try {
                        if ($global:octo.ScanJobs.$($Title).Jobs[$i].Thread.HadErrors) {
                            #check if the errors were terminating or not
                            $terminatingErrors = @(); $terminatingErrors = @($global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error.Exception | Where-Object { $_ -and $_ -is [System.Management.Automation.RuntimeException] })
                            if ($terminatingErrors.Count -gt 0) {
                                Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has completed with critical errors :("
                                $global:octo.ScanJobs.$($Title).Jobs[$i].Attempts++
                                if ($global:octo.ScanJobs.$($Title).Jobs[$i].Attempts -lt $global:octo.userConfig.maxJobRetries) {
                                    Write-LogMessage -message "Retrying $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) after $($global:octo.ScanJobs.$($Title).Jobs[$i].Attempts) failure(s)" -level 2
                                    Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) START---------" -Level 2
                                    if ($global:octo.userConfig.LogLevel -in ("Full", "Normal", "Minimal")) {
                                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error | fl *
                                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Warning | fl *
                                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Information | fl *
                                    }
                                    if ($global:octo.userConfig.LogLevel -eq "Full") {
                                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Debug | fl *
                                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Verbose | fl *
                                    }
                                    Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) END-----------" -Level 2       
                                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Queued"
                                }
                                else {
                                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Failed"
                                    Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) failed $($global:octo.ScanJobs.$($Title).Jobs[$i].Attempts) times, abandoning Job..." -level 1                               
                                    $failedJobs += $global:octo.ScanJobs.$($Title).Jobs[$i].Target
                                }
                            }
                            else {
                                Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has completed, but had $($global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error.Count) non-retryable errors :|" -level 2
                                $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Succeeded"
                            }
                        }
                        else {
                            Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has completed without any errors :)" -level 4
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Succeeded"
                        }                                                    
                    }
                    catch {
                        Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has crashed and will be retried" -level 2
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Queued"
                    }
                }

                #show progress bars from the child job
                $jobProgressBars = $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Progress
                if ($jobProgressBars) {
                    $uniqueIds = $jobProgressBars | Select-Object -ExpandProperty ActivityId -Unique
                    foreach ($uniqueId in $uniqueIds) {
                        $progressBar = @($jobProgressBars | Where-Object { $_.ActivityId -eq $uniqueId })[-1]
                        if ($global:octo.ScanJobs.$($Title).Jobs[$i].Status -ne "Running" -or $progressBar.RecordType -eq "Completed") {
                            Write-Progress -Id $($i + $uniqueId) -Completed
                        }
                        else {
                            Write-Progress -Id $($i + $uniqueId) -Activity $progressBar.Activity -Status $progressBar.StatusDescription -PercentComplete $progressBar.PercentComplete
                        }
                    }
                }                   

                #dispose of threads that have completed
                if ($global:octo.ScanJobs.$($Title).Jobs[$i].Status -in ("Succeeded", "Failed")) {
                    if ($global:octo.ScanJobs.$($Title).Jobs[$i].Status -eq "Failed") {
                        Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) START---------" -Level 2
                    }
                    else {
                        Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) START---------" -Level 4
                    }
                    
                    try {
                        if ($global:octo.userConfig.LogLevel -in ("Full", "Normal", "Minimal")) {
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Warning
                        }
                        if ($global:octo.userConfig.LogLevel -eq "Full") {
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Information
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Debug
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Verbose                            
                        }

                        if ($global:octo.ScanJobs.$($Title).Jobs[$i].Status -eq "Failed") {
                            Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) END-----------" -Level 2
                        }
                        else {
                            Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) END-----------" -Level 4
                        }
                    }
                    catch {}                         
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Dispose()
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread = $Null
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Handle = $Null
                }                   
            }

            #if job is queued, start it if we have room
            if ($global:octo.ScanJobs.$($Title).Jobs[$i].Status -eq "Queued") {
                if ($runningJobs -lt $global:octo.userConfig.maxThreads) {
                    Write-LogMessage -message "Starting $($global:octo.ScanJobs.$($Title).Jobs[$i].Target)" -Level 4
                    $runningJobs++
                    
                    # Create a clean copy of octo for this job
                    $jobOcto = Copy-Hashtable -Source $global:octo
                    
                    $thread = [powershell]::Create().AddScript($baseScriptBlock)
                    $Null = $thread.AddParameter('ModulePath', $global:octo.modulePath)
                    $Null = $thread.AddParameter('FunctionName', $global:octo.ScanJobs.$Title.FunctionToRun)
                    $Null = $thread.AddParameter('Arguments', $global:octo.ScanJobs.$($Title).Jobs[$i].FunctionArguments)
                    # Pass the clean copy instead of the original
                    $Null = $thread.AddParameter('octo', $jobOcto)
                    
                    $handle = $thread.BeginInvoke()
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Running"
                    $global:octo.ScanJobs.$($Title).Jobs[$i].StartTime = Get-Date
                    if ($global:octo.ScanJobs.$($Title).Jobs[$i].Handle) {
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Handle = $Null 
                    }
                    if ($global:octo.ScanJobs.$($Title).Jobs[$i].Thread) {
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Dispose()
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread = $Null
                    }      
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Handle = $handle
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread = $thread
                }
            }
        }

        Start-Sleep -Milliseconds 500
        
        # Monitor job count
        $currentJobCount = $global:octo.ScanJobs.$($Title).Jobs.Count
        if ($currentJobCount -gt $previousJobCount) {
            # This was to monitor when/if identical jobs were added while processing
            Write-LogMessage -level 2 -message "Job count increased from $previousJobCount to $currentJobCount (ignoring new jobs, only processing original $originalJobCount)"
            $newJobs = $global:octo.ScanJobs.$($Title).Jobs | Select-Object -Last ($currentJobCount - $previousJobCount)
            foreach ($job in $newJobs) {
                Write-LogMessage -level 2 -message "New job added but not processed: $($job.Target)"
            }
        }
    }

    if ($failedJobs) {
        Write-LogMessage -message "The following targets failed: $($failedJobs -join ', '). Try running these individually, if issues persist log an Issue in Github with verbose logs" -Level 1
        if ($global:octo.userConfig.LogLevel -ne "Full") {
            Write-LogMessage -message "To run in Verbose mode, use set-M365PermissionsConfig -logLevel Full before starting a scan."  -Level 1
        }
        else {
            Write-LogMessage -message "Verbose log path: $($global:octo.outputTempFolder)\M365PermissionsVerbose.log"  -Level 1
        }
    }
    Reset-ReportQueue
}