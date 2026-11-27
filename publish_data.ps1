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
#
# Large datasets (tens of thousands of schools) are read with a JSON reader
# that has no size limit; Windows PowerShell's ConvertFrom-Json stops at 2 MB.

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

# Reads a JSON file into dictionaries and lists, whatever its size.
function Read-Json([string]$path) {
    $text = [IO.File]::ReadAllText($path)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $text | ConvertFrom-Json -AsHashtable
    }
    Add-Type -AssemblyName System.Web.Extensions
    $reader = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $reader.MaxJsonLength = [int]::MaxValue
    return $reader.DeserializeObject($text)
}

if (-not (Test-Path $Dataset)) { Stop-Publish "dataset not found at $Dataset" }
$source = (Resolve-Path $Dataset).Path
Write-Host 'Reading the dataset (large files take a few seconds)...'
$data = Read-Json $source

# --- 1. Shape --------------------------------------------------------------
if ($data['format'] -ne 'nextstep-dataset') { Stop-Publish 'that file is not a NextStep dataset.' }
$allowed = @('format','schemaVersion','datasetVersion','publishedAt','isDemo','notes',
             'institutions','nationalEvents','retiredInstitutions')
foreach ($key in $data.Keys) {
    if ($allowed -notcontains $key) { Stop-Publish "unexpected top-level field '$key'." }
}
$version = [int]$data['datasetVersion']
$schema = [int]$data['schemaVersion']
$published = [string]$data['publishedAt']
$newIds = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($i in $data['institutions']) { [void]$newIds.Add([string]$i['id']) }
$newRetired = New-Object 'System.Collections.Generic.HashSet[string]'
if ($data['retiredInstitutions']) { foreach ($r in $data['retiredInstitutions']) { [void]$newRetired.Add([string]$r['id']) } }
Write-Host "Dataset version ${version}: $($newIds.Count) institutions."

# --- 2. Compare with what's already published ------------------------------
$manifestPath = Join-Path $here 'manifest.json'
$entries = @()
if (Test-Path $manifestPath) {
    $old = Read-Json $manifestPath
    if ($old['datasets']) {
        foreach ($e in $old['datasets']) {
            $entries += [pscustomobject]@{ schemaVersion = $e['schemaVersion']; datasetVersion = $e['datasetVersion']
                publishedAt = $e['publishedAt']; file = $e['file']; sha256 = $e['sha256'] }
        }
    } elseif ($old['datasetFile']) {
        $entries += [pscustomobject]@{ schemaVersion = $old['schemaVersion']; datasetVersion = $old['datasetVersion']
            publishedAt = $old['publishedAt']; file = $old['datasetFile']; sha256 = $old['sha256'] }
    }
}
$latest = $entries | Sort-Object { [int]$_.datasetVersion } -Descending | Select-Object -First 1
if ($latest) {
    if ($version -le [int]$latest.datasetVersion) {
        Stop-Publish "datasetVersion $version must be higher than the published $($latest.datasetVersion)."
    }
    $previousFile = Join-Path $here $latest.file
    if (Test-Path $previousFile) {
        Write-Host 'Comparing with the published version...'
        $previous = Read-Json $previousFile
        foreach ($inst in $previous['institutions']) {
            $id = [string]$inst['id']
            if (-not $newIds.Contains($id) -and -not $newRetired.Contains($id)) {
                Stop-Publish "'$id' was removed without being added to retiredInstitutions."
            }
        }
        if ($previous['retiredInstitutions']) {
            foreach ($r in $previous['retiredInstitutions']) {
                $id = [string]$r['id']
                if (-not $newRetired.Contains($id)) { Stop-Publish "retired ID '$id' must stay in retiredInstitutions." }
                if ($newIds.Contains($id)) { Stop-Publish "retired ID '$id' can't be reused for an active institution." }
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
[IO.File]::WriteAllText($manifestPath, $manifest)

git add -A
git commit -m "Publish dataset version $version"
if (-not $NoPush) { git push }

Write-Host ''
Write-Host "Published dataset version $version (format $schema, fingerprint $($hash.Substring(0, 12))...)." -ForegroundColor Green
