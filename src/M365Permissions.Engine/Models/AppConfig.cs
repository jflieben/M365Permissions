namespace M365Permissions.Engine.Models;

/// <summary>
/// Application configuration — stored in SQLite config table as key-value pairs.
/// This class represents the in-memory view.
/// </summary>
public sealed class AppConfig
{
    public int GuiPort { get; set; } = 8080;
    public int MaxThreads { get; set; } = 5;
    public string OutputFormat { get; set; } = "XLSX";          // XLSX | CSV
    public string LogLevel { get; set; } = "Minimal";          // Full | Normal | Minimal | None
    public bool IncludeCurrentUser { get; set; } = false;
    public int DefaultTimeoutMinutes { get; set; } = 120;
    public int MaxJobRetries { get; set; } = 3;
}
