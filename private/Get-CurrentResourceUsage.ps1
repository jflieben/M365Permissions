function Get-CurrentResourceUsage(){
     <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     
    $ProcessId = $PID
    $Process = Get-Process -Id $ProcessId
    
    $CpuUsage = $Process.CPU
    $MemoryUsage = $Process.WorkingSet64 / 1MB
    $CpuUsage = [math]::Round($CpuUsage)
    $MemoryUsage = [math]::Round($MemoryUsage)
    return "$CpuUsage seconds, $MemoryUsage MB"
}