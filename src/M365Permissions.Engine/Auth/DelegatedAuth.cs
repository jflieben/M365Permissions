using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Security.Cryptography;

namespace M365Permissions.Engine.Auth;

/// <summary>
/// OAuth2 Authorization Code flow with PKCE for delegated authentication.
/// Opens system browser → user signs in → local loopback HTTP listener captures code → exchanges for tokens.
/// </summary>
public sealed class DelegatedAuth
{
    // App registration used by M365Permissions
    private const string ClientId = "0ee7aa45-310d-4b82-9cb5-11cc01ad38e4";
    // Microsoft's well-known PowerApps/Flow client ID (pre-consented for PP APIs)
    private const string PowerPlatformClientId = "689e5960-2e49-4505-98d8-369236220fc6";
    private const string Authority = "https://login.microsoftonline.com/common";
    private const string GraphScope = "https://graph.microsoft.com/.default offline_access openid profile";

    private readonly TokenCache _tokenCache;
    private string? _tenantId;
    private string? _tenantDomain;
    private string? _userPrincipalName;

    public bool IsConnected => _tokenCache.HasValidToken("graph") || _tokenCache.GetRefreshToken() != null;
    public string? TenantId => _tenantId;
    public string? TenantDomain => _tenantDomain;
    public string? UserPrincipalName => _userPrincipalName;
    public DateTimeOffset? RefreshTokenExpiry => _tokenCache.RefreshTokenExpiry;

    public DelegatedAuth(TokenCache tokenCache)
    {
        _tokenCache = tokenCache;
    }

    /// <summary>
    /// Perform interactive delegated sign-in.
    /// Opens system browser, waits for OAuth callback on loopback port.
    /// </summary>
    public async Task AuthenticateAsync(CancellationToken ct = default)
    {
        // Generate PKCE challenge
        var codeVerifier = GenerateCodeVerifier();
        var codeChallenge = GenerateCodeChallenge(codeVerifier);

        // Loopback listener on fixed port
        var listener = new HttpListener();
        const int redirectPort = 1985;
        var redirectUri = $"http://localhost:{redirectPort}/";
        listener.Prefixes.Add(redirectUri);
        listener.Start();

        try
        {
            // Build authorization URL
            var authUrl = $"{Authority}/oauth2/v2.0/authorize" +
                $"?client_id={Uri.EscapeDataString(ClientId)}" +
                $"&response_type=code" +
                $"&redirect_uri={Uri.EscapeDataString(redirectUri)}" +
                $"&response_mode=query" +
                $"&scope={Uri.EscapeDataString(GraphScope)}" +
                $"&code_challenge={codeChallenge}" +
                $"&code_challenge_method=S256";

            // Open browser
            OpenBrowser(authUrl);

            // Wait for callback
            var context = await listener.GetContextAsync().WaitAsync(TimeSpan.FromMinutes(5), ct);
            var code = context.Request.QueryString["code"];
            var error = context.Request.QueryString["error"];

            // Send response to browser
            var responseHtml = code != null
                ? "<html><body><h2>Authentication successful!</h2><p>You can close this window.</p></body></html>"
                : $"<html><body><h2>Authentication failed</h2><p>{error}</p></body></html>";
            var buffer = System.Text.Encoding.UTF8.GetBytes(responseHtml);
            context.Response.ContentType = "text/html";
            context.Response.ContentLength64 = buffer.Length;
            await context.Response.OutputStream.WriteAsync(buffer, ct);
            context.Response.Close();

            if (string.IsNullOrEmpty(code))
                throw new InvalidOperationException($"Authentication failed: {error}");

            // Exchange code for tokens
            await ExchangeCodeForTokens(code, redirectUri, codeVerifier, ct);

            // Discover tenant info
            await DiscoverTenantInfoAsync(ct);
        }
        finally
        {
            listener.Stop();
            listener.Close();
        }
    }

    public void SignOut()
    {
        _tokenCache.Clear();
        _tenantId = null;
        _tenantDomain = null;
        _userPrincipalName = null;
    }

    /// <summary>
    /// Trigger an interactive admin consent flow for the M365Permissions app registration.
    /// Opens browser with prompt=consent to let an admin re-grant all configured API permissions.
    /// After consent, tokens are refreshed so new permissions take effect immediately.
    /// </summary>
    public async Task ReconsentAsync(CancellationToken ct = default)
    {
        var codeVerifier = GenerateCodeVerifier();
        var codeChallenge = GenerateCodeChallenge(codeVerifier);

        var listener = new HttpListener();
        const int redirectPort = 1985;
        var redirectUri = $"http://localhost:{redirectPort}/";
        listener.Prefixes.Add(redirectUri);
        listener.Start();

        try
        {
            var authUrl = $"{Authority}/oauth2/v2.0/authorize" +
                $"?client_id={Uri.EscapeDataString(ClientId)}" +
                $"&response_type=code" +
                $"&redirect_uri={Uri.EscapeDataString(redirectUri)}" +
                $"&response_mode=query" +
                $"&scope={Uri.EscapeDataString(GraphScope)}" +
                $"&prompt=consent" +
                $"&code_challenge={codeChallenge}" +
                $"&code_challenge_method=S256";

            OpenBrowser(authUrl);

            var context = await listener.GetContextAsync().WaitAsync(TimeSpan.FromMinutes(5), ct);
            var code = context.Request.QueryString["code"];
            var error = context.Request.QueryString["error"];

            var responseHtml = code != null
                ? "<html><body><h2>Consent granted!</h2><p>Permissions have been updated. You can close this window.</p></body></html>"
                : $"<html><body><h2>Consent failed</h2><p>{System.Net.WebUtility.HtmlEncode(error)}</p></body></html>";
            var buffer = System.Text.Encoding.UTF8.GetBytes(responseHtml);
            context.Response.ContentType = "text/html";
            context.Response.ContentLength64 = buffer.Length;
            await context.Response.OutputStream.WriteAsync(buffer, ct);
            context.Response.Close();

            if (string.IsNullOrEmpty(code))
                throw new InvalidOperationException($"Consent failed: {error}");

            // Exchange code for fresh tokens with the newly consented permissions
            await ExchangeCodeForTokens(code, redirectUri, codeVerifier, ct);

            // Refresh tenant info in case this is a different consent context
            await DiscoverTenantInfoAsync(ct);
        }
        finally
        {
            listener.Stop();
            listener.Close();
        }
    }

    /// <summary>
    /// Try to restore a previous session using a persisted refresh token.
    /// Returns true if session was restored, false if interactive login is needed.
    /// </summary>
    public async Task<bool> TryRestoreSessionAsync(CancellationToken ct = default)
    {
        var refreshToken = _tokenCache.GetRefreshToken();
        if (string.IsNullOrEmpty(refreshToken))
            return false;

        try
        {
            await RefreshTokensAsync(refreshToken, ct);
            await DiscoverTenantInfoAsync(ct);
            return true;
        }
        catch
        {
            // Refresh token expired or revoked — need interactive login
            return false;
        }
    }

    /// <summary>Get a valid access token for the given resource. Auto-refreshes if expired.</summary>
    public async Task<string> GetAccessTokenAsync(string resource = "graph", CancellationToken ct = default)
    {
        var token = _tokenCache.Get(resource);
        if (token != null) return token;

        // Power Platform resources use the well-known PP client ID (different from our app)
        if (IsPowerPlatformResource(resource))
            return await AcquirePowerPlatformTokenAsync(resource, ct);

        // Try refresh with the appropriate scope for the requested resource
        var refreshToken = _tokenCache.GetRefreshToken();
        if (string.IsNullOrEmpty(refreshToken))
            throw new InvalidOperationException("Not authenticated. Call ConnectAsync first.");

        var scope = GetScopeForResource(resource);
        await AcquireTokenForResourceAsync(refreshToken, ClientId, resource, scope, ct);
        return _tokenCache.Get(resource)
            ?? throw new InvalidOperationException($"Token acquisition for '{resource}' failed.");
    }

    private static bool IsPowerPlatformResource(string resource)
        => resource is "powerapps" or "flow";

    /// <summary>
    /// Acquire a Power Platform token using Microsoft's well-known PowerApps client ID.
    /// Uses a separate refresh token since it's a different client application.
    /// On first use, triggers an interactive browser login.
    /// </summary>
    private async Task<string> AcquirePowerPlatformTokenAsync(string resource, CancellationToken ct)
    {
        var scope = GetScopeForResource(resource);
        var ppRefreshToken = _tokenCache.GetPPRefreshToken();

        if (!string.IsNullOrEmpty(ppRefreshToken))
        {
            try
            {
                await AcquireTokenForResourceAsync(ppRefreshToken, PowerPlatformClientId, resource, scope, ct, isPP: true);
                var token = _tokenCache.Get(resource);
                if (token != null) return token;
            }
            catch (ResourcePrincipalNotFoundException)
            {
                // SPN missing — surface immediately so caller can skip this scan
                throw;
            }
            catch
            {
                // Refresh token expired or invalid — fall through to interactive
            }
        }

        // Interactive PKCE login with the PP client ID
        await AcquireTokenInteractiveAsync(PowerPlatformClientId, resource, scope, ct, isPP: true);
        return _tokenCache.Get(resource)
            ?? throw new InvalidOperationException($"Power Platform token acquisition for '{resource}' failed.");
    }

    /// <summary>Map resource key to the OAuth2 scope string needed for that API.</summary>
    private string GetScopeForResource(string resource) => resource switch
    {
        "graph" => GraphScope,
        "sharepoint" => $"https://{GetSharePointHost()}/.default offline_access",
        "exchange" => "https://outlook.office365.com/.default offline_access",
        "compliance" => "https://ps.compliance.protection.outlook.com/.default offline_access",
        "powerbi" => "https://analysis.windows.net/powerbi/api/.default offline_access",
        // BAP + PowerApps APIs use service.powerapps.com audience
        "powerapps" => "https://service.powerapps.com/.default offline_access",
        // Flow API uses service.flow.microsoft.com audience
        "flow" => "https://service.flow.microsoft.com/.default offline_access",
        "azure" => "https://management.azure.com/.default offline_access",
        "azuredevops" => "499b84ac-1321-427f-aa17-267ca6975798/user_impersonation offline_access",
        "sharepointadmin" => $"https://{GetSharePointAdminHost()}/.default offline_access",
        _ => throw new ArgumentException($"Unknown resource: {resource}")
    };

    /// <summary>Derive the tenant's SharePoint hostname (e.g. contoso.sharepoint.com).</summary>
    private string GetSharePointHost()
    {
        // Use tenant domain to derive SPO host: lieben.nu → lieben.sharepoint.com
        // Convention: take the first label of the verified domain
        if (!string.IsNullOrEmpty(_tenantDomain))
        {
            var label = _tenantDomain.Split('.')[0];
            return $"{label}.sharepoint.com";
        }
        throw new InvalidOperationException("Tenant domain not available. Ensure you're connected first.");
    }

    /// <summary>Derive the tenant's SharePoint admin hostname (e.g. contoso-admin.sharepoint.com).</summary>
    private string GetSharePointAdminHost()
    {
        if (!string.IsNullOrEmpty(_tenantDomain))
        {
            var label = _tenantDomain.Split('.')[0];
            return $"{label}-admin.sharepoint.com";
        }
        throw new InvalidOperationException("Tenant domain not available. Ensure you're connected first.");
    }

    /// <summary>Get the SharePoint admin site URL (e.g. https://contoso-admin.sharepoint.com).</summary>
    public string GetSharePointAdminUrl() => $"https://{GetSharePointAdminHost()}";

    /// <summary>Acquire an access token for a specific resource using a refresh token.</summary>
    private async Task AcquireTokenForResourceAsync(string refreshToken, string clientId, string cacheKey, string scope, CancellationToken ct, bool isPP = false)
    {
        using var http = new HttpClient();
        var body = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["client_id"] = clientId,
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = refreshToken,
            ["scope"] = scope
        });

        var response = await http.PostAsync($"{Authority}/oauth2/v2.0/token", body, ct);
        var json = await response.Content.ReadAsStringAsync(ct);

        if (!response.IsSuccessStatusCode)
        {
            ThrowIfResourcePrincipalMissing(cacheKey, json);
            throw new InvalidOperationException($"Token acquisition for '{cacheKey}' failed: {json}");
        }

        var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        _tokenCache.Set(cacheKey,
            root.GetProperty("access_token").GetString()!,
            TimeSpan.FromSeconds(root.GetProperty("expires_in").GetInt32() - 300));

        if (root.TryGetProperty("refresh_token", out var rt))
        {
            long? rtExpiry = root.TryGetProperty("refresh_token_expires_in", out var rtExp) ? rtExp.GetInt64() : null;
            if (isPP)
                _tokenCache.SetPPRefreshToken(rt.GetString()!, rtExpiry);
            else
                _tokenCache.SetRefreshToken(rt.GetString()!, rtExpiry);
        }
    }

    /// <summary>
    /// If the AAD error response indicates the resource service principal is missing in
    /// the user's tenant (e.g. PowerBI / Azure DevOps / ASM never used in this tenant),
    /// throw a typed <see cref="ResourcePrincipalNotFoundException"/> so callers can skip
    /// that resource gracefully. Otherwise return without throwing.
    /// </summary>
    private static void ThrowIfResourcePrincipalMissing(string resource, string errorJson)
    {
        // AAD error codes that indicate the resource SPN is not provisioned in the tenant
        // (or otherwise not consentable for this tenant):
        //  - AADSTS500011: The resource principal named X was not found in the tenant
        //  - AADSTS650052: The app needs access to a service that your organization has not subscribed to
        //  - AADSTS650057: Invalid resource
        //  - AADSTS500341: The user account has been deleted from the directory (different — don't catch)
        string? code = null;
        try
        {
            using var doc = JsonDocument.Parse(errorJson);
            if (doc.RootElement.TryGetProperty("error", out var errElem) && errElem.ValueKind == JsonValueKind.String)
                code = errElem.GetString();
            // AAD returns the AADSTS code embedded in error_description
            if (doc.RootElement.TryGetProperty("error_description", out var descElem))
            {
                var desc = descElem.GetString() ?? string.Empty;
                if (desc.Contains("AADSTS500011", StringComparison.Ordinal)
                    || desc.Contains("AADSTS650052", StringComparison.Ordinal)
                    || desc.Contains("AADSTS650057", StringComparison.Ordinal))
                {
                    var aadCode = desc.Contains("AADSTS500011") ? "AADSTS500011"
                                : desc.Contains("AADSTS650052") ? "AADSTS650052"
                                : "AADSTS650057";
                    throw new ResourcePrincipalNotFoundException(resource, aadCode,
                        $"The service principal for '{resource}' is not available in this tenant ({aadCode}). " +
                        "This usually means the service is not licensed or has never been used. " +
                        "Skipping this scan.");
                }
            }
        }
        catch (ResourcePrincipalNotFoundException) { throw; }
        catch { /* not JSON or unexpected — fall through to generic exception */ }
        _ = code;
    }

    /// <summary>
    /// Interactive PKCE browser login for a specific client + scope.
    /// Used for incremental consent and Power Platform client flows.
    /// </summary>
    private async Task AcquireTokenInteractiveAsync(string clientId, string cacheKey, string scope, CancellationToken ct, bool isPP = false)
    {
        var codeVerifier = GenerateCodeVerifier();
        var codeChallenge = GenerateCodeChallenge(codeVerifier);

        var listener = new HttpListener();
        const int redirectPort = 1985;
        var redirectUri = $"http://localhost:{redirectPort}/";
        listener.Prefixes.Add(redirectUri);
        listener.Start();

        try
        {
            var authUrl = $"{Authority}/oauth2/v2.0/authorize" +
                $"?client_id={Uri.EscapeDataString(clientId)}" +
                $"&response_type=code" +
                $"&redirect_uri={Uri.EscapeDataString(redirectUri)}" +
                $"&response_mode=query" +
                $"&scope={Uri.EscapeDataString(scope)}" +
                $"&code_challenge={codeChallenge}" +
                $"&code_challenge_method=S256";

            OpenBrowser(authUrl);

            var context = await listener.GetContextAsync().WaitAsync(TimeSpan.FromMinutes(5), ct);
            var code = context.Request.QueryString["code"];
            var error = context.Request.QueryString["error"];

            var responseHtml = code != null
                ? "<html><body><h2>Authentication successful!</h2><p>You can close this window.</p></body></html>"
                : $"<html><body><h2>Authentication failed</h2><p>{error}</p></body></html>";
            var buffer = System.Text.Encoding.UTF8.GetBytes(responseHtml);
            context.Response.ContentType = "text/html";
            context.Response.ContentLength64 = buffer.Length;
            await context.Response.OutputStream.WriteAsync(buffer, ct);
            context.Response.Close();

            if (string.IsNullOrEmpty(code))
                throw new InvalidOperationException($"Interactive auth failed for '{cacheKey}': {error}");

            using var http = new HttpClient();
            var body = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["client_id"] = clientId,
                ["grant_type"] = "authorization_code",
                ["code"] = code,
                ["redirect_uri"] = redirectUri,
                ["code_verifier"] = codeVerifier,
                ["scope"] = scope
            });

            var response = await http.PostAsync($"{Authority}/oauth2/v2.0/token", body, ct);
            var json = await response.Content.ReadAsStringAsync(ct);

            if (!response.IsSuccessStatusCode)
            {
                ThrowIfResourcePrincipalMissing(cacheKey, json);
                throw new InvalidOperationException($"Token exchange for '{cacheKey}' failed: {json}");
            }

            var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            _tokenCache.Set(cacheKey,
                root.GetProperty("access_token").GetString()!,
                TimeSpan.FromSeconds(root.GetProperty("expires_in").GetInt32() - 300));

            if (root.TryGetProperty("refresh_token", out var rt))
            {
                long? rtExpiry = root.TryGetProperty("refresh_token_expires_in", out var rtExp) ? rtExp.GetInt64() : null;
                if (isPP)
                    _tokenCache.SetPPRefreshToken(rt.GetString()!, rtExpiry);
                else
                    _tokenCache.SetRefreshToken(rt.GetString()!, rtExpiry);
            }
        }
        finally
        {
            listener.Stop();
            listener.Close();
        }
    }

    private async Task ExchangeCodeForTokens(string code, string redirectUri, string codeVerifier, CancellationToken ct)
    {
        using var http = new HttpClient();
        var body = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["client_id"] = ClientId,
            ["grant_type"] = "authorization_code",
            ["code"] = code,
            ["redirect_uri"] = redirectUri,
            ["code_verifier"] = codeVerifier,
            ["scope"] = GraphScope
        });

        var response = await http.PostAsync($"{Authority}/oauth2/v2.0/token", body, ct);
        var json = await response.Content.ReadAsStringAsync(ct);

        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Token exchange failed: {json}");

        var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        _tokenCache.Set("graph",
            root.GetProperty("access_token").GetString()!,
            TimeSpan.FromSeconds(root.GetProperty("expires_in").GetInt32() - 300));

        if (root.TryGetProperty("refresh_token", out var rt))
        {
            long? rtExpiry = root.TryGetProperty("refresh_token_expires_in", out var rtExp) ? rtExp.GetInt64() : null;
            _tokenCache.SetRefreshToken(rt.GetString()!, rtExpiry);
        }
    }

    private async Task RefreshTokensAsync(string refreshToken, CancellationToken ct)
    {
        await AcquireTokenForResourceAsync(refreshToken, ClientId, "graph", GraphScope, ct, false);
    }

    private async Task DiscoverTenantInfoAsync(CancellationToken ct)
    {
        var token = _tokenCache.Get("graph")
            ?? throw new InvalidOperationException("No access token available");

        using var http = new HttpClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

        // Get current user
        var userResponse = await http.GetStringAsync("https://graph.microsoft.com/v1.0/me?$select=userPrincipalName,mail", ct);
        var userDoc = JsonDocument.Parse(userResponse);
        _userPrincipalName = userDoc.RootElement.GetProperty("userPrincipalName").GetString();

        // Get organization info
        var orgResponse = await http.GetStringAsync("https://graph.microsoft.com/v1.0/organization?$select=id,verifiedDomains", ct);
        var orgDoc = JsonDocument.Parse(orgResponse);
        var orgs = orgDoc.RootElement.GetProperty("value");
        if (orgs.GetArrayLength() > 0)
        {
            var org = orgs[0];
            _tenantId = org.GetProperty("id").GetString();

            // Find the default verified domain
            foreach (var domain in org.GetProperty("verifiedDomains").EnumerateArray())
            {
                if (domain.TryGetProperty("isDefault", out var isDefault) && isDefault.GetBoolean())
                {
                    _tenantDomain = domain.GetProperty("name").GetString();
                    break;
                }
            }
        }
    }

    private static string GenerateCodeVerifier()
    {
        var bytes = RandomNumberGenerator.GetBytes(32);
        return Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    private static string GenerateCodeChallenge(string codeVerifier)
    {
        var hash = SHA256.HashData(System.Text.Encoding.ASCII.GetBytes(codeVerifier));
        return Convert.ToBase64String(hash)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    private static void OpenBrowser(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch
        {
            // Fallback for Linux/macOS
            if (OperatingSystem.IsLinux())
                Process.Start("xdg-open", url);
            else if (OperatingSystem.IsMacOS())
                Process.Start("open", url);
        }
    }
}
