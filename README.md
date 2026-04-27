# M365Permissions

A PowerShell module that scans and reports on Microsoft 365 permissions across **SharePoint**, **Entra ID**, **Exchange Online**, **OneDrive**, **Power BI**, **Power Platform**, **Azure RBAC**, and **Azure DevOps**.

Built on a compiled .NET 8 engine with embedded SQLite database and web-based GUI. Zero external PowerShell module dependencies — everything is bundled.

## Features

- **360° permission visibility** across SharePoint, Entra ID, Exchange, OneDrive, Power BI, Power Platform, Azure RBAC, and Azure DevOps
- **Web GUI** — opens automatically on module import with dashboard, scan progress, results viewer, comparison tool
- **SQLite storage** — paginated queries, cross-scan comparison, persistent scan history
- **Excel/CSV export** — styled XLSX with ClosedXML or UTF-8 CSV
- **Scan comparison** — detect added, removed, and changed permissions between scans
- **Delegated auth** — secure browser-based OAuth2 PKCE flow, no client secrets needed
- **Lightweight** — no PnP.PowerShell, no Pode, no ImportExcel dependencies
- **Cross-platform** — runs on Windows, macOS, Linux (PowerShell 7.4+)

## Installation

```powershell
Install-PSResource -Name M365Permissions -Repository PSGallery
```

## Quick Start

```powershell
# Import module — the GUI opens automatically in your browser
Import-Module M365Permissions
```

Everything happens in the browser: connect to a tenant, configure scans, view results, export reports, and compare scans. You can scan multiple tenants by disconnecting from one and connecting to another — each scan records which tenant it belongs to.

## GUI

The web GUI starts automatically at `http://localhost:8080` when you import the module.

| Page | Description |
|------|-------------|
| Dashboard | Connection status, token expiry, recent scans (with tenant), risk summary, scan comparison delta |
| Scan | Select scan types, start/cancel scans, live progress |
| Results | Paginated results with category/search filters, risk levels, column picker, quick filters |
| Compare | Side-by-side scan comparison with added/removed/changed detection |
| Trends | Permission trend chart with tenant filter for multi-tenant tracking |
| Policies | Risk policy editor with custom conditions per permission field |
| Audit | Action log (scans, exports, config changes) |
| Settings | Port, threads, output format, log level, database management |

## Multi-Tenant Support

The module can scan different tenants in sequence. Each scan stores the tenant domain so you can:
- See which tenant each scan belongs to in results, comparisons, and the dashboard
- Filter trends by tenant to track permission changes per tenant over time
- Auto-compare only compares scans from the same tenant

To switch tenants, use the disconnect button (⏏) in the navigation bar or dashboard, then connect to a different tenant.

## Configuration

Settings are managed through the GUI's Settings page and stored in `%APPDATA%/LiebenConsultancy/M365Permissions/`:

| Setting | Default | Description |
|---------|---------|-------------|
| `GuiPort` | 8080 | Web GUI TCP port |
| `MaxThreads` | 5 | Parallel scan threads |
| `OutputFormat` | XLSX | Default export format |
| `LogLevel` | Minimal | Logging verbosity |
| `DefaultTimeoutMinutes` | 120 | Scan timeout |

## Scan Coverage

### SharePoint
- Site collection administrators
- Role assignments (permissions inherited and unique)
- Graph site permissions (app-only access)
- Drive/item permissions (sharing links, direct grants)

### Entra ID
- Directory role memberships
- App registration API permissions (requiredResourceAccess)
- OAuth2 permission grants (delegated consent)
- Group memberships

### Exchange Online
- Mailbox permissions (FullAccess)
- Recipient permissions (SendAs)
- SendOnBehalf grants

### OneDrive for Business
- OneDrive site administrators
- Sharing permissions on personal sites
- External sharing configuration

### Power BI
- Workspace role assignments (Admin, Member, Contributor, Viewer)
- Workspace ownership

### Power Platform
- Environment role assignments
- Power Automate flow ownership and sharing
- Power Apps ownership and sharing
- Custom connector permissions

### Azure RBAC
- Subscription-level role assignments
- Resource group-level role assignments

### Azure DevOps
- Organization membership enumeration (delegated auth only)
- Project-level security group memberships (Contributors, Readers, Project Administrators, etc.)
- Organization-level group memberships (Project Collection Administrators, etc.)
- User and group resolution across organizations

## License

Free for non-commercial use. See [LICENSE](LICENSE) for details.

Commercial use: https://www.lieben.nu/liebensraum/commercial-use/

Enterprise version: https://www.m365permissions.com
