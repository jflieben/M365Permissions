function ConvertFrom-JsonToHash{
    Param(
        [Parameter(Mandatory=$true)][string]$path,
        [Parameter(Mandatory=$true)][string]$exclusionPattern
    )
    $hashtable = @{}
    $reader = [System.IO.StreamReader]::new($path)
    
    $buffer = ""  # Stores the current JSON object as a string
    
    try {
        while ($line = $reader.ReadLine()) {
            if($line -in @(""," ","`n","`r","`t","[","]")){
                continue #skip empty lines or array starts/stops
            }
            if($line -match $exclusionPattern){
                continue #skip excluded properties
            }
            if($line -match '^[\W_]*\{[\W_]*$'){
                $buffer = $line #start of a new object
            }elseif($line -match '^[\W_]*\}[\W_]*$'){
                $buffer += "}" #end of an object
                $hashtable[$buffer] = $true
            }else{
                $buffer += $line
            }
        }
    } finally {
        $reader.Close()
    }
    return $hashtable
}