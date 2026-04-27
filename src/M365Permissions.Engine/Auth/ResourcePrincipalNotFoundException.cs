namespace M365Permissions.Engine.Auth;

/// <summary>
/// Thrown when a token can't be acquired because the requested resource's
/// service principal is not provisioned in the user's tenant.
/// Typically AADSTS500011 (resource principal named X was not found in the tenant)
/// or AADSTS650057 (invalid resource). The scanner that depends on this resource
/// should be skipped, but other scans should continue.
/// </summary>
public sealed class ResourcePrincipalNotFoundException : Exception
{
    public string Resource { get; }
    public string? AadErrorCode { get; }

    public ResourcePrincipalNotFoundException(string resource, string? aadErrorCode, string message)
        : base(message)
    {
        Resource = resource;
        AadErrorCode = aadErrorCode;
    }
}
