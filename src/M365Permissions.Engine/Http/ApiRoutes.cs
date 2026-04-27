using System.Text.Json;
using M365Permissions.Engine.Graph;
using M365Permissions.Engine.Models;
using M365Permissions.Engine.Scanning;

namespace M365Permissions.Engine.Http;

/// <summary>
/// Registers all REST API routes on the WebServer.
/// Each route delegates to the Engine facade for actual logic.
/// </summary>
public static class ApiRoutes
{
    public static void Register(WebServer server, Engine engine)
    {
        // ── Status ──────────────────────────────────────────────
        server.Route("GET", "/api/status", async (ctx, _) =>
        {
            await engine.EnsureSessionRestoredAsync();
            var status = engine.GetStatus();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse<StatusResponse>.Ok(status));
        });

        // ── Authentication ──────────────────────────────────────
        server.Route("POST", "/api/connect", async (ctx, _) =>
        {
            try
            {
                await engine.ConnectAsync();
                var status = engine.GetStatus();
                await WebServer.WriteJson(ctx.Response, 200, ApiResponse<StatusResponse>.Ok(status));
            }
            catch (Exception ex)
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail(ex.Message));
            }
        });

        server.Route("POST", "/api/disconnect", async (ctx, _) =>
        {
            engine.Disconnect();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok());
        });

        server.Route("POST", "/api/reconsent", async (ctx, _) =>
        {
            try
            {
                await engine.ReconsentAsync();
                var status = engine.GetStatus();
                await WebServer.WriteJson(ctx.Response, 200, ApiResponse<StatusResponse>.Ok(status));
            }
            catch (Exception ex)
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail(ex.Message));
            }
        });

        // ── Configuration ───────────────────────────────────────
        server.Route("GET", "/api/config", async (ctx, _) =>
        {
            var config = engine.GetConfig();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse<AppConfig>.Ok(config));
        });

        server.Route("PUT", "/api/config", async (ctx, _) =>
        {
            var update = await WebServer.ReadJson<Dictionary<string, JsonElement>>(ctx.Request);
            if (update == null)
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid request body"));
                return;
            }
            engine.UpdateConfig(update);
            var config = engine.GetConfig();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse<AppConfig>.Ok(config));
        });

        // ── Scanning ────────────────────────────────────────────
        server.Route("POST", "/api/scan/start", async (ctx, _) =>
        {
            var request = await WebServer.ReadJson<ScanStartRequest>(ctx.Request);
            if (request?.ScanTypes == null || request.ScanTypes.Count == 0)
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Specify at least one scan type"));
                return;
            }

            try
            {
                var scanId = await engine.StartScanAsync(request.ScanTypes);
                await WebServer.WriteJson(ctx.Response, 200,
                    ApiResponse<object>.Ok(new { scanId }));
            }
            catch (InvalidOperationException ex)
            {
                await WebServer.WriteJson(ctx.Response, 409, ApiResponse.Fail(ex.Message));
            }
        });

        server.Route("GET", "/api/scan/progress", async (ctx, _) =>
        {
            var progress = engine.GetScanProgress();
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<AggregatedProgress?>.Ok(progress));
        });

        server.Route("POST", "/api/scan/cancel", async (ctx, _) =>
        {
            engine.CancelScan();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok());
        });

        server.Route("GET", "/api/scan/throttle", async (ctx, _) =>
        {
            var metrics = engine.GetThrottleMetrics();
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<ThrottleMetrics?>.Ok(metrics));
        });

        server.Route("POST", "/api/scan/precheck", async (ctx, _) =>
        {
            var body = await WebServer.ReadJson<JsonElement>(ctx.Request);
            var scanTypes = new List<string>();
            if (body.TryGetProperty("scanTypes", out var st) && st.ValueKind == JsonValueKind.Array)
            {
                foreach (var t in st.EnumerateArray())
                    if (t.GetString() is string s) scanTypes.Add(s);
            }

            if (scanTypes.Count == 0)
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("No scan types specified"));
                return;
            }

            var results = await engine.CheckPermissionsAsync(scanTypes);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<Dictionary<string, List<string>>>.Ok(results));
        });

        // ── Scan Results ────────────────────────────────────────
        server.Route("GET", "/api/scans", async (ctx, _) =>
        {
            var tenantId = ctx.Request.QueryString["tenantId"];
            var scans = engine.GetScans(tenantId);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<List<ScanInfo>>.Ok(scans));
        });

        server.Route("GET", "/api/scans/:id/categories", async (ctx, p) =>
        {
            if (!long.TryParse(p.GetValueOrDefault("id"), out var scanId))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID"));
                return;
            }
            var categories = engine.GetCategories(scanId);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<List<string>>.Ok(categories));
        });

        server.Route("GET", "/api/scans/:id/results", async (ctx, p) =>
        {
            if (!long.TryParse(p.GetValueOrDefault("id"), out var scanId))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID"));
                return;
            }

            var qs = ctx.Request.QueryString;
            var category = qs["category"];
            var search = qs["search"];
            int.TryParse(qs["page"], out var page); if (page < 1) page = 1;
            int.TryParse(qs["pageSize"], out var pageSize); if (pageSize < 1) pageSize = 100;
            var sortColumn = qs["sortColumn"];
            var sortDirection = qs["sortDirection"];

            // Column filters: f_target_type=Site|List, f_access_type=Allow, etc.
            var columnFilters = new Dictionary<string, string>();
            foreach (string? key in qs.AllKeys)
            {
                if (key != null && key.StartsWith("f_", StringComparison.Ordinal))
                {
                    var col = key[2..]; // strip "f_" prefix
                    var val = qs[key];
                    if (!string.IsNullOrEmpty(val))
                        columnFilters[col] = val;
                }
            }

            var results = engine.QueryPermissions(scanId, category, search, page, pageSize,
                sortColumn, sortDirection, columnFilters.Count > 0 ? columnFilters : null);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<PagedResult<PermissionEntry>>.Ok(results));
        });

        server.Route("GET", "/api/scans/:id/export", async (ctx, p) =>
        {
            if (!long.TryParse(p.GetValueOrDefault("id"), out var scanId))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID"));
                return;
            }

            var format = ctx.Request.QueryString["format"] ?? "xlsx";
            var category = ctx.Request.QueryString["category"];

            try
            {
                var (bytes, fileName, contentType) = engine.ExportScan(scanId, format, category);
                ctx.Response.ContentType = contentType;
                ctx.Response.Headers.Add("Content-Disposition", $"attachment; filename=\"{fileName}\"");
                ctx.Response.ContentLength64 = bytes.Length;
                await ctx.Response.OutputStream.WriteAsync(bytes);
                ctx.Response.Close();
            }
            catch (KeyNotFoundException)
            {
                await WebServer.WriteJson(ctx.Response, 404, ApiResponse.Fail("Scan not found"));
            }
        });

        // ── User Permissions Lookup ─────────────────────────────
        server.Route("GET", "/api/scans/:id/user-permissions", async (ctx, p) =>
        {
            if (!long.TryParse(p.GetValueOrDefault("id"), out var scanId))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID"));
                return;
            }
            var qs = ctx.Request.QueryString;
            var user = qs["user"];
            if (string.IsNullOrWhiteSpace(user))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Specify a user search term"));
                return;
            }
            int.TryParse(qs["page"], out var page); if (page < 1) page = 1;
            int.TryParse(qs["pageSize"], out var pageSize); if (pageSize < 1) pageSize = 100;
            var sortColumn = qs["sortColumn"];
            var sortDirection = qs["sortDirection"];

            // Column filters: f_target_type=Site|List, f_access_type=Allow, etc.
            var columnFilters = new Dictionary<string, string>();
            foreach (string? key in qs.AllKeys)
            {
                if (key != null && key.StartsWith("f_", StringComparison.Ordinal))
                {
                    var col = key[2..];
                    var val = qs[key];
                    if (!string.IsNullOrEmpty(val))
                        columnFilters[col] = val;
                }
            }

            var results = engine.QueryUserPermissions(scanId, user, page, pageSize,
                sortColumn, sortDirection, columnFilters.Count > 0 ? columnFilters : null);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<PagedResult<PermissionEntry>>.Ok(results));
        });

        // ── Group Members Lookup ────────────────────────────────
        server.Route("GET", "/api/scans/:id/group-members", async (ctx, p) =>
        {
            if (!long.TryParse(p.GetValueOrDefault("id"), out var scanId))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID"));
                return;
            }
            var groupId = ctx.Request.QueryString["groupId"];
            if (string.IsNullOrWhiteSpace(groupId))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Specify groupId"));
                return;
            }
            var members = engine.GetGroupMembers(scanId, groupId);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<List<PermissionEntry>>.Ok(members));
        });

        // ── Filter Options ──────────────────────────────────────
        server.Route("GET", "/api/scans/:id/filter-options", async (ctx, p) =>
        {
            if (!long.TryParse(p.GetValueOrDefault("id"), out var scanId))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID"));
                return;
            }
            var column = ctx.Request.QueryString["column"];
            var category = ctx.Request.QueryString["category"];
            if (string.IsNullOrWhiteSpace(column))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Specify column"));
                return;
            }
            var values = engine.GetFilterOptions(scanId, column, category);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<List<string>>.Ok(values));
        });

        // ── Comparison ──────────────────────────────────────────
        server.Route("POST", "/api/compare", async (ctx, _) =>
        {
            var request = await WebServer.ReadJson<CompareRequest>(ctx.Request);
            if (request == null || request.OldScanId <= 0 || request.NewScanId <= 0)
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Specify oldScanId and newScanId"));
                return;
            }

            var result = engine.CompareScans(request.OldScanId, request.NewScanId, request.Category);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<ComparisonResult>.Ok(result));
        });

        // ── Comparison Export ───────────────────────────────────
        server.Route("POST", "/api/compare/export", async (ctx, _) =>
        {
            var request = await WebServer.ReadJson<CompareRequest>(ctx.Request);
            if (request == null || request.OldScanId <= 0 || request.NewScanId <= 0)
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Specify oldScanId and newScanId"));
                return;
            }

            var (bytes, fileName, contentType) = engine.ExportComparison(request.OldScanId, request.NewScanId, request.Category);
            ctx.Response.ContentType = contentType;
            ctx.Response.Headers.Add("Content-Disposition", $"attachment; filename=\"{fileName}\"");
            ctx.Response.ContentLength64 = bytes.Length;
            await ctx.Response.OutputStream.WriteAsync(bytes);
            ctx.Response.Close();
        });

        // ── Risk Summary ────────────────────────────────────────
        server.Route("GET", "/api/scans/:id/risk-summary", async (ctx, p) =>
        {
            if (!long.TryParse(p.GetValueOrDefault("id"), out var scanId))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID"));
                return;
            }
            var summary = engine.GetRiskSummary(scanId);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<Dictionary<string, int>>.Ok(summary));
        });

        // ── Scan Notes & Tags ───────────────────────────────────
        server.Route("PUT", "/api/scans/:id", async (ctx, p) =>
        {
            if (!long.TryParse(p.GetValueOrDefault("id"), out var scanId))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID"));
                return;
            }
            var body = await WebServer.ReadJson<JsonElement>(ctx.Request);
            string? notes = null, tags = null;
            if (body.TryGetProperty("notes", out var n)) notes = n.GetString();
            if (body.TryGetProperty("tags", out var t)) tags = t.GetString();

            engine.UpdateScanNotes(scanId, notes, tags);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok());
        });

        // ── Trends ──────────────────────────────────────────────
        server.Route("GET", "/api/trends", async (ctx, _) =>
        {
            int.TryParse(ctx.Request.QueryString["limit"], out var limit);
            if (limit < 1) limit = 20;
            var tenantId = ctx.Request.QueryString["tenantId"];
            var trends = engine.GetTrends(limit, tenantId);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<List<TrendDataPoint>>.Ok(trends));
        });

        // ── User Count ───────────────────────────────────────────
        server.Route("GET", "/api/user-count", async (ctx, _) =>
        {
            var info = await engine.GetUserCountAsync();
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<UserCountInfo?>.Ok(info));
        });

        // ── Audit Log ───────────────────────────────────────────
        server.Route("GET", "/api/audit", async (ctx, _) =>
        {
            int.TryParse(ctx.Request.QueryString["limit"], out var limit);
            if (limit < 1) limit = 100;
            var action = ctx.Request.QueryString["action"];
            var tenantId = ctx.Request.QueryString["tenantId"];
            var entries = engine.GetAuditLog(limit, action, tenantId);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<List<AuditEntry>>.Ok(entries));
        });
        // ── Policies ────────────────────────────────────────────────
        server.Route("GET", "/api/policies", async (ctx, _) =>
        {
            var policies = engine.GetPolicies();
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<List<Policy>>.Ok(policies));
        });

        server.Route("POST", "/api/policies", async (ctx, _) =>
        {
            var policy = await WebServer.ReadJson<Policy>(ctx.Request);
            if (policy == null || string.IsNullOrWhiteSpace(policy.Name))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Name is required"));
                return;
            }
            var id = engine.CreatePolicy(policy);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<object>.Ok(new { id }));
        });

        server.Route("PUT", "/api/policies/:id", async (ctx, p) =>
        {
            if (!long.TryParse(p.GetValueOrDefault("id"), out var policyId))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid policy ID"));
                return;
            }
            var policy = await WebServer.ReadJson<Policy>(ctx.Request);
            if (policy == null)
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid request body"));
                return;
            }
            policy.Id = policyId;
            engine.UpdatePolicy(policy);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok());
        });

        server.Route("DELETE", "/api/policies/:id", async (ctx, p) =>
        {
            if (!long.TryParse(p.GetValueOrDefault("id"), out var policyId))
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid policy ID"));
                return;
            }
            engine.DeletePolicy(policyId);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok());
        });

        server.Route("POST", "/api/policies/evaluate", async (ctx, _) =>
        {
            var body = await WebServer.ReadJson<JsonElement>(ctx.Request);
            long scanId = 0;
            string? category = null;
            if (body.TryGetProperty("scanId", out var sid)) scanId = sid.GetInt64();
            if (body.TryGetProperty("category", out var cat)) category = cat.GetString();
            if (scanId <= 0)
            {
                await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Specify scanId"));
                return;
            }
            var result = engine.EvaluatePolicies(scanId, category);
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<PolicyEvaluationResult>.Ok(result));
        });

        server.Route("POST", "/api/policies/reset-defaults", async (ctx, _) =>
        {
            var count = engine.ResetDefaultPolicies();
            await WebServer.WriteJson(ctx.Response, 200,
                ApiResponse<object>.Ok(new { count, message = $"Reset {count} default policies" }));
        });

        // ── Database Management ─────────────────────────────────

        server.Route("GET", "/api/database", async (ctx, _) =>
        {
            var info = engine.GetDatabaseInfo();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse<DatabaseInfo>.Ok(info));
        });

        server.Route("POST", "/api/database/reset", async (ctx, _) =>
        {
            try
            {
                engine.ResetDatabase();
                await WebServer.WriteJson(ctx.Response, 200,
                    ApiResponse<object>.Ok(new { message = "Database reset successfully" }));
            }
            catch (InvalidOperationException ex)
            {
                await WebServer.WriteJson(ctx.Response, 409,
                    ApiResponse<object?>.Fail(ex.Message));
            }
        });
    }

    // ── Request DTOs ────────────────────────────────────────────
    private sealed class ScanStartRequest
    {
        public List<string> ScanTypes { get; set; } = new();
    }

    private sealed class CompareRequest
    {
        public long OldScanId { get; set; }
        public long NewScanId { get; set; }
        public string? Category { get; set; }
    }
}
