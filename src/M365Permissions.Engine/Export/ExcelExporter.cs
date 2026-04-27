using ClosedXML.Excel;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Export;

/// <summary>
/// Exports permission entries to XLSX format using ClosedXML.
/// Replaces V1's ImportExcel dependency.
/// </summary>
public sealed class ExcelExporter
{
    /// <summary>
    /// Generate an XLSX workbook from permission entries.
    /// Returns the file as a byte array.
    /// </summary>
    public byte[] Export(IReadOnlyList<PermissionEntry> entries, string sheetName = "Permissions")
    {
        using var workbook = new XLWorkbook();
        var worksheet = workbook.Worksheets.Add(sheetName);

        // Headers
        var headers = new[]
        {
            "Risk Level", "Risk Reason",
            "Target Path", "Target Type", "Target ID",
            "Principal (Entra ID)", "Principal (UPN)", "Principal (System ID)", "Principal Name",
            "Principal Type", "Role", "Through", "Access Type", "Tenure",
            "Parent ID", "Start Date", "End Date", "Created", "Modified"
        };

        for (int col = 0; col < headers.Length; col++)
        {
            worksheet.Cell(1, col + 1).Value = headers[col];
            worksheet.Cell(1, col + 1).Style.Font.Bold = true;
            worksheet.Cell(1, col + 1).Style.Fill.BackgroundColor = XLColor.FromArgb(0, 172, 215);
            worksheet.Cell(1, col + 1).Style.Font.FontColor = XLColor.White;
        }

        // Data rows
        for (int row = 0; row < entries.Count; row++)
        {
            var e = entries[row];
            var r = row + 2;
            worksheet.Cell(r, 1).Value = e.RiskLevel;
            worksheet.Cell(r, 2).Value = e.RiskReason;
            worksheet.Cell(r, 3).Value = e.TargetPath;
            worksheet.Cell(r, 4).Value = e.TargetType;
            worksheet.Cell(r, 5).Value = e.TargetId;
            worksheet.Cell(r, 6).Value = e.PrincipalEntraId;
            worksheet.Cell(r, 7).Value = e.PrincipalEntraUpn;
            worksheet.Cell(r, 8).Value = e.PrincipalSysId;
            worksheet.Cell(r, 9).Value = e.PrincipalSysName;
            worksheet.Cell(r, 10).Value = e.PrincipalType;
            worksheet.Cell(r, 11).Value = e.PrincipalRole;
            worksheet.Cell(r, 12).Value = e.Through;
            worksheet.Cell(r, 13).Value = e.AccessType;
            worksheet.Cell(r, 14).Value = e.Tenure;
            worksheet.Cell(r, 15).Value = e.ParentId;
            worksheet.Cell(r, 16).Value = e.StartDateTime;
            worksheet.Cell(r, 17).Value = e.EndDateTime;
            worksheet.Cell(r, 18).Value = e.CreatedDateTime;
            worksheet.Cell(r, 19).Value = e.ModifiedDateTime;

            // Risk-level color coding
            ApplyRiskColor(worksheet.Cell(r, 1), e.RiskLevel);
        }

        // Auto-fit columns
        worksheet.Columns().AdjustToContents(1, Math.Min(entries.Count + 1, 100));

        // Freeze header row
        worksheet.SheetView.FreezeRows(1);

        // Auto-filter
        if (entries.Count > 0)
            worksheet.RangeUsed()?.SetAutoFilter();

        using var ms = new MemoryStream();
        workbook.SaveAs(ms);
        return ms.ToArray();
    }

    /// <summary>
    /// Export a comparison result with Added / Removed / Changed sheets.
    /// </summary>
    public byte[] ExportComparison(ComparisonResult result)
    {
        using var workbook = new XLWorkbook();

        WriteComparisonSheet(workbook, "Added", result.Added);
        WriteComparisonSheet(workbook, "Removed", result.Removed);
        WriteChangedSheet(workbook, result.Changed);
        WriteSummarySheet(workbook, result);

        // Move Summary to front
        var summarySheet = workbook.Worksheet("Summary");
        summarySheet.Position = 1;

        using var ms = new MemoryStream();
        workbook.SaveAs(ms);
        return ms.ToArray();
    }

    private static void WriteComparisonSheet(XLWorkbook workbook, string name, IReadOnlyList<PermissionEntry> entries)
    {
        var ws = workbook.Worksheets.Add(name);
        var headers = new[] { "Risk Level", "Category", "Target Path", "Principal UPN", "Principal Name", "Role", "Through", "Access Type", "Tenure" };
        for (int c = 0; c < headers.Length; c++)
        {
            ws.Cell(1, c + 1).Value = headers[c];
            ws.Cell(1, c + 1).Style.Font.Bold = true;
            ws.Cell(1, c + 1).Style.Fill.BackgroundColor = name == "Added" ? XLColor.FromArgb(76, 175, 80) : XLColor.FromArgb(244, 67, 54);
            ws.Cell(1, c + 1).Style.Font.FontColor = XLColor.White;
        }
        for (int r = 0; r < entries.Count; r++)
        {
            var e = entries[r];
            var row = r + 2;
            ws.Cell(row, 1).Value = e.RiskLevel;
            ApplyRiskColor(ws.Cell(row, 1), e.RiskLevel);
            ws.Cell(row, 2).Value = e.Category;
            ws.Cell(row, 3).Value = e.TargetPath;
            ws.Cell(row, 4).Value = e.PrincipalEntraUpn;
            ws.Cell(row, 5).Value = e.PrincipalSysName;
            ws.Cell(row, 6).Value = e.PrincipalRole;
            ws.Cell(row, 7).Value = e.Through;
            ws.Cell(row, 8).Value = e.AccessType;
            ws.Cell(row, 9).Value = e.Tenure;
        }
        ws.Columns().AdjustToContents(1, Math.Min(entries.Count + 1, 100));
        ws.SheetView.FreezeRows(1);
        if (entries.Count > 0) ws.RangeUsed()?.SetAutoFilter();
    }

    private static void WriteChangedSheet(XLWorkbook workbook, IReadOnlyList<PermissionChange> changes)
    {
        var ws = workbook.Worksheets.Add("Changed");
        var headers = new[] { "Category", "Target Path", "Principal UPN", "Field", "Old Value", "New Value" };
        for (int c = 0; c < headers.Length; c++)
        {
            ws.Cell(1, c + 1).Value = headers[c];
            ws.Cell(1, c + 1).Style.Font.Bold = true;
            ws.Cell(1, c + 1).Style.Fill.BackgroundColor = XLColor.FromArgb(255, 152, 0);
            ws.Cell(1, c + 1).Style.Font.FontColor = XLColor.White;
        }
        int row = 2;
        foreach (var change in changes)
        {
            foreach (var field in change.ChangedFields)
            {
                ws.Cell(row, 1).Value = change.Old.Category;
                ws.Cell(row, 2).Value = change.Old.TargetPath;
                ws.Cell(row, 3).Value = change.Old.PrincipalEntraUpn;
                ws.Cell(row, 4).Value = field;
                ws.Cell(row, 5).Value = GetFieldValue(change.Old, field);
                ws.Cell(row, 6).Value = GetFieldValue(change.New, field);
                row++;
            }
        }
        ws.Columns().AdjustToContents(1, Math.Min(row, 100));
        ws.SheetView.FreezeRows(1);
        if (row > 2) ws.RangeUsed()?.SetAutoFilter();
    }

    private static string GetFieldValue(PermissionEntry entry, string fieldName)
    {
        return fieldName switch
        {
            "PrincipalRole" => entry.PrincipalRole,
            "Through" => entry.Through,
            "AccessType" => entry.AccessType,
            "Tenure" => entry.Tenure,
            "RiskLevel" => entry.RiskLevel,
            "RiskReason" => entry.RiskReason,
            "PrincipalType" => entry.PrincipalType,
            "PrincipalEntraUpn" => entry.PrincipalEntraUpn,
            "PrincipalSysName" => entry.PrincipalSysName,
            "TargetType" => entry.TargetType,
            _ => fieldName
        };
    }

    private static void WriteSummarySheet(XLWorkbook workbook, ComparisonResult result)
    {
        var ws = workbook.Worksheets.Add("Summary");
        ws.Cell(1, 1).Value = "M365Permissions Comparison Summary";
        ws.Cell(1, 1).Style.Font.Bold = true;
        ws.Cell(1, 1).Style.Font.FontSize = 14;

        ws.Cell(3, 1).Value = "Metric";
        ws.Cell(3, 2).Value = "Count";
        ws.Cell(3, 1).Style.Font.Bold = true;
        ws.Cell(3, 2).Style.Font.Bold = true;

        ws.Cell(4, 1).Value = "Permissions Added";
        ws.Cell(4, 2).Value = result.Added.Count;
        ws.Cell(4, 2).Style.Font.FontColor = XLColor.FromArgb(76, 175, 80);

        ws.Cell(5, 1).Value = "Permissions Removed";
        ws.Cell(5, 2).Value = result.Removed.Count;
        ws.Cell(5, 2).Style.Font.FontColor = XLColor.FromArgb(244, 67, 54);

        ws.Cell(6, 1).Value = "Permissions Changed";
        ws.Cell(6, 2).Value = result.Changed.Count;
        ws.Cell(6, 2).Style.Font.FontColor = XLColor.FromArgb(255, 152, 0);

        ws.Columns().AdjustToContents();
    }

    private static void ApplyRiskColor(IXLCell cell, string riskLevel)
    {
        switch (riskLevel)
        {
            case "Critical":
                cell.Style.Fill.BackgroundColor = XLColor.FromArgb(183, 28, 28);
                cell.Style.Font.FontColor = XLColor.White;
                break;
            case "High":
                cell.Style.Fill.BackgroundColor = XLColor.FromArgb(244, 67, 54);
                cell.Style.Font.FontColor = XLColor.White;
                break;
            case "Medium":
                cell.Style.Fill.BackgroundColor = XLColor.FromArgb(255, 152, 0);
                cell.Style.Font.FontColor = XLColor.White;
                break;
            case "Low":
                cell.Style.Fill.BackgroundColor = XLColor.FromArgb(76, 175, 80);
                cell.Style.Font.FontColor = XLColor.White;
                break;
            case "Info":
                cell.Style.Fill.BackgroundColor = XLColor.FromArgb(33, 150, 243);
                cell.Style.Font.FontColor = XLColor.White;
                break;
        }
    }
}
