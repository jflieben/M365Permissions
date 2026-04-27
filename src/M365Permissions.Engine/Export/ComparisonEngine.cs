using M365Permissions.Engine.Database;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Export;

/// <summary>
/// Compares permissions between two scans.
/// Classifies changes as Added, Removed, or Changed.
/// </summary>
public sealed class ComparisonEngine
{
    private readonly PermissionRepository _permRepo;

    public ComparisonEngine(PermissionRepository permRepo)
    {
        _permRepo = permRepo;
    }

    /// <summary>
    /// Compare two scans and return the delta.
    /// Matching key: (category, target_path, principal_entra_id OR principal_sys_id, principal_role, through).
    /// </summary>
    public ComparisonResult Compare(long oldScanId, long newScanId, string? category = null)
    {
        var oldPerms = _permRepo.GetAll(oldScanId, category);
        var newPerms = _permRepo.GetAll(newScanId, category);

        var oldDict = BuildLookup(oldPerms);
        var newDict = BuildLookup(newPerms);

        var result = new ComparisonResult
        {
            OldScanId = oldScanId,
            NewScanId = newScanId
        };

        // Find added and changed
        foreach (var (key, newEntry) in newDict)
        {
            if (oldDict.TryGetValue(key, out var oldEntry))
            {
                var changedFields = GetChangedFields(oldEntry, newEntry);
                if (changedFields.Count > 0)
                {
                    result.Changed.Add(new PermissionChange
                    {
                        Old = oldEntry,
                        New = newEntry,
                        ChangedFields = changedFields
                    });
                }
            }
            else
            {
                result.Added.Add(newEntry);
            }
        }

        // Find removed
        foreach (var (key, oldEntry) in oldDict)
        {
            if (!newDict.ContainsKey(key))
                result.Removed.Add(oldEntry);
        }

        return result;
    }

    private static Dictionary<string, PermissionEntry> BuildLookup(List<PermissionEntry> entries)
    {
        var dict = new Dictionary<string, PermissionEntry>();
        foreach (var entry in entries)
        {
            var principalKey = !string.IsNullOrEmpty(entry.PrincipalEntraId)
                ? entry.PrincipalEntraId
                : entry.PrincipalSysId;
            var key = $"{entry.Category}|{entry.TargetPath}|{principalKey}|{entry.PrincipalRole}|{entry.Through}";

            dict.TryAdd(key, entry);
        }
        return dict;
    }

    private static List<string> GetChangedFields(PermissionEntry old, PermissionEntry new_)
    {
        var changes = new List<string>();

        if (old.AccessType != new_.AccessType) changes.Add("AccessType");
        if (old.Tenure != new_.Tenure) changes.Add("Tenure");
        if (old.PrincipalType != new_.PrincipalType) changes.Add("PrincipalType");
        if (old.PrincipalSysName != new_.PrincipalSysName) changes.Add("PrincipalSysName");
        if (old.PrincipalEntraUpn != new_.PrincipalEntraUpn) changes.Add("PrincipalEntraUpn");
        if (old.ParentId != new_.ParentId) changes.Add("ParentId");
        if (old.StartDateTime != new_.StartDateTime) changes.Add("StartDateTime");
        if (old.EndDateTime != new_.EndDateTime) changes.Add("EndDateTime");

        return changes;
    }
}
