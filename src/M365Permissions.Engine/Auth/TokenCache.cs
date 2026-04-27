using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;

namespace M365Permissions.Engine.Auth;

/// <summary>
/// Thread-safe token cache with expiry tracking.
/// Refresh tokens are persisted to disk (DPAPI-protected on Windows) so sessions survive restarts.
/// </summary>
public sealed class TokenCache
{
    private readonly ConcurrentDictionary<string, CachedToken> _tokens = new();
    private string? _refreshToken;
    private DateTimeOffset? _refreshTokenExpiresAt;
    private string? _ppRefreshToken;
    private DateTimeOffset? _ppRefreshTokenExpiresAt;
    private readonly string? _persistPath;
    private string? PpPersistPath => _persistPath != null ? Path.Combine(Path.GetDirectoryName(_persistPath)!, ".pprt") : null;
    private string? ExpiryPath => _persistPath != null ? _persistPath + ".exp" : null;
    private string? PpExpiryPath => PpPersistPath != null ? PpPersistPath + ".exp" : null;

    /// <summary>Actual refresh token expiry if known from token response, otherwise estimated 90 days from file timestamp.</summary>
    public DateTimeOffset? RefreshTokenExpiry => _refreshTokenExpiresAt;

    public TokenCache(string? persistDirectory = null)
    {
        if (!string.IsNullOrEmpty(persistDirectory))
        {
            Directory.CreateDirectory(persistDirectory);
            _persistPath = Path.Combine(persistDirectory, ".rt");
        }
    }

    public void Set(string resource, string accessToken, TimeSpan lifetime)
    {
        _tokens[resource] = new CachedToken(accessToken, DateTimeOffset.UtcNow.Add(lifetime));
    }

    public string? Get(string resource)
    {
        if (_tokens.TryGetValue(resource, out var cached) && cached.ExpiresAt > DateTimeOffset.UtcNow)
            return cached.AccessToken;
        return null;
    }

    public bool HasValidToken(string resource)
        => Get(resource) != null;

    public void SetRefreshToken(string refreshToken, long? expiresInSeconds = null)
    {
        _refreshToken = refreshToken;
        if (expiresInSeconds.HasValue)
            _refreshTokenExpiresAt = DateTimeOffset.UtcNow.AddSeconds(expiresInSeconds.Value);
        PersistToken(refreshToken, _persistPath);
        PersistExpiry(_refreshTokenExpiresAt, ExpiryPath);
    }

    public string? GetRefreshToken()
    {
        if (!string.IsNullOrEmpty(_refreshToken))
            return _refreshToken;

        _refreshToken = LoadPersistedToken(_persistPath);
        if (_refreshToken != null && _refreshTokenExpiresAt == null)
            _refreshTokenExpiresAt = LoadExpiry(ExpiryPath);
        return _refreshToken;
    }

    public void SetPPRefreshToken(string refreshToken, long? expiresInSeconds = null)
    {
        _ppRefreshToken = refreshToken;
        if (expiresInSeconds.HasValue)
            _ppRefreshTokenExpiresAt = DateTimeOffset.UtcNow.AddSeconds(expiresInSeconds.Value);
        PersistToken(refreshToken, PpPersistPath);
        PersistExpiry(_ppRefreshTokenExpiresAt, PpExpiryPath);
    }

    public string? GetPPRefreshToken()
    {
        if (!string.IsNullOrEmpty(_ppRefreshToken))
            return _ppRefreshToken;

        _ppRefreshToken = LoadPersistedToken(PpPersistPath);
        if (_ppRefreshToken != null && _ppRefreshTokenExpiresAt == null)
            _ppRefreshTokenExpiresAt = LoadExpiry(PpExpiryPath);
        return _ppRefreshToken;
    }

    public void Clear()
    {
        _tokens.Clear();
        _refreshToken = null;
        _ppRefreshToken = null;
        _refreshTokenExpiresAt = null;
        _ppRefreshTokenExpiresAt = null;
        DeletePersistedToken(_persistPath);
        DeletePersistedToken(PpPersistPath);
        DeletePersistedToken(ExpiryPath);
        DeletePersistedToken(PpExpiryPath);
    }

    private static void PersistToken(string token, string? path)
    {
        if (path == null) return;
        try
        {
            var plainBytes = Encoding.UTF8.GetBytes(token);
            if (OperatingSystem.IsWindows())
            {
                var encrypted = ProtectedData.Protect(plainBytes, null, DataProtectionScope.CurrentUser);
                File.WriteAllBytes(path, encrypted);
            }
            else
            {
                File.WriteAllText(path, Convert.ToBase64String(plainBytes));
            }
        }
        catch { /* best effort */ }
    }

    private static string? LoadPersistedToken(string? path)
    {
        if (path == null || !File.Exists(path)) return null;
        try
        {
            if (OperatingSystem.IsWindows())
            {
                var encrypted = File.ReadAllBytes(path);
                var plainBytes = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(plainBytes);
            }
            else
            {
                var b64 = File.ReadAllText(path);
                return Encoding.UTF8.GetString(Convert.FromBase64String(b64));
            }
        }
        catch
        {
            DeletePersistedToken(path);
            return null;
        }
    }

    private static void DeletePersistedToken(string? path)
    {
        if (path == null) return;
        try { File.Delete(path); } catch { }
    }

    private static void PersistExpiry(DateTimeOffset? expiry, string? path)
    {
        if (path == null) return;
        try
        {
            if (expiry.HasValue)
                File.WriteAllText(path, expiry.Value.ToString("O"));
        }
        catch { /* best effort */ }
    }

    private static DateTimeOffset? LoadExpiry(string? path)
    {
        if (path == null || !File.Exists(path)) return null;
        try
        {
            var text = File.ReadAllText(path).Trim();
            return DateTimeOffset.TryParse(text, out var dt) ? dt : null;
        }
        catch { return null; }
    }

    private sealed record CachedToken(string AccessToken, DateTimeOffset ExpiresAt);
}
