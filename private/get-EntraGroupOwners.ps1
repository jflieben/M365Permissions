function Get-EntraGroupOwners {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     
    Param(
        [Parameter(Mandatory=$true)]$groupId
    )

    try{
        [Array]$groupMembers = new-GraphQuery -Method GET -Uri "$($global:octo.graphUrl)/v1.0/groups/$groupId/owners/microsoft.graph.user" | Where-Object {$_}
    }catch{
        [Array]$groupMembers = @()
    }
    return $groupMembers
}