<#
sync-buildkite-bootstrap-pipelines.ps1

Idempotently creates/updates Buildkite pipelines for GitHub repos that contain a Buildkite pipeline file.
No git clone. No repo creation. Uses GitHub + Buildkite APIs only.

Logic:
- List repos in a GitHub org
- Optionally require .buildkite/ folder to exist
- Find first pipeline file from candidates:
    .buildkite/pipeline.yml
    .buildkite/pipeline.yaml
    buildkite.yml
    buildkite.yaml
- Ensure Buildkite pipeline exists with bootstrap config:
    buildkite-agent pipeline upload <found-path>
- Idempotent: PATCH only if repository/branch/config differs
- Report output: console summary + CSV + JSON

Requirements:
- PowerShell 5.1+ or 7+
- GitHub token: repo read (org read if needed)
- Buildkite token: manage pipelines
#>

param(
  # GitHub
  [Parameter(Mandatory = $true)]
  [string]$GitHubOrg,

  [Parameter(Mandatory = $true)]
  [string]$GitHubToken,

  # Buildkite
  [Parameter(Mandatory = $true)]
  [string]$BuildkiteOrgSlug,

  [Parameter(Mandatory = $true)]
  [string]$BuildkiteToken,

  # Candidate pipeline files (checked in order)
  [string[]]$PipelineCandidates = @(
    ".buildkite/pipeline.yml",
    ".buildkite/pipeline.yaml",
    "buildkite.yml",
    "buildkite.yaml"
  ),

  # If set, require BOTH .buildkite/ folder exists AND a pipeline file exists
  [switch]$RequireBuildkiteFolder,

  # Defaults
  [string]$DefaultBranchFallback = "main",

  # Filters
  [switch]$IncludeArchived = $false,
  [switch]$IncludeForks = $false,

  # Report output (writes CSV + JSON here)
  [string]$ReportDir = ".",

  # Behaviour
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ---------------- Helpers ----------------

function Sanitize-Slug([string]$name) {
  return ($name.ToLower() -replace '[^a-z0-9\-]+','-').Trim('-')
}

function Normalize([string]$s) {
  if ($null -eq $s) { return "" }
  return ($s -replace "`r`n", "`n").Trim()
}

function Invoke-GitHub([string]$method, [string]$url) {
  $headers = @{
    "Authorization" = "Bearer $GitHubToken"
    "Accept"        = "application/vnd.github+json"
    "User-Agent"    = "bk-sync"
    "X-GitHub-Api-Version" = "2022-11-28"
  }
  Invoke-RestMethod -Method $method -Uri $url -Headers $headers
}

function Invoke-Buildkite([string]$method, [string]$url, $body = $null) {
  $headers = @{
    "Authorization" = "Bearer $BuildkiteToken"
    "Content-Type"  = "application/json"
  }
  if ($null -eq $body) {
    Invoke-RestMethod -Method $method -Uri $url -Headers $headers
  } else {
    $json = $body | ConvertTo-Json -Depth 30
    Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $json
  }
}

function Get-AllOrgRepos {
  $perPage = 100
  $page = 1
  $all = @()

  while ($true) {
    $url = "https://api.github.com/orgs/$GitHubOrg/repos?per_page=$perPage&page=$page&type=all&sort=full_name"
    $repos = Invoke-GitHub GET $url
    if (-not $repos -or $repos.Count -eq 0) { break }

    $all += $repos
    if ($repos.Count -lt $perPage) { break }
    $page++
  }

  $all
}

function GitHub-FolderExists {
  param(
    [Parameter(Mandatory=$true)][string]$RepoName,
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Ref
  )

  $url = "https://api.github.com/repos/$GitHubOrg/$RepoName/contents/$Path?ref=$Ref"
  try {
    $item = Invoke-GitHub GET $url
    return ($item.type -eq "dir")
  } catch {
    $resp = $_.Exception.Response
    if ($resp -and $resp.StatusCode.value__ -eq 404) { return $false }
    throw
  }
}

function GitHub-FindPipelineFile {
  param(
    [Parameter(Mandatory=$true)][string]$RepoName,
    [Parameter(Mandatory=$true)][string]$Ref,
    [Parameter(Mandatory=$true)][string[]]$Candidates
  )

  foreach ($path in $Candidates) {
    $url = "https://api.github.com/repos/$GitHubOrg/$RepoName/contents/$path?ref=$Ref"
    try {
      $item = Invoke-GitHub GET $url
      if ($item.type -eq "file") {
        return $path
      }
    } catch {
      $resp = $_.Exception.Response
      if ($resp -and $resp.StatusCode.value__ -eq 404) { continue }
      throw
    }
  }

  return $null
}

function Get-BootstrapConfig {
  param([Parameter(Mandatory=$true)][string]$PipelinePath)

@"
steps:
  - label: ":pipeline: Upload pipeline"
    command: "buildkite-agent pipeline upload $PipelinePath"
"@
}

function Get-BuildkitePipeline {
  param([Parameter(Mandatory=$true)][string]$Slug)

  $url = "https://api.buildkite.com/v2/organizations/$BuildkiteOrgSlug/pipelines/$Slug"
  try {
    return Invoke-Buildkite GET $url
  } catch {
    $resp = $_.Exception.Response
    if ($resp -and $resp.StatusCode.value__ -eq 404) { return $null }
    throw
  }
}

function Ensure-ReportDir {
  param([Parameter(Mandatory=$true)][string]$Dir)
  $full = Resolve-Path -LiteralPath $Dir -ErrorAction SilentlyContinue
  if (-not $full) {
    New-Item -ItemType Directory -Path $Dir | Out-Null
    $full = Resolve-Path -LiteralPath $Dir
  }
  return $full.Path
}

# ---------------- Main ----------------

$reportPath = Ensure-ReportDir -Dir $ReportDir
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath  = Join-Path $reportPath "buildkite-pipeline-sync-report-$stamp.csv"
$jsonPath = Join-Path $reportPath "buildkite-pipeline-sync-report-$stamp.json"

$repos = Get-AllOrgRepos | Where-Object {
  ($IncludeArchived -or -not $_.archived) -and
  ($IncludeForks -or -not $_.fork)
}

Write-Host "Repos after filters: $($repos.Count)"
Write-Host "RequireBuildkiteFolder: $RequireBuildkiteFolder"
Write-Host "Candidates: $($PipelineCandidates -join ', ')"
Write-Host "DryRun: $DryRun"
Write-Host ""

$report = New-Object System.Collections.Generic.List[object]

$created = 0
$updated = 0
$unchanged = 0
$skipped = 0
$failed = 0

foreach ($r in $repos) {
  $repoName = $r.name
  $repoFullName = $r.full_name
  $slug = Sanitize-Slug $repoName
  $defaultBranch = if ($r.default_branch) { $r.default_branch } else { $DefaultBranchFallback }
  $repoUrl = $r.clone_url

  $row = [ordered]@{
    timestamp_utc            = (Get-Date).ToUniversalTime().ToString("o")
    github_org               = $GitHubOrg
    github_repo              = $repoName
    github_full_name         = $repoFullName
    github_default_branch    = $defaultBranch
    github_repo_url          = $r.html_url
    buildkite_org_slug       = $BuildkiteOrgSlug
    buildkite_pipeline_slug  = $slug
    buildkite_repository     = $repoUrl
    require_buildkite_folder = [bool]$RequireBuildkiteFolder
    pipeline_file_found      = $null
    action                   = $null          # created | updated | unchanged | skipped | failed
    reason                   = $null
    changed_fields           = $null
  }

  try {
    if ($RequireBuildkiteFolder) {
      $hasFolder = GitHub-FolderExists -RepoName $repoName -Path ".buildkite" -Ref $defaultBranch
      if (-not $hasFolder) {
        $row.action = "skipped"
        $row.reason = "missing .buildkite/ folder"
        $skipped++
        $report.Add([pscustomobject]$row)
        Write-Host "⏭ $repoName: missing .buildkite/ folder"
        continue
      }
    }

    $pipelinePath = GitHub-FindPipelineFile -RepoName $repoName -Ref $defaultBranch -Candidates $PipelineCandidates
    if (-not $pipelinePath) {
      $row.action = "skipped"
      $row.reason = "no pipeline file found"
      $skipped++
      $report.Add([pscustomobject]$row)
      Write-Host "⏭ $repoName: no pipeline file found"
      continue
    }

    $row.pipeline_file_found = $pipelinePath
    $desiredConfig = Get-BootstrapConfig -PipelinePath $pipelinePath

    $existing = Get-BuildkitePipeline -Slug $slug

    if ($null -eq $existing) {
      $body = @{
        name = $repoName
        slug = $slug
        repository = $repoUrl
        branch_configuration = $defaultBranch
        configuration = $desiredConfig
        provider_settings = @{
          trigger_mode = "code"
          build_pull_requests = $true
          build_pull_request_forks = $false
          build_tags = $false
        }
      }

      if ($DryRun) {
        $row.action = "created"
        $row.reason = "dryrun"
        $report.Add([pscustomobject]$row)
        Write-Host "DRYRUN 🆕 CREATE $repoName ($slug) using $pipelinePath"
      } else {
        $createUrl = "https://api.buildkite.com/v2/organizations/$BuildkiteOrgSlug/pipelines"
        Invoke-Buildkite POST $createUrl $body | Out-Null
        $row.action = "created"
        $row.reason = "created pipeline"
        $report.Add([pscustomobject]$row)
        Write-Host "🆕 Created $repoName ($slug) using $pipelinePath"
      }

      $created++
      continue
    }

    # Idempotent comparisons
    $needsRepo   = (Normalize $existing.repository) -ne (Normalize $repoUrl)
    $needsBranch = (Normalize $existing.branch_configuration) -ne (Normalize $defaultBranch)
    $needsConfig = (Normalize $existing.configuration) -ne (Normalize $desiredConfig)

    if (-not ($needsRepo -or $needsBranch -or $needsConfig)) {
      $row.action = "unchanged"
      $row.reason = "already matches desired state"
      $report.Add([pscustomobject]$row)
      Write-Host "✅ Unchanged $repoName ($slug)"
      $unchanged++
      continue
    }

    $patch = @{}
    $changed = @()

    if ($needsRepo)   { $patch.repository = $repoUrl; $changed += "repository" }
    if ($needsBranch) { $patch.branch_configuration = $defaultBranch; $changed += "branch_configuration" }
    if ($needsConfig) { $patch.configuration = $desiredConfig; $changed += "configuration" }

    $row.changed_fields = ($changed -join ",")

    if ($DryRun) {
      $row.action = "updated"
      $row.reason = "dryrun"
      $report.Add([pscustomobject]$row)
      Write-Host "DRYRUN ♻ PATCH $repoName ($slug): $($changed -join ', ')"
    } else {
      $patchUrl = "https://api.buildkite.com/v2/organizations/$BuildkiteOrgSlug/pipelines/$slug"
      Invoke-Buildkite PATCH $patchUrl $patch | Out-Null
      $row.action = "updated"
      $row.reason = "patched pipeline"
      $report.Add([pscustomobject]$row)
      Write-Host "♻ Updated $repoName ($slug): $($changed -join ', ')"
    }

    $updated++
  }
  catch {
    $row.action = "failed"
    $row.reason = $_.Exception.Message
    $failed++
    $report.Add([pscustomobject]$row)
    Write-Host "❌ Failed $repoName ($slug): $($_.Exception.Message)"
  }
}

# Write report files
$report | Export-Csv -NoTypeInformation -Path $csvPath -Encoding UTF8
$report | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

Write-Host ""
Write-Host "Done."
Write-Host "Created:   $created"
Write-Host "Updated:   $updated"
Write-Host "Unchanged: $unchanged"
Write-Host "Skipped:   $skipped"
Write-Host "Failed:    $failed"
Write-Host ""
Write-Host "Report CSV:  $csvPath"
Write-Host "Report JSON: $jsonPath"
