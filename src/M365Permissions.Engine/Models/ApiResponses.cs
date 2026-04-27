using System.Text.Json.Serialization;

namespace M365Permissions.Engine.Models;

/// <summary>
/// Standard API response envelope: { success, data?, error? }
/// </summary>
public sealed class ApiResponse<T>
{
    [JsonPropertyName("success")]
    public bool Success { get; set; }

    [JsonPropertyName("data")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public T? Data { get; set; }

    [JsonPropertyName("error")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Error { get; set; }

    public static ApiResponse<T> Ok(T data) => new() { Success = true, Data = data };
    public static ApiResponse<T> Fail(string error) => new() { Success = false, Error = error };
}

public static class ApiResponse
{
    public static ApiResponse<object?> Ok() => new() { Success = true };
    public static ApiResponse<object?> Fail(string error) => new() { Success = false, Error = error };
}

/// <summary>
/// Status endpoint response.
/// </summary>
public sealed class StatusResponse
{
    [JsonPropertyName("connected")]
    public bool Connected { get; set; }

    [JsonPropertyName("tenantId")]
    public string? TenantId { get; set; }

    [JsonPropertyName("tenantDomain")]
    public string? TenantDomain { get; set; }

    [JsonPropertyName("userPrincipalName")]
    public string? UserPrincipalName { get; set; }

    [JsonPropertyName("moduleVersion")]
    public string ModuleVersion { get; set; } = Engine.ModuleVersion;

    [JsonPropertyName("scanning")]
    public bool Scanning { get; set; }

    [JsonPropertyName("activeScanId")]
    public long? ActiveScanId { get; set; }

    [JsonPropertyName("refreshTokenExpiry")]
    public string? RefreshTokenExpiry { get; set; }
}

/// <summary>
/// Paginated results response.
/// </summary>
public sealed class PagedResult<T>
{
    [JsonPropertyName("items")]
    public List<T> Items { get; set; } = new();

    [JsonPropertyName("totalCount")]
    public long TotalCount { get; set; }

    [JsonPropertyName("page")]
    public int Page { get; set; }

    [JsonPropertyName("pageSize")]
    public int PageSize { get; set; }
}

/// <summary>
/// Comparison result between two scans.
/// </summary>
public sealed class ComparisonResult
{
    [JsonPropertyName("oldScanId")]
    public long OldScanId { get; set; }

    [JsonPropertyName("newScanId")]
    public long NewScanId { get; set; }

    [JsonPropertyName("added")]
    public List<PermissionEntry> Added { get; set; } = new();

    [JsonPropertyName("removed")]
    public List<PermissionEntry> Removed { get; set; } = new();

    [JsonPropertyName("changed")]
    public List<PermissionChange> Changed { get; set; } = new();
}

public sealed class PermissionChange
{
    [JsonPropertyName("old")]
    public PermissionEntry Old { get; set; } = new();

    [JsonPropertyName("new")]
    public PermissionEntry New { get; set; } = new();

    [JsonPropertyName("changedFields")]
    public List<string> ChangedFields { get; set; } = new();
}

public sealed class TrendDataPoint
{
    [JsonPropertyName("scanId")]
    public long ScanId { get; set; }

    [JsonPropertyName("startedAt")]
    public string StartedAt { get; set; } = string.Empty;

    [JsonPropertyName("tenantDomain")]
    public string TenantDomain { get; set; } = string.Empty;

    [JsonPropertyName("totalPermissions")]
    public long TotalPermissions { get; set; }

    [JsonPropertyName("critical")]
    public int Critical { get; set; }

    [JsonPropertyName("high")]
    public int High { get; set; }

    [JsonPropertyName("medium")]
    public int Medium { get; set; }

    [JsonPropertyName("low")]
    public int Low { get; set; }

    [JsonPropertyName("info")]
    public int Info { get; set; }
}

public sealed class AuditEntry
{
    [JsonPropertyName("id")]
    public long Id { get; set; }

    [JsonPropertyName("action")]
    public string Action { get; set; } = string.Empty;

    [JsonPropertyName("userName")]
    public string UserName { get; set; } = string.Empty;

    [JsonPropertyName("details")]
    public string Details { get; set; } = string.Empty;

    [JsonPropertyName("scanId")]
    public long? ScanId { get; set; }

    [JsonPropertyName("timestamp")]
    public string Timestamp { get; set; } = string.Empty;
}

public sealed class UserCountInfo
{
    [JsonPropertyName("userCount")]
    public long UserCount { get; set; }

    [JsonPropertyName("recommendation")]
    public string? Recommendation { get; set; }
}

public sealed class DatabaseInfo
{
    [JsonPropertyName("path")]
    public string Path { get; set; } = string.Empty;

    [JsonPropertyName("sizeBytes")]
    public long SizeBytes { get; set; }

    [JsonPropertyName("sizeMB")]
    public double SizeMB => Math.Round(SizeBytes / 1048576.0, 2);

    [JsonPropertyName("tableCounts")]
    public Dictionary<string, long> TableCounts { get; set; } = new();
}
