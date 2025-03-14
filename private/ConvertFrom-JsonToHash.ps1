function ConvertFrom-JsonToHash{
    Param(
        [Parameter(Mandatory=$true)][string]$path,
        [Parameter(Mandatory=$true)][string]$exclusionPattern
    )
    $hashtable = @{}
    $reader = [System.IO.StreamReader]::new($path)
    
    $bufferCleansed = ""
    $bufferOriginal = ""

    try {
        while ($line = $reader.ReadLine()) {
            if($line -in @(""," ","`n","`r","`t","[","]")){
                continue #skip empty lines or array starts/stops
            }
            if($line -match $exclusionPattern){
                $bufferOriginal += $line
                continue #skip excluded properties
            }
            if($line -match '^[\W_]*\{[\W_]*$'){
                $bufferOriginal = $line
                $bufferCleansed = $line #start of a new object
            }elseif($line -match '^[\W_]*\}[\W_]*$'){
                $bufferCleansed += "}" #end of an object
                $bufferOriginal += "}"
                if($bufferCleansed -eq $bufferOriginal){
                    $hashtable[$bufferCleansed.Replace(",}","}")] = $true
                }else{
                    $hashtable[$bufferCleansed.Replace(",}","}")] = $bufferOriginal
                }
            }else{
                $bufferOriginal += $line
                $bufferCleansed += $line
            }
        }
    } finally {
        $reader.Close()
    }
    return $hashtable
}