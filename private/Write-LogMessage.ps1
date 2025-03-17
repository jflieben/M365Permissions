function Write-LogMessage {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        level 0 = Critical
        level 1 = Error
        level 2 = Warning
        level 3 = Guidance
        level 4 = Informational
        level 5 = Verbose
        level 6 = Debug
    #>        

    Param(
        [Parameter(Mandatory=$true)]$message,
        [Parameter(Mandatory=$false)][Int]$level = 3
    )

    switch($global:octo.userConfig.LogLevel){
        "Full" {} #show everything
        "Normal"  {if($level -gt 4){$level = 7}} #show up to informational
        "Minimal" {if($level -gt 3){$level = 7}} #show up to guidance (not much technical data, only if errors occur)
        "None" {if($level -gt 0){$level = 7}} #only show critical errors, nothing else
        default {$level = 7}
    }

    switch($level){
        0 { Throw $message }
        1 { Write-Error $message -ErrorAction Continue }
        2 { Write-Warning "$((Get-Date).ToString()) $message" }
        3 { Write-Output "$((Get-Date).ToString()) $message" }
        4 { Write-Information "$((Get-Date).ToString()) $message" }
        5 { Write-Verbose "$((Get-Date).ToString()) $message" }
        6 { Write-Debug "$((Get-Date).ToString()) $message" }
    }
}        