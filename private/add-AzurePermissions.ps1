function add-AzurePermissions{
    Param(
        [Parameter(Mandatory=$true)]$permission,
        [Parameter(Mandatory=$true)]$roleDefinitionsLookup,
        [Parameter(Mandatory=$true)]$targetPath,
        [Parameter(Mandatory=$true)]$targetType,
        [Parameter(Mandatory=$true)]$targetId,
        [Parameter(Mandatory=$false)]$tenure = "Permanent"
    )
    $roleDefinitionId = $permission.properties.roleDefinitionId.Split("/")[-1]
    if(!$roleDefinitionsLookup.$roleDefinitionId){
        Write-LogMessage -level 3 -message "Role /$($targetPath)/$roleDefinitionId not found in lookup hash, skipping"
        continue #role does not exist
    }
    $permissionSplat = @{
        targetPath = $targetPath
        targetType = $targetType
        targetId = $targetId
        principalEntraId = $permission.properties.principalId
        principalType = $permission.properties.principalType
        through = $roleDefinitionsLookup.$roleDefinitionId.properties.roleName
        tenure = $tenure
        startDateTime = $permission.properties.startDateTime
        endDateTime = $permission.properties.endDateTime
        createdDateTime = $permission.properties.createdOn
        modifiedDateTime = $permission.properties.updatedOn
    }
    foreach($action in $roleDefinitionsLookup.$roleDefinitionId.properties.permissions.actions){
        $permissionSplat.principalRole = $action
        $permissionSplat.accessType = "Allow"
        New-AzurePermissionEntry @permissionSplat
    }
    foreach($notAction in $roleDefinitionsLookup.$roleDefinitionId.properties.permissions.notActions){
        $permissionSplat.principalRole = $notAction
        $permissionSplat.accessType = "Deny"
        New-AzurePermissionEntry @permissionSplat
    }
    foreach($dataAction in $roleDefinitionsLookup.$roleDefinitionId.properties.permissions.dataActions){
        $permissionSplat.principalRole = $dataAction
        $permissionSplat.accessType = "Allow"
        New-AzurePermissionEntry @permissionSplat
    }
    foreach($notDataAction in $roleDefinitionsLookup.$roleDefinitionId.properties.permissions.notDataActions){
        $permissionSplat.principalRole = $notDataAction
        $permissionSplat.accessType = "Deny"
        New-AzurePermissionEntry @permissionSplat
    }
}