function Start-ScanJobs{
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

    Write-LogMessage -level 5 -message "Start multithreading $Title $($global:octo.ScanJobs.$($Title).Jobs.Count) jobs $($global:octo.userConfig.maxThreads) at a time using $($global:octo.ScanJobs.$($Title).FunctionToRun)"

    $startTime = Get-Date

    Write-Progress -Id 1 -Activity $Title -Status "Starting initial threads" -PercentComplete 0
    
    [Int]$batchSize = 50
    [Int]$doneUntil = $batchSize
    [Array]$failedJobs = @()
    while($true){
        [Int]$queuedJobs = ($global:octo.ScanJobs.$($Title).Jobs | Where-Object {$_.Status -eq "Queued"}).Count
        [Int]$runningJobs = ($global:octo.ScanJobs.$($Title).Jobs | Where-Object {$_.Status -eq "Running"}).Count
        [Int]$failedJobsCount = ($global:octo.ScanJobs.$($Title).Jobs | Where-Object {$_.Status -eq "Failed"}).Count
        [Int]$totalJobs = $global:octo.ScanJobs.$($Title).Jobs.Count
        [Int]$completedJobs = $totalJobs - $queuedJobs - $runningJobs
        try{$percentComplete = (($completedJobs / $totalJobs) * 100)}catch{$percentComplete = 0}

        $elapsedTime = $(Get-Date) - $startTime
        if ($completedJobs -gt 0) {
            $estimatedTotalTime = $elapsedTime.TotalSeconds / $completedJobs * $totalJobs
            $remainingTime = [TimeSpan]::FromSeconds($estimatedTotalTime - $elapsedTime.TotalSeconds)
            $remainingTimeFormatted = $remainingTime.ToString("hh\:mm\:ss")
        } else {
            $remainingTimeFormatted = "??:??:??"
        }
        
        Write-Progress -Id 1 -Activity $Title -Status "$completedJobs/$totalJobs done. $failedJobsCount failed, $runningJobs active, $queuedJobs queued. $remainingTimeFormatted est time left" -PercentComplete $percentComplete
        
        if($queuedJobs -eq 0 -and $runningJobs -eq 0){
            Write-LogMessage -level 5 -message "All jobs for $Title have finished"
            break
        }

        if($doneUntil -le $completedJobs){
            $doneUntil += $batchSize
            Reset-ReportQueue
        }

        #cycle over all jobs
        for($i = 0; $i -lt $totalJobs; $i++){
            #if job is running, check if it has completed
            if($global:octo.ScanJobs.$($Title).Jobs[$i].Status -eq "Running"){             
                #handle timed out jobs
                if((Get-Date) -gt $global:octo.ScanJobs.$($Title).Jobs[$i].StartTime.AddMinutes($global:octo.userConfig.defaultTimeoutMinutes)){
                    $failedJobs += $global:octo.ScanJobs.$($Title).Jobs[$i].Target
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Failed"
                    Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has been running for more than $($global:octo.userConfig.defaultTimeoutMinutes) minutes, killing it :(" -level 1
                }
                #handle completed jobs
                if($global:octo.ScanJobs.$($Title).Jobs[$i].Handle.IsCompleted -eq $True){
                    try{
                        if($global:octo.ScanJobs.$($Title).Jobs[$i].Thread.HadErrors){
                            #check if the errors were terminating or not
                            $terminatingErrors= @(); $terminatingErrors = @($global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error.Exception | Where-Object {$_ -and $_ -is [System.Management.Automation.RuntimeException]})
                            if($terminatingErrors.Count -gt 0){
                                Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has completed with critical errors :("
                                $global:octo.ScanJobs.$($Title).Jobs[$i].Attempts++
                                if($global:octo.ScanJobs.$($Title).Jobs[$i].Attempts -lt $global:octo.userConfig.maxJobRetries){
                                    Write-LogMessage -message "Retrying $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) after $($global:octo.ScanJobs.$($Title).Jobs[$i].Attempts) failure(s)" -level 2
                                    Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) START---------" -Level 2
                                    if($global:octo.userConfig.LogLevel -in ("Full","Normal","Minimal")){
                                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error | fl *
                                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Warning | fl *
                                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Information | fl *
                                    }
                                    if($global:octo.userConfig.LogLevel -eq "Full"){
                                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Debug | fl *
                                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Verbose | fl *
                                    }
                                    Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) END-----------" -Level 2       
                                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Queued"
                                }else{
                                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Failed"
                                    Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) failed $($global:octo.ScanJobs.$($Title).Jobs[$i].Attempts) times, abandoning Job..." -level 1                               
                                    $failedJobs += $global:octo.ScanJobs.$($Title).Jobs[$i].Target
                                }
                            }else{
                                Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has completed, but had $($global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error.Count) non-retryable errors :|" -level 2
                                $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Succeeded"
                            }
                        }else{
                            Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has completed without any errors :)" -level 4
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Succeeded"
                        }                                                    
                    }catch{
                        Write-LogMessage -message "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has crashed and will be retried" -level 2
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Queued"
                    }
                }

                #show progress bars from the child job
                $jobProgressBars = $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Progress
                if($jobProgressBars){
                    $uniqueIds = $jobProgressBars | Select-Object -ExpandProperty ActivityId -Unique
                    foreach($uniqueId in $uniqueIds){
                        $progressBar = @($jobProgressBars | Where-Object {$_.ActivityId -eq $uniqueId})[-1]
                        if($global:octo.ScanJobs.$($Title).Jobs[$i].Status -ne "Running" -or $progressBar.RecordType -eq "Completed"){
                            Write-Progress -Id $($i+$uniqueId) -Completed
                        }else{
                            Write-Progress -Id $($i+$uniqueId) -Activity $progressBar.Activity -Status $progressBar.StatusDescription -PercentComplete $progressBar.PercentComplete
                        }
                    }
                }                   

                #dispose of threads that have completed
                if($global:octo.ScanJobs.$($Title).Jobs[$i].Status -in ("Succeeded", "Failed")){
                    if($global:octo.ScanJobs.$($Title).Jobs[$i].Status -eq "Failed"){
                        Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) START---------" -Level 2
                    }else{
                        Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) START---------" -Level 4
                    }
                    
                    try{
                        if($global:octo.userConfig.LogLevel -in ("Full","Normal","Minimal")){
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Warning
                        }
                        if($global:octo.userConfig.LogLevel -eq "Full"){
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Information
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Debug
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Verbose                            
                        }
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.EndInvoke($global:octo.ScanJobs.$($Title).Jobs[$i].Handle)
                        if($global:octo.ScanJobs.$($Title).Jobs[$i].Status -eq "Failed"){
                            Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) END-----------" -Level 2
                        }else{
                            Write-LogMessage -message "---------OUTPUT $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) END-----------" -Level 4
                        }

                    }catch{}                         
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Dispose()
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread = $Null
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Handle = $Null
                }                   
            }

            #if job is queued, start it if we have room
            if($global:octo.ScanJobs.$($Title).Jobs[$i].Status -eq "Queued"){
                if($runningJobs -lt $global:octo.userConfig.maxThreads){
                    Write-LogMessage -message "Starting $($global:octo.ScanJobs.$($Title).Jobs[$i].Target)" -Level 4
                    $runningJobs++
                    $thread = [powershell]::Create().AddScript($baseScriptBlock)
                    $Null = $thread.AddParameter('ModulePath', $global:octo.modulePath)
                    $Null = $thread.AddParameter('FunctionName', $global:octo.ScanJobs.$Title.FunctionToRun)
                    $Null = $thread.AddParameter('Arguments', $global:octo.ScanJobs.$($Title).Jobs[$i].FunctionArguments)
                    $Null = $thread.AddParameter('octo', $global:octo)
                    $handle = $thread.BeginInvoke()
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Running"
                    $global:octo.ScanJobs.$($Title).Jobs[$i].StartTime = Get-Date
                    if($global:octo.ScanJobs.$($Title).Jobs[$i].Handle){
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Handle = $Null 
                    }
                    if($global:octo.ScanJobs.$($Title).Jobs[$i].Thread){
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Dispose()
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread = $Null
                    }      
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Handle = $handle
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread = $thread
                }
            }
        }

        Start-Sleep -Milliseconds 500
    }

    if($failedJobs){
        Write-LogMessage -message "The following targets failed: $($failedJobs -join ', '). Try running these individually, if issues persist log an Issue in Github with verbose logs" -Level 1
        if($global:octo.userConfig.LogLevel -ne "Full"){
            Write-LogMessage -message "To run in Verbose mode, use set-M365PermissionsConfig -logLevel Full before starting a scan."  -Level 1
        }else{
            Write-LogMessage -message "Verbose log path: $($global:octo.outputTempFolder)\M365PermissionsVerbose.log"  -Level 1
        }
    }
    Reset-ReportQueue
}        