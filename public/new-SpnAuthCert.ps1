function new-SpnAuthCert{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>
    Param(
        [Parameter(Mandatory=$true)]$tenantId
    )
    
    if (-not [Guid]::TryParse($tenantId, [ref]([Guid]::Empty))) {
        Write-LogMessage -level 5 -message "Tenant ID is not a valid GUID, assuming it is a domain name and autodetect..."
        $tenantId = (Invoke-RestMethod "https://login.windows.net/$($tenantId)/.well-known/openid-configuration" -Method GET).userinfo_endpoint.Split("/")[3]
    }

    if (-not [Guid]::TryParse($tenantId, [ref]([Guid]::Empty))) {
        Throw "Tenant ID is not a valid GUID or domain name, or domain name could not be resolved to a tenant ID."
    }

    $pfxPath = "$($env:USERPROFILE)\$($tenantId).pfx"
    $cerPath = "$($env:USERPROFILE)\$($tenantId).cer"
    $password = ConvertTo-SecureString -String $(-join ((33..126) | Get-Random -Count 46 | % { [char]$_ })) -Force -AsPlainText

    $cert = New-SelfSignedCertificate -Subject "CN=$tenantId" -KeyAlgorithm RSA -KeyLength 2048 -CertStoreLocation "Cert:\CurrentUser\My" -NotAfter (Get-Date).AddDays(7)

    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $password
    Export-Certificate -Cert $cert -FilePath $cerPath

    Write-LogMessage -message "Certificate generated successfully!"
    Write-LogMessage -message "CER file: $cerPath (Import this into Entra ID)"
    Write-LogMessage -message "PFX file: $pfxPath (Ensure this is imported on your automation machine)"
}