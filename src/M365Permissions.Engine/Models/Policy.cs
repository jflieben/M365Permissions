namespace M365Permissions.Engine.Models;

/// <summary>
/// A policy rule that flags permission entries matching a set of conditions (AND logic).
/// Used for both risk scoring and compliance flagging.
/// </summary>
public sealed class Policy
{
    public long Id { get; set; }
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public bool Enabled { get; set; } = true;
    public string Severity { get; set; } = "High";           // Critical, High, Medium, Low, Info
    public string CategoryFilter { get; set; } = "";          // Empty = all categories
    public bool IsDefault { get; set; }                       // True = pre-seeded, cannot be deleted via UI
    public List<PolicyCondition> Conditions { get; set; } = new(); // All conditions must match (AND)
    public string CreatedAt { get; set; } = "";
    public string UpdatedAt { get; set; } = "";
}

/// <summary>
/// A single condition within a policy rule.
/// </summary>
public sealed class PolicyCondition
{
    public string Field { get; set; } = "";                   // Column to match: principal_role, through, tenure, target_path, etc.
    public string Operator { get; set; } = "equals";          // equals, contains, startsWith, regex, notEquals, notContains
    public string Value { get; set; } = "";
}

/// <summary>
/// Result of evaluating a permission entry against all policies.
/// </summary>
public sealed class PolicyViolation
{
    public long PolicyId { get; set; }
    public string PolicyName { get; set; } = "";
    public string Severity { get; set; } = "";
    public string Description { get; set; } = "";
}

/// <summary>
/// Combined result of policy evaluation: violations keyed by entry index, plus the matching entries.
/// </summary>
public sealed class PolicyEvaluationResult
{
    public Dictionary<int, List<PolicyViolation>> Violations { get; set; } = new();
    public Dictionary<int, PermissionEntry> Entries { get; set; } = new();
}
