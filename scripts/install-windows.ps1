
# DigitalBase installer for Windows (run as a normal user; PostgreSQL and pgvector come first from setup-windows.ps1)
#   irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-windows.ps1 | iex
# Downloads the binary and hands over to `api.exe setup` (the same installer as Linux: database, .env, db command, start at logon)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$BASE_URL = if ($env:DB_BASE_URL) { $env:DB_BASE_URL } else { "https://github.com/lmlight-app/dist_vite/releases/latest/download" }
$VERSION_BASE_URL="https://github.com/lmlight-app/dist_vite/releases/download/"
$DB_VERSION = if ($env:DB_VERSION) { $env:DB_VERSION } else { "latest" }
$INSTALL_DIR = if ($env:DB_INSTALL_DIR) { $env:DB_INSTALL_DIR } else { "$env:LOCALAPPDATA\db" }
$ARCH = if ($env:DB_ARCH) { $env:DB_ARCH } elseif ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
# Windows を api.exe setup で入れられるのはこのバージョンから
$MIN_SETUP_VERSION = "26.11.231"

function Fail([string]$Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red; exit 1 }

if ($DB_VERSION -notmatch '^(latest|\d{2}\.\d{1,2}\.\d{1,3}|x\d{8}(\.\d+)?(-[a-z0-9]+)?|\d{2}\.\d{4}(\.\d+)?)$') {
    Fail "DB_VERSION must be latest, a version (26.10.124), or a release tag (x20261012.4)"
}
function Get-ReleaseTag([string]$Version) {
    if ($Version -like "x*") { return $Version }
    $p = $Version.Split('.') | ForEach-Object { [int]$_ }
    if ($p[1] -le 12) { $m = $p[1]; $d = [math]::Floor($p[2] / 10); $b = $p[2] % 10 }
    else { $m = [math]::Floor($p[1] / 100); $d = $p[1] % 100; $b = $(if ($p.Count -gt 2) { $p[2] } else { 0 }) }
    $tag = "x20{0:D2}{1:D2}{2:D2}" -f $p[0], [int]$m, [int]$d
    if ($b) { $tag += ".$b" }
    return $tag
}
function Get-DisplayVersion([string]$Tag) {
    $t = ($Tag -replace '^x', '') -replace '-[a-z0-9]+$', ''
    $parts = $t.Split('.')
    $build = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
    return "{0}.{1}.{2}" -f [int]$parts[0].Substring(2, 2), [int]$parts[0].Substring(4, 2), ([int]$parts[0].Substring(6, 2) * 10 + $build)
}
$TARGET_VERSION = ""
if ($DB_VERSION -ne "latest") {
    $releaseRef = Get-ReleaseTag $DB_VERSION
# BEGIN staging-only
    $base = $releaseRef -replace '-[a-z0-9]+$', ''
    $tags = (Invoke-RestMethod -Uri "https://api.github.com/repos/lmlight-app/dist_vite/releases?per_page=100" -UseBasicParsing).tag_name |
        Where-Object { $_ -match ('^' + [regex]::Escape($base) + '(-[a-z0-9]+)?$') }
    $releaseRef = ($tags | Where-Object { $_ -like "*-windows" } | Select-Object -First 1)
    if (-not $releaseRef) { $releaseRef = ($tags | Where-Object { $_ -notlike "*-*" } | Select-Object -First 1) }
    if (-not $releaseRef) { Fail "Version $DB_VERSION was not found in releases" }
# END staging-only
    if (-not $env:DB_BASE_URL) { $BASE_URL = "$VERSION_BASE_URL$releaseRef" }
    $TARGET_VERSION = Get-DisplayVersion $releaseRef
    if ([version]$TARGET_VERSION -lt [version]$MIN_SETUP_VERSION) { Fail "$TARGET_VERSION is older than $MIN_SETUP_VERSION and cannot be installed with this installer" }
}

New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
$binaryName = "lmlight-vite-windows-$ARCH.exe"
$bin = Join-Path $INSTALL_DIR "api.new.$PID.exe"
Write-Host "Installing DigitalBase $(if ($TARGET_VERSION) { $TARGET_VERSION } else { 'latest' }) ($ARCH) to $INSTALL_DIR"
$ProgressPreference = "SilentlyContinue"
try { Invoke-WebRequest -Uri "$BASE_URL/$binaryName" -OutFile $bin -UseBasicParsing } catch { Remove-Item -Force $bin -ErrorAction SilentlyContinue; Fail "Failed to get the binary: $BASE_URL/$binaryName ($($_.Exception.Message))" }
if ($env:DB_SKIP_SHA256 -eq "1") {
    Write-Host "[WARN] sha256 verification skipped (DB_SKIP_SHA256=1)" -ForegroundColor Yellow
} else {
    $expected = ""
    try {
        $content = (Invoke-WebRequest -Uri "$BASE_URL/$binaryName.sha256" -UseBasicParsing).Content
        if ($content -is [byte[]]) { $content = [Text.Encoding]::ASCII.GetString($content) }
        $expected = ($content.Trim() -split '\s+')[0].ToLower()
    } catch {}
    if ($expected -match '^[0-9a-f]{64}$') {
        $actual = (Get-FileHash -Algorithm SHA256 $bin).Hash.ToLower()
        if ($expected -ne $actual) { Remove-Item -Force $bin; Fail "sha256 mismatch: expected $expected, got $actual" }
        Write-Host "[OK] sha256 verified: $actual" -ForegroundColor Green
    } else {
        Write-Host "[WARN] checksum unavailable ($BASE_URL/$binaryName.sha256), continuing without sha256 verification" -ForegroundColor Yellow
    }
}

$env:DB_INSTALL_DIR = $INSTALL_DIR
Push-Location $INSTALL_DIR
try {
    # PowerShell 5.1 は空の引数を外のプログラムに渡さないので、最新 (バージョンが空) の時は --product-version を付けない (本体が自分のバージョンを使う)
    $setupArgs = @("setup", "--binary", $bin)
    if ($TARGET_VERSION) { $setupArgs += @("--product-version", $TARGET_VERSION) }
    & $bin @setupArgs
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $code
