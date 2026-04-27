using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Data.Sqlite;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Database;

/// <summary>
/// Manages SQLite connection lifecycle and schema migration.
/// Thread-safe: uses a single connection string; SQLite handles WAL-mode concurrency.
/// </summary>
public sealed class SqliteDb : IDisposable
{
    private readonly string _connectionString;
    private readonly string _databasePath;
    private bool _initialized;
    private static bool _nativeInitialized;

    /// <summary>Full path to the SQLite database file.</summary>
    public string DatabasePath => _databasePath;

    public SqliteDb(string databasePath)
    {
        // Ensure SQLitePCLRaw native provider is initialized (required when loaded in PowerShell)
        if (!_nativeInitialized)
        {
            _nativeInitialized = true;

            // Register a resolver so the runtime can find e_sqlite3 native library
            // under runtimes/{rid}/native/ — needed when loaded outside a standard .NET host (e.g. PowerShell)
            var providerAssembly = typeof(SQLitePCL.SQLite3Provider_e_sqlite3).Assembly;
            NativeLibrary.SetDllImportResolver(providerAssembly, ResolveNativeLibrary);

            SQLitePCL.Batteries_V2.Init();
        }

        _databasePath = databasePath;

        var dir = Path.GetDirectoryName(databasePath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared
        }.ToString();
    }

    /// <summary>Create a new open connection. Caller owns disposal.</summary>
    public SqliteConnection CreateConnection()
    {
        var conn = new SqliteConnection(_connectionString);
        conn.Open();
        // Enable WAL mode for concurrent reads during scans
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;";
        cmd.ExecuteNonQuery();
        return conn;
    }

    /// <summary>
    /// Apply embedded Schema.sql if tables don't exist yet.
    /// Safe to call multiple times (CREATE TABLE IF NOT EXISTS).
    /// </summary>
    public void Initialize()
    {
        if (_initialized) return;

        var assembly = Assembly.GetExecutingAssembly();
        var resourceName = "M365Permissions.Engine.Database.Schema.sql";

        using var stream = assembly.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Embedded resource '{resourceName}' not found.");
        using var reader = new StreamReader(stream);
        var sql = reader.ReadToEnd();

        using var conn = CreateConnection();

        // 1. Execute schema first to ensure all tables exist (CREATE TABLE IF NOT EXISTS).
        using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();

        // 2. Apply migrations for existing databases — adds missing columns/indexes
        //    that were introduced after the original schema (safe to run on fresh DBs too).
        ApplyMigrations(conn);

        _initialized = true;
    }

    /// <summary>
    /// Add columns/tables that didn't exist in earlier schema versions.
    /// Each migration is guarded to be idempotent.
    /// </summary>
    private static void ApplyMigrations(SqliteConnection conn)
    {
        // Migration 1: Add risk_level, risk_reason to permissions
        AddColumnIfMissing(conn, "permissions", "risk_level", "TEXT NOT NULL DEFAULT ''");
        AddColumnIfMissing(conn, "permissions", "risk_reason", "TEXT NOT NULL DEFAULT ''");

        // Migration 2: Add notes, tags to scans
        AddColumnIfMissing(conn, "scans", "notes", "TEXT NOT NULL DEFAULT ''");
        AddColumnIfMissing(conn, "scans", "tags", "TEXT NOT NULL DEFAULT ''");

        // Migration 3: risk index
        using var idxCmd = conn.CreateCommand();
        idxCmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_permissions_risk ON permissions(scan_id, risk_level)";
        idxCmd.ExecuteNonQuery();

        // Migration 4: audit_log table + indexes (handled by CREATE TABLE IF NOT EXISTS in schema)
        using var auditIdxCmd = conn.CreateCommand();
        auditIdxCmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_log(timestamp)";
        auditIdxCmd.ExecuteNonQuery();
        using var auditIdx2 = conn.CreateCommand();
        auditIdx2.CommandText = "CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_log(action)";
        auditIdx2.ExecuteNonQuery();

        // Migration 5: policies table
        using var policiesCmd = conn.CreateCommand();
        policiesCmd.CommandText = @"CREATE TABLE IF NOT EXISTS policies (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            name                TEXT NOT NULL DEFAULT '',
            description         TEXT NOT NULL DEFAULT '',
            enabled             INTEGER NOT NULL DEFAULT 1,
            severity            TEXT NOT NULL DEFAULT 'High',
            category_filter     TEXT NOT NULL DEFAULT '',
            conditions          TEXT NOT NULL DEFAULT '[]',
            is_default          INTEGER NOT NULL DEFAULT 0,
            created_at          TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at          TEXT NOT NULL DEFAULT (datetime('now'))
        )";
        policiesCmd.ExecuteNonQuery();

        // Migration 6: add conditions + is_default columns to existing policies tables
        AddColumnIfMissing(conn, "policies", "conditions", "TEXT NOT NULL DEFAULT '[]'");
        AddColumnIfMissing(conn, "policies", "is_default", "INTEGER NOT NULL DEFAULT 0");
    }

    private static void AddColumnIfMissing(SqliteConnection conn, string table, string column, string definition)
    {
        using var infoCmd = conn.CreateCommand();
        infoCmd.CommandText = $"PRAGMA table_info({table})";
        bool exists = false;
        using (var reader = infoCmd.ExecuteReader())
        {
            while (reader.Read())
            {
                if (string.Equals(reader.GetString(1), column, StringComparison.OrdinalIgnoreCase))
                { exists = true; break; }
            }
        }
        if (!exists)
        {
            using var alterCmd = conn.CreateCommand();
            alterCmd.CommandText = $"ALTER TABLE {table} ADD COLUMN {column} {definition}";
            alterCmd.ExecuteNonQuery();
        }
    }

    /// <summary>Get database file size and table row counts.</summary>
    public DatabaseInfo GetDatabaseInfo()
    {
        var info = new DatabaseInfo { Path = _databasePath };

        // File sizes
        if (File.Exists(_databasePath))
            info.SizeBytes = new FileInfo(_databasePath).Length;

        var walPath = _databasePath + "-wal";
        if (File.Exists(walPath))
            info.SizeBytes += new FileInfo(walPath).Length;

        // Row counts per table
        using var conn = CreateConnection();
        foreach (var table in new[] { "scans", "permissions", "scan_progress", "comparisons", "logs", "audit_log", "policies", "config" })
        {
            try
            {
                using var cmd = conn.CreateCommand();
                cmd.CommandText = $"SELECT COUNT(*) FROM {table}";
                var count = Convert.ToInt64(cmd.ExecuteScalar());
                info.TableCounts[table] = count;
            }
            catch { /* table may not exist */ }
        }

        return info;
    }

    /// <summary>Delete all scan data (scans, permissions, progress, comparisons, logs, audit). Preserves config and policies.</summary>
    public void ResetDatabase()
    {
        // Delete all scan data
        using (var conn = CreateConnection())
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = @"
                DELETE FROM permissions;
                DELETE FROM scan_progress;
                DELETE FROM comparisons;
                DELETE FROM logs;
                DELETE FROM audit_log;
                DELETE FROM scans;
            ";
            cmd.ExecuteNonQuery();
        }

        // VACUUM must run on its own connection with no other connections open.
        // Clear connection pool first so no pooled connections hold the DB open.
        SqliteConnection.ClearAllPools();

        using (var conn = CreateConnection())
        {
            using var vacCmd = conn.CreateCommand();
            vacCmd.CommandText = "VACUUM;";
            vacCmd.ExecuteNonQuery();
        }
    }

    public void Dispose()
    {
        // Flush WAL and release SQLite connection pool.
        try
        {
            using var conn = CreateConnection();
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "PRAGMA wal_checkpoint(TRUNCATE);";
            cmd.ExecuteNonQuery();
        }
        catch { /* best effort — may fail during process teardown */ }

        // Clear the connection pool so all file handles are released.
        // Without this, the .db file (and WAL/SHM) stay locked until GC.
        SqliteConnection.ClearAllPools();
    }

    /// <summary>
    /// Resolves native e_sqlite3 library from runtimes/{rid}/native/ relative to the assembly location.
    /// Required when loaded in PowerShell because the default .NET host probing paths don't apply.
    /// </summary>
    private static IntPtr ResolveNativeLibrary(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (libraryName != "e_sqlite3")
            return IntPtr.Zero;

        var libDir = Path.GetDirectoryName(typeof(SqliteDb).Assembly.Location) ?? ".";

        var os = OperatingSystem.IsWindows() ? "win"
               : OperatingSystem.IsLinux() ? "linux"
               : OperatingSystem.IsMacOS() ? "osx"
               : null;

        var arch = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.X64 => "x64",
            Architecture.Arm64 => "arm64",
            Architecture.X86 => "x86",
            Architecture.Arm => "arm",
            _ => null
        };

        if (os != null && arch != null)
        {
            var runtimePath = Path.Combine(libDir, "runtimes", $"{os}-{arch}", "native", libraryName);
            if (NativeLibrary.TryLoad(runtimePath, out var handle))
                return handle;
        }

        // Fallback: try same directory as the managed DLLs
        if (NativeLibrary.TryLoad(Path.Combine(libDir, libraryName), out var fallback))
            return fallback;

        return IntPtr.Zero;
    }
}
