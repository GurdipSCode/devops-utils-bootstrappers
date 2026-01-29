# Multi-Platform Project Provisioning Script
# Creates namespaces in Vault, project in Lynx, and projects in Harbor - for Terraform Modules

param(
    [Parameter(Mandatory=$true)]
    [string]$Name,
    
    [Parameter(Mandatory=$true)]
    [string]$VaultModuleParentNamespace,
    
    [Parameter(Mandatory=$true)]
    [string]$VaultServiceParentNamespace,
    
    [Parameter(Mandatory=$false)]
    [string]$LynxEnvironmentName = "dev",
    
    [Parameter(Mandatory=$false)]
    [string]$VaultPolicyTemplate = @"
# Policy for {namespace}
path "secret/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/*" {
  capabilities = ["list", "read", "delete"]
}
"@,
    
    [Parameter(Mandatory=$false)]
    [string]$VaultAddr = $env:VAULT_ADDR,
    
    [Parameter(Mandatory=$false)]
    [string]$VaultToken = $env:VAULT_TOKEN,
    
    [Parameter(Mandatory=$false)]
    [string]$LynxUrl = $env:LYNX_URL,
    
    [Parameter(Mandatory=$false)]
    [string]$LynxToken = $env:LYNX_TOKEN,
    
    [Parameter(Mandatory=$false)]
    [string]$HarborUrl = $env:HARBOR_URL,
    
    [Parameter(Mandatory=$false)]
    [string]$HarborUsername = $env:HARBOR_USERNAME,
    
    [Parameter(Mandatory=$false)]
    [string]$HarborPassword = $env:HARBOR_PASSWORD,
    
    [Parameter(Mandatory=$false)]
    [string]$HarborRobotToken = $env:HARBOR_ROBOT_TOKEN,
    
    [Parameter(Mandatory=$false)]
    [string]$BuildkiteToken = $env:BUILDKITE_TOKEN,
    
    [Parameter(Mandatory=$false)]
    [string]$BuildkiteOrgSlug = $env:BUILDKITE_ORG_SLUG,
    
    [Parameter(Mandatory=$false)]
    [string]$BuildkiteClusterId = $env:BUILDKITE_CLUSTER_ID
)

# Error handling
$ErrorActionPreference = "Stop"

function Write-ColorOutput($ForegroundColor) {
    $fc = $host.UI.RawUI.ForegroundColor
    $host.UI.RawUI.ForegroundColor = $ForegroundColor
    if ($args) {
        Write-Output $args
    }
    $host.UI.RawUI.ForegroundColor = $fc
}

# Validate required parameters
function Test-Prerequisites {
    $valid = $true
    
    if ([string]::IsNullOrEmpty($VaultAddr)) {
        Write-ColorOutput Red "ERROR: Vault address not provided. Set VAULT_ADDR or use -VaultAddr"
        $valid = $false
    }
    
    if ([string]::IsNullOrEmpty($VaultToken)) {
        Write-ColorOutput Red "ERROR: Vault token not provided. Set VAULT_TOKEN or use -VaultToken"
        $valid = $false
    }
    
    if ([string]::IsNullOrEmpty($LynxUrl)) {
        Write-ColorOutput Red "ERROR: Lynx URL not provided. Set LYNX_URL or use -LynxUrl"
        $valid = $false
    }
    
    if ([string]::IsNullOrEmpty($LynxToken)) {
        Write-ColorOutput Red "ERROR: Lynx token not provided. Set LYNX_TOKEN or use -LynxToken"
        $valid = $false
    }
    
    if ([string]::IsNullOrEmpty($HarborUrl)) {
        Write-ColorOutput Red "ERROR: Harbor URL not provided. Set HARBOR_URL or use -HarborUrl"
        $valid = $false
    }
    
    # Check for either robot token OR username/password
    $hasRobotToken = -not [string]::IsNullOrEmpty($HarborRobotToken)
    $hasUserPass = -not [string]::IsNullOrEmpty($HarborUsername) -and -not [string]::IsNullOrEmpty($HarborPassword)
    
    if (-not $hasRobotToken -and -not $hasUserPass) {
        Write-ColorOutput Red "ERROR: Harbor authentication not provided. Either:"
        Write-ColorOutput Red "  - Set HARBOR_ROBOT_TOKEN or use -HarborRobotToken"
        Write-ColorOutput Red "  - Set HARBOR_USERNAME and HARBOR_PASSWORD or use -HarborUsername and -HarborPassword"
        $valid = $false
    }
    
    # Buildkite is optional - only validate if any Buildkite parameter is provided
    $buildkiteProvided = -not [string]::IsNullOrEmpty($BuildkiteToken) -or 
                         -not [string]::IsNullOrEmpty($BuildkiteOrgSlug) -or 
                         -not [string]::IsNullOrEmpty($BuildkiteClusterId)
    
    if ($buildkiteProvided) {
        if ([string]::IsNullOrEmpty($BuildkiteToken)) {
            Write-ColorOutput Red "ERROR: Buildkite token not provided. Set BUILDKITE_TOKEN or use -BuildkiteToken"
            $valid = $false
        }
        
        if ([string]::IsNullOrEmpty($BuildkiteOrgSlug)) {
            Write-ColorOutput Red "ERROR: Buildkite org slug not provided. Set BUILDKITE_ORG_SLUG or use -BuildkiteOrgSlug"
            $valid = $false
        }
        
        if ([string]::IsNullOrEmpty($BuildkiteClusterId)) {
            Write-ColorOutput Red "ERROR: Buildkite cluster ID not provided. Set BUILDKITE_CLUSTER_ID or use -BuildkiteClusterId"
            $valid = $false
        }
    }
    
    return $valid
}

# Create or update Buildkite cluster access policy
function Set-BuildkiteClusterAccessPolicy {
    param(
        [string]$ClusterId,
        [string]$PipelineSlug
    )
    
    try {
        $headers = @{
            "Authorization" = "Bearer $BuildkiteToken"
            "Content-Type" = "application/json"
        }
        
        # Get existing policies to check if one exists for this pipeline
        $getPoliciesUri = "https://api.buildkite.com/v2/organizations/$BuildkiteOrgSlug/clusters/$ClusterId/policies"
        
        try {
            $existingPolicies = Invoke-RestMethod -Uri $getPoliciesUri -Method Get -Headers $headers
            $policyExists = $existingPolicies | Where-Object { 
                $_.pipelines -and $_.pipelines.slug -contains $PipelineSlug 
            }
        }
        catch {
            $policyExists = $null
        }
        
        if ($policyExists) {
            Write-ColorOutput Yellow "  ⚠ Access policy for pipeline '$PipelineSlug' already exists"
            return $true
        }
        
        # Create new access policy
        $body = @{
            pipelines = @(
                @{
                    slug = $PipelineSlug
                }
            )
        } | ConvertTo-Json -Depth 10
        
        $createUri = "https://api.buildkite.com/v2/organizations/$BuildkiteOrgSlug/clusters/$ClusterId/policies"
        $response = Invoke-RestMethod -Uri $createUri -Method Post -Headers $headers -Body $body
        
        Write-ColorOutput Green "  ✓ Created access policy for pipeline '$PipelineSlug'"
        return $true
    }
    catch {
        Write-ColorOutput Red "  ✗ Failed to create access policy for '$PipelineSlug': $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            Write-ColorOutput Red "    Response: $($_.ErrorDetails.Message)"
        }
        return $false
    }
}

# Create or update Buildkite cluster variable
function Set-BuildkiteClusterVariable {
    param(
        [string]$ClusterId,
        [string]$Key,
        [string]$Value
    )
    
    try {
        $headers = @{
            "Authorization" = "Bearer $BuildkiteToken"
            "Content-Type" = "application/json"
        }
        
        # Buildkite clusters API endpoint
        $getUri = "https://api.buildkite.com/v2/organizations/$BuildkiteOrgSlug/clusters/$ClusterId/env"
        
        try {
            $existing = Invoke-RestMethod -Uri $getUri -Method Get -Headers $headers
            $variableExists = $existing | Where-Object { $_.key -eq $Key }
        }
        catch {
            $variableExists = $null
        }
        
        $body = @{
            key = $Key
            value = $Value
            protected = $true
        } | ConvertTo-Json
        
        if ($variableExists) {
            # Update existing variable
            $updateUri = "https://api.buildkite.com/v2/organizations/$BuildkiteOrgSlug/clusters/$ClusterId/env/$($variableExists.id)"
            $response = Invoke-RestMethod -Uri $updateUri -Method Patch -Headers $headers -Body $body
            Write-ColorOutput Yellow "  ⚠ Updated existing cluster variable '$Key'"
        }
        else {
            # Create new variable
            $createUri = "https://api.buildkite.com/v2/organizations/$BuildkiteOrgSlug/clusters/$ClusterId/env"
            $response = Invoke-RestMethod -Uri $createUri -Method Post -Headers $headers -Body $body
            Write-ColorOutput Green "  ✓ Created cluster variable '$Key'"
        }
        
        return $true
    }
    catch {
        Write-ColorOutput Red "  ✗ Failed to set cluster variable '$Key': $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            Write-ColorOutput Red "    Response: $($_.ErrorDetails.Message)"
        }
        return $false
    }
}

# Enable AppRole auth method in Vault namespace
function Enable-VaultAppRole {
    param([string]$Namespace)
    
    try {
        $headers = @{
            "X-Vault-Token" = $VaultToken
            "X-Vault-Namespace" = $Namespace
        }
        
        $body = @{
            type = "approle"
        } | ConvertTo-Json
        
        $uri = "$VaultAddr/v1/sys/auth/approle"
        
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType "application/json"
        
        Write-ColorOutput Green "  ✓ Enabled AppRole auth in namespace '$Namespace'"
        return $true
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 400 -and $_.ErrorDetails.Message -like "*path is already in use*") {
            Write-ColorOutput Yellow "  ⚠ AppRole auth already enabled in namespace '$Namespace'"
            return $true
        }
        Write-ColorOutput Red "  ✗ Failed to enable AppRole auth in '$Namespace': $($_.Exception.Message)"
        return $false
    }
}

# Create Vault policy
function New-VaultPolicy {
    param(
        [string]$Namespace,
        [string]$PolicyName,
        [string]$PolicyContent
    )
    
    try {
        $headers = @{
            "X-Vault-Token" = $VaultToken
            "X-Vault-Namespace" = $Namespace
        }
        
        $body = @{
            policy = $PolicyContent
        } | ConvertTo-Json
        
        $uri = "$VaultAddr/v1/sys/policies/acl/$PolicyName"
        
        $response = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $body -ContentType "application/json"
        
        Write-ColorOutput Green "  ✓ Created policy '$PolicyName' in namespace '$Namespace'"
        return $true
    }
    catch {
        Write-ColorOutput Red "  ✗ Failed to create policy '$PolicyName' in '$Namespace': $($_.Exception.Message)"
        return $false
    }
}

# Create AppRole
function New-VaultAppRole {
    param(
        [string]$Namespace,
        [string]$RoleName,
        [string[]]$Policies
    )
    
    try {
        $headers = @{
            "X-Vault-Token" = $VaultToken
            "X-Vault-Namespace" = $Namespace
        }
        
        $body = @{
            token_policies = $Policies
            token_ttl = "1h"
            token_max_ttl = "4h"
        } | ConvertTo-Json
        
        $uri = "$VaultAddr/v1/auth/approle/role/$RoleName"
        
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType "application/json"
        
        Write-ColorOutput Green "  ✓ Created AppRole '$RoleName' in namespace '$Namespace'"
        return $true
    }
    catch {
        Write-ColorOutput Red "  ✗ Failed to create AppRole '$RoleName' in '$Namespace': $($_.Exception.Message)"
        return $false
    }
}

# Get AppRole Role ID
function Get-VaultAppRoleId {
    param(
        [string]$Namespace,
        [string]$RoleName
    )
    
    try {
        $headers = @{
            "X-Vault-Token" = $VaultToken
            "X-Vault-Namespace" = $Namespace
        }
        
        $uri = "$VaultAddr/v1/auth/approle/role/$RoleName/role-id"
        
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        
        Write-ColorOutput Green "  ✓ Retrieved Role ID for '$RoleName'"
        return $response.data.role_id
    }
    catch {
        Write-ColorOutput Red "  ✗ Failed to get Role ID for '$RoleName' in '$Namespace': $($_.Exception.Message)"
        return $null
    }
}

# Generate AppRole Secret ID
function New-VaultAppRoleSecretId {
    param(
        [string]$Namespace,
        [string]$RoleName
    )
    
    try {
        $headers = @{
            "X-Vault-Token" = $VaultToken
            "X-Vault-Namespace" = $Namespace
        }
        
        $uri = "$VaultAddr/v1/auth/approle/role/$RoleName/secret-id"
        
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType "application/json"
        
        Write-ColorOutput Green "  ✓ Generated Secret ID for '$RoleName'"
        return $response.data.secret_id
    }
    catch {
        Write-ColorOutput Red "  ✗ Failed to generate Secret ID for '$RoleName' in '$Namespace': $($_.Exception.Message)"
        return $null
    }
}

# Store secret in Vault namespace
function Set-VaultSecret {
    param(
        [string]$Namespace,
        [string]$Path,
        [hashtable]$Data
    )
    
    try {
        $headers = @{
            "X-Vault-Token" = $VaultToken
            "X-Vault-Namespace" = $Namespace
        }
        
        $body = @{
            data = $Data
        } | ConvertTo-Json -Depth 10
        
        $uri = "$VaultAddr/v1/secret/data/$Path"
        
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType "application/json"
        
        Write-ColorOutput Green "  ✓ Stored secret at '$Namespace/secret/$Path'"
        return $true
    }
    catch {
        Write-ColorOutput Red "  ✗ Failed to store secret at '$Namespace/secret/$Path': $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            Write-ColorOutput Red "    Response: $($_.ErrorDetails.Message)"
        }
        return $false
    }
}

# Create namespace in HashiCorp Vault
function New-VaultNamespace {
    param(
        [string]$ParentPath,
