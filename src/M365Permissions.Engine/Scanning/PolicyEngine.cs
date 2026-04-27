using System.Text.RegularExpressions;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Evaluates permission entries against policy rules (multi-condition AND logic).
/// Used for both risk classification and compliance flagging.
/// </summary>
public static class PolicyEngine
{
    // Map policy field names to PermissionEntry property accessor
    private static readonly Dictionary<string, Func<PermissionEntry, string>> FieldAccessors = new(StringComparer.OrdinalIgnoreCase)
    {
        ["category"] = e => e.Category,
        ["target_path"] = e => e.TargetPath,
        ["target_type"] = e => e.TargetType,
        ["target_id"] = e => e.TargetId,
        ["principal_entra_id"] = e => e.PrincipalEntraId,
        ["principal_entra_upn"] = e => e.PrincipalEntraUpn,
        ["principal_sys_id"] = e => e.PrincipalSysId,
        ["principal_sys_name"] = e => e.PrincipalSysName,
        ["principal_type"] = e => e.PrincipalType,
        ["principal_role"] = e => e.PrincipalRole,
        ["through"] = e => e.Through,
        ["access_type"] = e => e.AccessType,
        ["tenure"] = e => e.Tenure,
    };

    // Severity ordering: higher number = more severe
    private static readonly Dictionary<string, int> SeverityOrder = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Info"] = 0, ["Low"] = 1, ["Medium"] = 2, ["High"] = 3, ["Critical"] = 4
    };

    /// <summary>
    /// Classify a single permission entry: evaluate all enabled policies, pick highest severity.
    /// Sets entry.RiskLevel and entry.RiskReason. Falls back to "Info" / "No policy matched" if no match.
    /// </summary>
    public static void Classify(PermissionEntry entry, IReadOnlyList<Policy> policies)
    {
        string bestSeverity = "Info";
        string bestReason = "No specific risk identified";
        int bestOrder = -1;

        foreach (var policy in policies)
        {
            if (!policy.Enabled) continue;

            // Check category filter
            if (!string.IsNullOrEmpty(policy.CategoryFilter))
            {
                var categories = policy.CategoryFilter.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                if (!categories.Any(c => c.Equals(entry.Category, StringComparison.OrdinalIgnoreCase)))
                    continue;
            }

            // All conditions must match (AND logic)
            if (policy.Conditions.Count == 0) continue;

            bool allMatch = true;
            foreach (var cond in policy.Conditions)
            {
                if (!FieldAccessors.TryGetValue(cond.Field, out var accessor))
                {
                    allMatch = false;
                    break;
                }
                if (!Matches(accessor(entry), cond.Operator, cond.Value))
                {
                    allMatch = false;
                    break;
                }
            }

            if (!allMatch) continue;

            // This policy matches — check if it's higher severity
            var order = SeverityOrder.GetValueOrDefault(policy.Severity, 1);
            if (order > bestOrder)
            {
                bestOrder = order;
                bestSeverity = policy.Severity;
                bestReason = policy.Name;
                if (!string.IsNullOrEmpty(policy.Description))
                    bestReason = policy.Description;
            }
        }

        entry.RiskLevel = bestSeverity;
        entry.RiskReason = bestReason;
    }

    /// <summary>
    /// Classify a batch of permission entries using policy rules.
    /// </summary>
    public static void ClassifyBatch(IReadOnlyList<PermissionEntry> entries, IReadOnlyList<Policy> policies)
    {
        foreach (var entry in entries) Classify(entry, policies);
    }

    /// <summary>
    /// Evaluate a single permission entry against all enabled policies.
    /// Returns list of matching policy violations (empty if none).
    /// </summary>
    public static List<PolicyViolation> Evaluate(PermissionEntry entry, IReadOnlyList<Policy> policies)
    {
        var violations = new List<PolicyViolation>();

        foreach (var policy in policies)
        {
            if (!policy.Enabled) continue;

            // Check category filter
            if (!string.IsNullOrEmpty(policy.CategoryFilter))
            {
                var categories = policy.CategoryFilter.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                if (!categories.Any(c => c.Equals(entry.Category, StringComparison.OrdinalIgnoreCase)))
                    continue;
            }

            if (policy.Conditions.Count == 0) continue;

            bool allMatch = true;
            foreach (var cond in policy.Conditions)
            {
                if (!FieldAccessors.TryGetValue(cond.Field, out var accessor))
                {
                    allMatch = false;
                    break;
                }
                if (!Matches(accessor(entry), cond.Operator, cond.Value))
                {
                    allMatch = false;
                    break;
                }
            }

            if (allMatch)
            {
                violations.Add(new PolicyViolation
                {
                    PolicyId = policy.Id,
                    PolicyName = policy.Name,
                    Severity = policy.Severity,
                    Description = policy.Description
                });
            }
        }

        return violations;
    }

    /// <summary>
    /// Evaluate a batch of entries. Returns a dictionary of entry index → violations.
    /// Only entries with violations are included.
    /// </summary>
    public static Dictionary<int, List<PolicyViolation>> EvaluateBatch(
        IReadOnlyList<PermissionEntry> entries, IReadOnlyList<Policy> policies)
    {
        var results = new Dictionary<int, List<PolicyViolation>>();
        for (int i = 0; i < entries.Count; i++)
        {
            var violations = Evaluate(entries[i], policies);
            if (violations.Count > 0)
                results[i] = violations;
        }
        return results;
    }

    private static bool Matches(string fieldValue, string op, string pattern)
    {
        return op.ToLower() switch
        {
            "equals" => fieldValue.Equals(pattern, StringComparison.OrdinalIgnoreCase),
            "notequals" => !fieldValue.Equals(pattern, StringComparison.OrdinalIgnoreCase),
            "contains" => fieldValue.Contains(pattern, StringComparison.OrdinalIgnoreCase),
            "notcontains" => !fieldValue.Contains(pattern, StringComparison.OrdinalIgnoreCase),
            "startswith" => fieldValue.StartsWith(pattern, StringComparison.OrdinalIgnoreCase),
            "regex" => TryRegexMatch(fieldValue, pattern),
            _ => false
        };
    }

    private static bool TryRegexMatch(string input, string pattern)
    {
        try
        {
            return Regex.IsMatch(input, pattern, RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
        }
        catch
        {
            return false;
        }
    }
}
