#!/usr/bin/env pwsh
# ============================================================================
# Generate-CosignKeysPerService.ps1
# Generate cosign key pairs for each terraform service
# ============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$OutputDir = ".\cosign-keys"
)

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

# Create output directory
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Generate Cosign Keys Per Service" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "`nOutput: $OutputDir"
Write-Host "Services: $($services.Count)`n"

$created = 0
$failed = 0

foreach ($service in $services) {
    Write-Host "→ $service... " -NoNewline
    
    $serviceDir = Join-Path $OutputDir $service
    New-Item -ItemType Directory -Path $serviceDir -Force | Out-Null
    
    $password = [System.Guid]::NewGuid().ToString() + [System.Guid]::NewGuid().ToString()
    
    # Remove existing keys
    Remove-Item (Join-Path $serviceDir "cosign.key") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $serviceDir "cosign.pub") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $serviceDir "password.txt") -Force -ErrorAction SilentlyContinue
    
    # Get cosign path
    $cosignPath = (Get-Command cosign -ErrorAction SilentlyContinue).Source
    if (-not $cosignPath) {
        $cosignPath = "cosign"
    }
    
    # Create batch file with full path
    $batchFile = Join-Path $serviceDir "run-cosign.bat"
    @"
@echo off
cd /d "$serviceDir"
set COSIGN_PASSWORD=$password
"$cosignPath" generate-key-pair
"@ | Set-Content $batchFile -Encoding ASCII
    
    # Run it
    $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$batchFile`"" -NoNewWindow -Wait -PassThru
    
    Remove-Item $batchFile -Force -ErrorAction SilentlyContinue
    
    $keyFile = Join-Path $serviceDir "cosign.key"
    $pubFile = Join-Path $serviceDir "cosign.pub"
    $pwdFile = Join-Path $serviceDir "password.txt"
    
    if ((Test-Path $keyFile) -and (Test-Path $pubFile)) {
        # Save password
        $password | Set-Content $pwdFile -Encoding UTF8
        
        Write-Host "✅" -ForegroundColor Green
        $created++
    } else {
        Write-Host "❌ (files not created)" -ForegroundColor Red
        $failed++
    }
}

Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "`n  Created: $created" -ForegroundColor Green
Write-Host "  Failed:  $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "White" })

Write-Host "`n📁 Keys saved to: $OutputDir"
Write-Host "   Each service folder contains:"
Write-Host "     - cosign.key (private key)"
Write-Host "     - cosign.pub (public key)"
Write-Host "     - password.txt (password used)`n"
