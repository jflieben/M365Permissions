
function Write-ToJSONStorage {
    param (
        [Parameter(Mandatory=$true)] $data,
        [Parameter(Mandatory=$true)] [string]$FilePath
    )

    if($data.GetType().Name -ne "String"){
        $data = $data | ConvertTo-Json -Depth 10
    }

    if($data[0] -ne "["){
        $data = "[`n" + $data
    }

    if($data[-1] -ne "]"){
        $data = $data + "`n]"
    }

    $tryLock = $True
    if(!(Test-Path $FilePath)){
        try{
            Set-Content -Path $FilePath -Value $data -Encoding UTF8 -Force -Confirm:$False
            $tryLock = $False
        }catch{}
    }
    
    if($tryLock){
        $data = $data -replace '^\[', ','

        $attempt = 0;$MaxRetries = 100
        while ($attempt -lt $MaxRetries) {   
            try{
                $stream = [System.IO.File]::Open($FilePath, "Open", "ReadWrite", "Write")
                $attempt = $MaxRetries
            }catch{
                Start-Sleep -Milliseconds 2000 
                $attempt++
                continue
            }
        }
        $pos = $stream.Length - 1
        $buffer = New-Object byte[] 1
        
        while ($pos -ge 0) {
            $stream.Seek($pos--, "Begin") | Out-Null
            $stream.Read($buffer, 0, 1) | Out-Null
            if ([char]$buffer[0] -eq "]") { break }
        }
        
        $stream.Seek($pos, "Begin") | Out-Null
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($data)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.SetLength($stream.Position)
        $stream.Close()
    }
}