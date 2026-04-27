-- M365Permissions SQLite Schema
-- Applied automatically on first run via SqliteDb.Initialize()

CREATE TABLE IF NOT EXISTS config (
    key         TEXT PRIMARY KEY NOT NULL,
    value       TEXT NOT NULL,
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS scans (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    tenant_id           TEXT NOT NULL DEFAULT '',
    tenant_domain       TEXT NOT NULL DEFAULT '',
    status              TEXT NOT NULL DEFAULT 'Pending',     -- Pending, Running, Completed, Failed, Cancelled
    scan_types          TEXT NOT NULL DEFAULT '',             -- Comma-separated
    started_at          TEXT NOT NULL DEFAULT '',
    completed_at        TEXT NOT NULL DEFAULT '',
    started_by          TEXT NOT NULL DEFAULT '',
    total_permissions   INTEGER NOT NULL DEFAULT 0,
    config_snapshot     TEXT NOT NULL DEFAULT '{}',
    error_message       TEXT NOT NULL DEFAULT '',
    module_version      TEXT NOT NULL DEFAULT '',
    notes               TEXT NOT NULL DEFAULT '',
    tags                TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS permissions (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_id             INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
    category            TEXT NOT NULL DEFAULT '',
    target_path         TEXT NOT NULL DEFAULT '',
    target_type         TEXT NOT NULL DEFAULT '',
    target_id           TEXT NOT NULL DEFAULT '',
    principal_entra_id  TEXT NOT NULL DEFAULT '',
    principal_entra_upn TEXT NOT NULL DEFAULT '',
    principal_sys_id    TEXT NOT NULL DEFAULT '',
    principal_sys_name  TEXT NOT NULL DEFAULT '',
    principal_type      TEXT NOT NULL DEFAULT '',
    principal_role      TEXT NOT NULL DEFAULT '',
    through             TEXT NOT NULL DEFAULT '',
    access_type         TEXT NOT NULL DEFAULT 'Allow',
    tenure              TEXT NOT NULL DEFAULT 'Permanent',
    parent_id           TEXT NOT NULL DEFAULT '',
    start_date_time     TEXT NOT NULL DEFAULT '',
    end_date_time       TEXT NOT NULL DEFAULT '',
    created_date_time   TEXT NOT NULL DEFAULT '',
    modified_date_time  TEXT NOT NULL DEFAULT '',
    risk_level          TEXT NOT NULL DEFAULT '',
    risk_reason         TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_permissions_scan_id ON permissions(scan_id);
CREATE INDEX IF NOT EXISTS idx_permissions_category ON permissions(scan_id, category);
CREATE INDEX IF NOT EXISTS idx_permissions_principal ON permissions(scan_id, principal_entra_id);
CREATE INDEX IF NOT EXISTS idx_permissions_target ON permissions(scan_id, target_path);
-- idx_permissions_risk is created in ApplyMigrations (after risk_level column is guaranteed to exist)

CREATE TABLE IF NOT EXISTS scan_progress (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_id             INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
    category            TEXT NOT NULL DEFAULT '',
    total_targets       INTEGER NOT NULL DEFAULT 0,
    completed_targets   INTEGER NOT NULL DEFAULT 0,
    failed_targets      INTEGER NOT NULL DEFAULT 0,
    permissions_found   INTEGER NOT NULL DEFAULT 0,
    current_target      TEXT NOT NULL DEFAULT '',
    status              TEXT NOT NULL DEFAULT 'Pending',
    started_at          TEXT NOT NULL DEFAULT '',
    UNIQUE(scan_id, category)
);

CREATE TABLE IF NOT EXISTS comparisons (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    old_scan_id         INTEGER NOT NULL REFERENCES scans(id),
    new_scan_id         INTEGER NOT NULL REFERENCES scans(id),
    created_at          TEXT NOT NULL DEFAULT (datetime('now')),
    added_count         INTEGER NOT NULL DEFAULT 0,
    removed_count       INTEGER NOT NULL DEFAULT 0,
    changed_count       INTEGER NOT NULL DEFAULT 0,
    result_json         TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS logs (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_id             INTEGER,
    level               INTEGER NOT NULL DEFAULT 3,          -- 0=Critical, 1=Error, 2=Warning, 3=Info, 4=Verbose, 5=Debug
    message             TEXT NOT NULL DEFAULT '',
    category            TEXT NOT NULL DEFAULT '',
    timestamp           TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_logs_scan_id ON logs(scan_id);
CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON logs(timestamp);

CREATE TABLE IF NOT EXISTS audit_log (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    action              TEXT NOT NULL DEFAULT '',               -- ScanStarted, ScanCompleted, ConfigChanged, Export, Compare, etc.
    user_name           TEXT NOT NULL DEFAULT '',
    details             TEXT NOT NULL DEFAULT '',               -- JSON or free text with details
    scan_id             INTEGER,
    timestamp           TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_log(timestamp);
CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_log(action);

CREATE TABLE IF NOT EXISTS policies (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    name                TEXT NOT NULL DEFAULT '',
    description         TEXT NOT NULL DEFAULT '',
    enabled             INTEGER NOT NULL DEFAULT 1,
    severity            TEXT NOT NULL DEFAULT 'High',          -- Critical, High, Medium, Low, Info
    category_filter     TEXT NOT NULL DEFAULT '',               -- Empty = all categories, or e.g. "SharePoint,Entra"
    conditions          TEXT NOT NULL DEFAULT '[]',             -- JSON array of {field, operator, value} conditions (AND)
    is_default          INTEGER NOT NULL DEFAULT 0,            -- 1 = pre-seeded default policy
    created_at          TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at          TEXT NOT NULL DEFAULT (datetime('now'))
);
