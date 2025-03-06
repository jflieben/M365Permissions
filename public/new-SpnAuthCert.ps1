function new-SpnAuthCert{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -tenantId: the tenantId (GUID) or domain name of the tenant you want to create a certificate for
        -importToEntraAppId: the appId of the application (SPN) you want to import the certificate into. If not provided, the CER file will be output to the current user's profile folder and you will need to import it manually.
    #>
    Param(
        [Parameter(Mandatory=$true)]$tenantId,
        [String]$importToEntraAppId
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

    $cert = New-SelfSignedCertificate -Subject "CN=$tenantId" -KeyAlgorithm RSA -KeyLength 2048 -CertStoreLocation "Cert:\CurrentUser\My" -NotAfter (Get-Date).AddYears(10)

    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $password
    Export-Certificate -Cert $cert -FilePath $cerPath

    Write-LogMessage -message "Certificate generated successfully!"
    if($importToEntraAppId){
        Write-LogMessage -message "Importing certificate into Entra ID application $($importToEntraAppId)..."
        $certBytes = [System.IO.File]::ReadAllBytes($cerPath)
        $certBase64 = [System.Convert]::ToBase64String($certBytes)

        $payload = @{
            keyCredentials = @(@{
                type          = "AsymmetricX509Cert"
                usage         = "Verify"
                key           = $certBase64
                displayName   = "Added via PowerShell"
            })
        }| ConvertTo-Json -Depth 10

        New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/applications/$($importToEntraAppId)" -Method PATCH -Body $payload
        Write-LogMessage -message "Certificate imported successfully!"
    }else{
        Write-LogMessage -message "CER file: $cerPath  --> Import this into your application in Entra ID"
    }
    $password = $password | ConvertFrom-SecureString -AsPlainText
    Write-LogMessage -message "PFX file: $pfxPath  --> Ensure this is imported on your automation machine, using password: $($password)"
}