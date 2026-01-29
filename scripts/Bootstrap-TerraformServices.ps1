#!/usr/bin/env pwsh
# ============================================================================
# Bootstrap-TerraformServices.ps1
# Creates AppRole auth, policies, and roles for Terraform services. Stores Lynx credentials in Vault. Stores Vault roleid and secretid in Buildkite secret variables.
# Stores role_id and secret_id in Buildkite pipeline environment variables
# ============================================================================
#
# Usage:
#   ./Setup-VaultAppRoles.ps1
#   ./Setup-VaultAppRoles.ps1 -DryRun
#
# Prerequisites:
#   - Vault token with admin access
#   - Buildkite API token with write access to pipelines
#
# ============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$VaultAddr = "http://vault.gssira.com:8200",
    
    [Parameter(Mandatory=$false)]
    [string]$VaultToken = "hvs.vwcrYLioLRZBO3tbsplBAMzA",
    
    [Parameter(Mandatory=$false)]
    [string]$RootNamespace = "DevOps/terraform-services",
    
    [Parameter(Mandatory=$false)]
    [string]$KvMount = "secret",
    
    [Parameter(Mandatory=$false)]
    [string]$BuildkiteApiToken = "bkua_e16297033d76cd680dc1418bd3a2ae6b7f4deadc",
    
    [Parameter(Mandatory=$false)]
    [string]$BuildkiteOrg = "gurdipdevops",
    
    [Parameter(Mandatory=$false)]
    [string]$BuildkiteClusterId = "e121d8c9-e133-4f47-a97a-c13aa3cff90c",
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION
# ============================================================================

$services = @(
    "axiom",
    "buildkite",
    "cloudflare",
    "netlify",
    "ngrok",
    "teamcity",
    "octopusdeploy",
    "splunk",
    "elastic",
    "netbox",
    "vmware",
    "argocd",
    "cloudsmith",
    "terrapwner",
    "mondoo",
    "grafana",
    "gns3",
    "lynx",
    "archestra",
    "kestra",
    "nirmata",
    "checkly",
    "portio",
    "sentry",
    "tailscale",
    "vault",
    "harbor"
)

# ============================================================================
# COUNTERS
# ============================================================================

$script:policiesCreated = 0
$script:rolesCreated = 0
$script:buildkiteSecretsCreated = 0
$script:failed = 0

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Header {
    param([string]$Message)
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✅ $Message" -ForegroundColor Green
}

function Write-Failed {
    param([string]$Message)
    Write-Host "  ❌ $Message" -ForegroundColor Red
    $script:failed++
}

function Write-Info {
    param([string]$Message)
    Write-Host "  ℹ️  $Message" -ForegroundColor Cyan
}

function Write-Exists {
    param([string]$Message)
    Write-Host "  ✅ $Message (exists)" -ForegroundColor DarkGray
}

# ============================================================================
# VAULT API FUNCTIONS (using curl.exe)
# ============================================================================

function Invoke-VaultApi {
    param(
        [string]$Method = "GET",
        [string]$Path,
        [string]$Namespace = "",
        [string]$Body = ""
    )
    
    $uri = "$VaultAddr/v1/$Path"
    
    if ($Body) {
        $tempFile = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($tempFile, $Body, (New-Object System.Text.UTF8Encoding $false))
        
        try {
            if ($Namespace) {
                $response = & curl.exe -s -X $Method `
                    -H "X-Vault-Token: $VaultToken" `
                    -H "X-Vault-Namespace: $Namespace" `
                    -H "Content-Type: application/json" `
                    -d "@$tempFile" `
                    $uri 2>$null
            } else {
                $response = & curl.exe -s -X $Method `
                    -H "X-Vault-Token: $VaultToken" `
                    -H "Content-Type: application/json" `
                    -d "@$tempFile" `
                    $uri 2>$null
            }
            return $response
        } finally {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    } else {
        if ($Namespace) {
            $response = & curl.exe -s -X $Method `
                -H "X-Vault-Token: $VaultToken" `
                -H "X-Vault-Namespace: $Namespace" `
                -H "Content-Type: application/json" `
                $uri 2>$null
        } else {
            $response = & curl.exe -s -X $Method `
                -H "X-Vault-Token: $VaultToken" `
                -H "Content-Type: application/json" `
                $uri 2>$null
        }
        return $response
    }
}

function Test-VaultConnection {
    $response = Invoke-VaultApi -Method "GET" -Path "sys/health"
    try {
        $json = $response | ConvertFrom-Json -ErrorAction Stop
        return @{
            Connected = $true
            Version = $json.version
        }
    } catch {
        return @{
            Connected = $false
            Error = $response
        }
    }
}

function Enable-AppRoleAuth {
    param([string]$Namespace)
    
    if ($DryRun) {
        Write-Host "    [DRY RUN] Would enable AppRole auth in $Namespace" -ForegroundColor DarkGray
        return $true
    }
    
    # Check if already enabled
    $response = Invoke-VaultApi -Method "GET" -Path "sys/auth" -Namespace $Namespace
    if ($response -match '"approle/"') {
        Write-Exists "AppRole auth enabled"
        return $true
    }
    
    # Enable AppRole
    $body = '{"type":"approle"}'
    $response = Invoke-VaultApi -Method "POST" -Path "sys/auth/approle" -Namespace $Namespace -Body $body
    
    if ($response -match 'error' -and -not ($response -match 'already in use')) {
        Write-Failed "Failed to enable AppRole: $response"
        return $false
    }
    
    Write-Success "Enabled AppRole auth"
    return $true
}

function New-VaultPolicy {
    param(
        [string]$Namespace,
        [string]$PolicyName,
        [string]$PolicyHcl
    )
    
    if ($DryRun) {
        Write-Host "    [DRY RUN] Would create policy: $PolicyName" -ForegroundColor DarkGray
        return $true
    }
    
    # Escape the policy for JSON
    $escapedPolicy = $PolicyHcl.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
    $body = "{`"policy`":`"$escapedPolicy`"}"
    
    $response = Invoke-VaultApi -Method "PUT" -Path "sys/policies/acl/$PolicyName" -Namespace $Namespace -Body $body
    
    if ($response -match 'error') {
        Write-Failed "Failed to create policy $PolicyName : $response"
        return $false
    }
    
    Write-Success "Created policy: $PolicyName"
    $script:policiesCreated++
    return $true
}

function New-AppRole {
    param(
        [string]$Namespace,
        [string]$RoleName,
        [string[]]$Policies
    )
    
    if ($DryRun) {
        Write-Host "    [DRY RUN] Would create AppRole: $RoleName" -ForegroundColor DarkGray
        return $true
    }
    
    # Build policies array JSON
    $policiesJson = ($Policies | ForEach-Object { "`"$_`"" }) -join ','
    $body = "{`"token_policies`":[$policiesJson],`"token_ttl`":`"1h`",`"token_max_ttl`":`"4h`",`"secret_id_ttl`":`"0`",`"secret_id_num_uses`":`"0`"}"
    
    $response = Invoke-VaultApi -Method "POST" -Path "auth/approle/role/$RoleName" -Namespace $Namespace -Body $body
    
    if ($response -match 'error') {
        Write-Failed "Failed to create AppRole $RoleName : $response"
        return $false
    }
    
    Write-Success "Created AppRole: $RoleName"
    $script:rolesCreated++
    return $true
}

function Get-AppRoleId {
    param(
        [string]$Namespace,
        [string]$RoleName
    )
    
    $response = Invoke-VaultApi -Method "GET" -Path "auth/approle/role/$RoleName/role-id" -Namespace $Namespace
    
    try {
        $json = $response | ConvertFrom-Json -ErrorAction Stop
        return $json.data.role_id
    } catch {
        Write-Failed "Failed to get role_id for $RoleName"
        return $null
    }
}

function New-AppRoleSecretId {
    param(
        [string]$Namespace,
        [string]$RoleName
    )
    
    $response = Invoke-VaultApi -Method "POST" -Path "auth/approle/role/$RoleName/secret-id" -Namespace $Namespace -Body "{}"
    
    try {
        $json = $response | ConvertFrom-Json -ErrorAction Stop
        return $json.data.secret_id
    } catch {
        Write-Failed "Failed to generate secret_id for $RoleName"
        return $null
    }
}

# ============================================================================
# BUILDKITE API FUNCTIONS
# ============================================================================

function Set-BuildkiteSecret {
    param(
        [string]$ServiceName,
        [string]$Key,
        [string]$Value
    )
    
    if ($DryRun) {
        Write-Host "    [DRY RUN] Would set Buildkite cluster secret: $Key" -ForegroundColor DarkGray
        return $true
    }
    
    if (-not $BuildkiteApiToken -or -not $BuildkiteOrg -or -not $BuildkiteClusterId) {
        Write-Host "    ⚠️ Buildkite not configured, skipping: $Key" -ForegroundColor Yellow
        return $false
    }
    
    # Pipeline name for restriction
    $pipelineName = "devops-terraform-services-$ServiceName"
    
    # Cluster secrets endpoint
    $secretsUri = "https://api.buildkite.com/v2/organizations/$BuildkiteOrg/clusters/$BuildkiteClusterId/secrets"
    
    # Check if secret exists
    $checkResponse = & curl.exe -s -X GET `
        -H "Authorization: Bearer $BuildkiteApiToken" `
        "$secretsUri" 2>$null
    
    $exists = $false
    $existingUuid = $null
    
    try {
        $secrets = $checkResponse | ConvertFrom-Json -ErrorAction Stop
        if ($secrets -is [array]) {
            foreach ($secret in $secrets) {
                if ($secret.key -eq $Key) {
                    $exists = $true
                    $existingUuid = $secret.uuid
                    break
                }
            }
        }
    } catch {
        # Ignore parse errors
    }
    
    # Body with pipeline restriction
    $body = "{`"key`":`"$Key`",`"value`":`"$Value`",`"rules`":[{`"type`":`"pipeline`",`"value`":`"pipeline.slug == '$pipelineName'`"}]}"
    $tempFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempFile, $body, (New-Object System.Text.UTF8Encoding $false))
    
    try {
        if ($exists -and $existingUuid) {
            # Update existing secret
            $updateUri = "$secretsUri/$existingUuid"
            $response = & curl.exe -s -X PATCH `
                -H "Authorization: Bearer $BuildkiteApiToken" `
                -H "Content-Type: application/json" `
                -d "@$tempFile" `
                $updateUri 2>$null
            
            if ($response -match '"key"' -or $response -match '"uuid"' -or $response -match '"id"') {
                Write-Success "Updated cluster secret: $Key (restricted to: $pipelineName)"
                $script:buildkiteSecretsCreated++
                return $true
            }
        } else {
            # Create new secret
            $response = & curl.exe -s -X POST `
                -H "Authorization: Bearer $BuildkiteApiToken" `
                -H "Content-Type: application/json" `
                -d "@$tempFile" `
                $secretsUri 2>$null
            
            if ($response -match '"key"' -or $response -match '"uuid"' -or $response -match '"id"') {
                Write-Success "Created cluster secret: $Key (restricted to: $pipelineName)"
                $script:buildkiteSecretsCreated++
                return $true
            }
        }
        
        Write-Failed "Failed to set cluster secret $Key : $response"
        return $false
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Header "Vault AppRole Setup Script"

Write-Host "`nConfiguration:" -ForegroundColor Yellow
Write-Host "  Vault Address:      $VaultAddr"
Write-Host "  Root Namespace:     $RootNamespace"
Write-Host "  KV Mount:           $KvMount"
Write-Host "  Buildkite Org:      $BuildkiteOrg"
Write-Host "  Buildkite Cluster:  $BuildkiteClusterId"
Write-Host "  Pipeline Pattern:   devops-terraform-services-{service}"
Write-Host "  Services:           $($services.Count)"
Write-Host "  Dry Run:            $DryRun"

if ($DryRun) {
    Write-Host "`n⚠️  DRY RUN MODE - No changes will be made" -ForegroundColor Yellow
}

# Verify prerequisites
Write-Header "Verifying Prerequisites"

# Check curl
$curlPath = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curlPath) {
    Write-Host "  ❌ curl.exe not found in PATH" -ForegroundColor Red
    exit 1
}
Write-Host "  ✅ curl.exe found" -ForegroundColor Green

# Check Vault connection
if (-not $DryRun) {
    $vaultStatus = Test-VaultConnection
    if ($vaultStatus.Connected) {
        Write-Host "  ✅ Vault connected (v$($vaultStatus.Version))" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Cannot connect to Vault: $($vaultStatus.Error)" -ForegroundColor Red
        exit 1
    }
}

# Check Buildkite configuration
if ($BuildkiteApiToken -and $BuildkiteOrg -and $BuildkiteClusterId) {
    Write-Host "  ✅ Buildkite configured (org: $BuildkiteOrg, cluster: $BuildkiteClusterId)" -ForegroundColor Green
} else {
    Write-Host "  ⚠️ Buildkite not fully configured - will skip storing secrets" -ForegroundColor Yellow
}

# Process each service
foreach ($service in $services) {
    $serviceNamespace = "$RootNamespace/$service"
    $prdNamespace = "$serviceNamespace/prd"
    
    Write-Header "Service: $service"
    Write-Host "  Namespace: $prdNamespace" -ForegroundColor DarkGray
    
    # 1. Enable AppRole auth in the prd namespace
    Write-Host "  → Enabling AppRole auth..." -ForegroundColor White
    if (-not (Enable-AppRoleAuth -Namespace $prdNamespace)) {
        Write-Failed "Could not enable AppRole, skipping service"
        continue
    }
    
    # 2. Create policy for reading/listing secrets
    Write-Host "  → Creating policy..." -ForegroundColor White
    $policyName = "terraform-$service-read"
    $policyHcl = @"
# Policy for terraform-$service
# Allows reading and listing secrets in the $KvMount mount

# Read secrets
path "$KvMount/data/*" {
  capabilities = ["read", "list"]
}

# List secrets
path "$KvMount/metadata/*" {
  capabilities = ["read", "list"]
}

# Allow looking up own token
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
"@
    
    if (-not (New-VaultPolicy -Namespace $prdNamespace -PolicyName $policyName -PolicyHcl $policyHcl)) {
        Write-Failed "Could not create policy, skipping service"
        continue
    }
    
    # 3. Create AppRole
    Write-Host "  → Creating AppRole..." -ForegroundColor White
    $roleName = "terraform-$service"
    if (-not (New-AppRole -Namespace $prdNamespace -RoleName $roleName -Policies @($policyName))) {
        Write-Failed "Could not create AppRole, skipping service"
        continue
    }
    
    # 4. Get role_id and generate secret_id
    if (-not $DryRun) {
        Write-Host "  → Retrieving credentials..." -ForegroundColor White
        $roleId = Get-AppRoleId -Namespace $prdNamespace -RoleName $roleName
        $secretId = New-AppRoleSecretId -Namespace $prdNamespace -RoleName $roleName
        
        if ($roleId -and $secretId) {
            Write-Host "    Role ID:   $($roleId.Substring(0, 8))..." -ForegroundColor DarkGray
            Write-Host "    Secret ID: $($secretId.Substring(0, 8))..." -ForegroundColor DarkGray
            
            # 5. Store in Buildkite
            Write-Host "  → Storing in Buildkite..." -ForegroundColor White
            $roleIdKey = "devops_terraform_services_$($service)_roleid"
            $secretIdKey = "devops_terraform_services_$($service)_secretid"
            
            Set-BuildkiteSecret -ServiceName $service -Key $roleIdKey -Value $roleId | Out-Null
            Set-BuildkiteSecret -ServiceName $service -Key $secretIdKey -Value $secretId | Out-Null
        }
    } else {
        Write-Host "    [DRY RUN] Would retrieve role_id and secret_id" -ForegroundColor DarkGray
        Write-Host "    [DRY RUN] Would store in Buildkite cluster: $BuildkiteCluster" -ForegroundColor DarkGray
        Write-Host "      devops_terraform_services_$($service)_roleid (restricted to: devops-terraform-services-$service)" -ForegroundColor DarkGray
        Write-Host "      devops_terraform_services_$($service)_secretid (restricted to: devops-terraform-services-$service)" -ForegroundColor DarkGray
    }
}

Write-Header "Summary"
Write-Host "`n  Vault:" -ForegroundColor White
Write-Host "    Policies created:  $($script:policiesCreated)" -ForegroundColor Green
Write-Host "    AppRoles created:  $($script:rolesCreated)" -ForegroundColor Green

Write-Host "`n  Buildkite:" -ForegroundColor White
Write-Host "    Secrets created:   $($script:buildkiteSecretsCreated)" -ForegroundColor Green

Write-Host "`n  Errors:" -ForegroundColor White
Write-Host "    Failed:            $($script:failed)" -ForegroundColor $(if ($script:failed -gt 0) { "Red" } else { "White" })

if ($DryRun) {
    Write-Host "`n⚠️  DRY RUN - No changes were made" -ForegroundColor Yellow
}

Write-Host "`n📋 Buildkite Variable Names:" -ForegroundColor Cyan
Write-Host "  devops_terraform_services_{service}_roleid" -ForegroundColor White
Write-Host "  devops_terraform_services_{service}_secretid" -ForegroundColor White

exit $(if ($script:failed -gt 0) { 1 } else { 0 })
