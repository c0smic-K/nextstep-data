# Publishes the app's dataset to this repository (and so to GitHub Pages).
# Run from the nextstep-data folder:
#   powershell -ExecutionPolicy Bypass -File .\publish_data.ps1
# Options: -Dataset <path to nextstep_dataset.json>  -NoPush (commit only)
#
# Safety checks before anything is published:
#   - it's a NextStep dataset with only the expected top-level fields
#     (so nothing personal can be mixed into this public repository)
#   - its version is higher than the version already published
#   - no institution disappears unless it's listed in retiredInstitutions
#   - previously retired IDs stay retired and are never reused

param(
    [string]$Dataset = '..\nextstep\assets\data\nextstep_dataset.json',
    [switch]$NoPush
)
$ErrorActionPreference = 'Stop'
$here = (Get-Location).Path

function Stop-Publish($message) {
    Write-Host "Not published: $message" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $Dataset)) { Stop-Publish "dataset not found at $Dataset" }
$source = (Resolve-Path $Dataset).Path
$data = [IO.File]::ReadAllText($source) | ConvertFrom-Json

# --- 1. Shape --------------------------------------------------------------
if ($data.format -ne 'nextstep-dataset') { Stop-Publish 'that file is not a NextStep dataset.' }
$allowed = @('format','schemaVersion','datasetVersion','publishedAt','isDemo','notes',
             'institutions','nationalEvents','retiredInstitutions')
foreach ($key in $data.PSObject.Properties.Name) {
    if ($allowed -notcontains $key) { Stop-Publish "unexpected top-level field '$key'." }
}
$version = [int]$data.datasetVersion
$schema = [int]$data.schemaVersion
$published = [string]$data.publishedAt
$newIds = @($data.institutions | ForEach-Object { $_.id })
$newRetired = @($data.retiredInstitutions | ForEach-Object { $_.id })

# --- 2. Compare with what's already published ------------------------------
$manifestPath = Join-Path $here 'manifest.json'
$entries = @()
if (Test-Path $manifestPath) {
    $old = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($old.datasets) {
        $entries = @($old.datasets)
    } elseif ($old.datasetFile) {
        # First published form: one dataset described at the top level.
        $entries = @([pscustomobject]@{
            schemaVersion = $old.schemaVersion; datasetVersion = $old.datasetVersion
            publishedAt = $old.publishedAt; file = $old.datasetFile; sha256 = $old.sha256 })
    }
}
$latest = $entries | Sort-Object { [int]$_.datasetVersion } -Descending | Select-Object -First 1
if ($latest) {
    if ($version -le [int]$latest.datasetVersion) {
        Stop-Publish "datasetVersion $version must be higher than the published $($latest.datasetVersion)."
    }
    $previousFile = Join-Path $here $latest.file
    if (Test-Path $previousFile) {
        $previous = [IO.File]::ReadAllText($previousFile) | ConvertFrom-Json
        foreach ($inst in $previous.institutions) {
            if ($newIds -notcontains $inst.id -and $newRetired -notcontains $inst.id) {
                Stop-Publish "'$($inst.id)' was removed without being added to retiredInstitutions."
            }
        }
        foreach ($r in $previous.retiredInstitutions) {
            if ($newRetired -notcontains $r.id) {
                Stop-Publish "retired ID '$($r.id)' must stay in retiredInstitutions."
            }
            if ($newIds -contains $r.id) {
                Stop-Publish "retired ID '$($r.id)' can't be reused for an active institution."
            }
        }
    }
}

# --- 3. Publish ------------------------------------------------------------
# Byte-for-byte copy, so the fingerprint matches what phones download.
$fileName = "nextstep_dataset_v$version.json"
Copy-Item $source (Join-Path $here $fileName) -Force
$hash = (Get-FileHash -Algorithm SHA256 (Join-Path $here $fileName)).Hash.ToLower()

# Keep the newest entry for every older format, so phones that haven't
# updated the app keep receiving data they understand.
$kept = @($entries | Where-Object { [int]$_.schemaVersion -ne $schema })
$lines = @()
foreach ($e in $kept + @([pscustomobject]@{
        schemaVersion = $schema; datasetVersion = $version
        publishedAt = $published; file = $fileName; sha256 = $hash })) {
    $lines += "    { ""schemaVersion"": $($e.schemaVersion), ""datasetVersion"": $($e.datasetVersion), " +
              """publishedAt"": ""$($e.publishedAt)"", ""file"": ""$($e.file)"", ""sha256"": ""$($e.sha256)"" }"
}
$manifest = "{`n  ""format"": ""nextstep-manifest"",`n  ""datasets"": [`n" + ($lines -join ",`n") + "`n  ]`n}`n"
# UTF-8 without a byte-order mark.
[IO.File]::WriteAllText($manifestPath, $manifest)

git add -A
git commit -m "Publish dataset version $version"
if (-not $NoPush) { git push }

Write-Host ''
Write-Host "Published dataset version $version (format $schema, fingerprint $($hash.Substring(0, 12))...)." -ForegroundColor Green
