using System.Text;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Export;

/// <summary>
/// Exports permission entries to CSV format.
/// </summary>
public sealed class CsvExporter
{
    public byte[] Export(IReadOnlyList<PermissionEntry> entries)
    {
        var sb = new StringBuilder();

        // Header
        sb.AppendLine(string.Join(",",
            "Risk Level", "Risk Reason",
            "Target Path", "Target Type", "Target ID",
            "Principal Entra ID", "Principal UPN", "Principal System ID", "Principal Name",
            "Principal Type", "Role", "Through", "Access Type", "Tenure",
            "Parent ID", "Start Date", "End Date", "Created", "Modified"));

        // Rows
        foreach (var e in entries)
        {
            sb.AppendLine(string.Join(",",
                Escape(e.RiskLevel), Escape(e.RiskReason),
                Escape(e.TargetPath), Escape(e.TargetType), Escape(e.TargetId),
                Escape(e.PrincipalEntraId), Escape(e.PrincipalEntraUpn),
                Escape(e.PrincipalSysId), Escape(e.PrincipalSysName),
                Escape(e.PrincipalType), Escape(e.PrincipalRole),
                Escape(e.Through), Escape(e.AccessType), Escape(e.Tenure),
                Escape(e.ParentId), Escape(e.StartDateTime),
                Escape(e.EndDateTime), Escape(e.CreatedDateTime),
                Escape(e.ModifiedDateTime)));
        }

        return Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(sb.ToString())).ToArray();
    }

    private static string Escape(string value)
    {
        if (string.IsNullOrEmpty(value)) return "\"\"";
        if (value.Contains('"') || value.Contains(',') || value.Contains('\n') || value.Contains('\r'))
            return $"\"{value.Replace("\"", "\"\"")}\"";
        return $"\"{value}\"";
    }
}
