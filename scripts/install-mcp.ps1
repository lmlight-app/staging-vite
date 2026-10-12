# DigitalBase - カスタム MCP ランタイム インストーラー (Windows)
#
# ユーザーが Python (fastmcp) で書いた MCP server を本体が別プロセスとして起動するための土台を入れる:
#   uv (Python パッケージ管理) → Python (uv 管理) → 配置先ディレクトリ → .env の設定
# server ごとの venv は本体が保存時に作るので、このスクリプトは 1 回だけ実行すればよい。
#
# 使い方:
#   irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-mcp.ps1 | iex
#   & ([scriptblock]::Create((irm .../install-mcp.ps1))) -PythonVersion 3.13 -McpDir "D:\db\mcp"
#
# 環境変数: DB_INSTALL_DIR (本体の配置先、既定 %LOCALAPPDATA%\db)、MCP_PYTHON_VER (既定 3.13)

param(
    [string]$PythonVersion = $(if ($env:MCP_PYTHON_VER) { $env:MCP_PYTHON_VER } else { "3.13" }),
    [string]$McpDir = "",
    [switch]$NoPrewarm
)

$ErrorActionPreference = "Stop"

$InstallDir = if ($env:DB_INSTALL_DIR) { $env:DB_INSTALL_DIR } else { "$env:LOCALAPPDATA\db" }
$EnvFile = "$InstallDir\.env"
if (-not $McpDir) { $McpDir = "$InstallDir\mcp" }

function Write-Ok { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Fail { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " DigitalBase Custom MCP runtime installer" -ForegroundColor Cyan
Write-Host "   install dir : $InstallDir"
Write-Host "   mcp dir     : $McpDir"
Write-Host "   python      : $PythonVersion"
Write-Host "==============================================" -ForegroundColor Cyan

if (-not (Test-Path $InstallDir)) {
    Fail "$InstallDir が見つかりません。先に本体 (install-windows.ps1) を導入してください"
}

# ── uv (= astral.sh の PowerShell installer。%USERPROFILE%\.local\bin に入る) ──
$UvBin = "$env:USERPROFILE\.local\bin"
if (-not (Get-Command uv -ErrorAction SilentlyContinue) -and -not (Test-Path "$UvBin\uv.exe")) {
    Write-Host "Installing uv..."
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
        $ProgressPreference = 'Continue'
    } catch {
        Fail "uv のインストールに失敗しました。閉域網なら uv を手動導入して再実行してください: $_"
    }
}
if (Test-Path "$UvBin\uv.exe") { $env:Path = "$UvBin;$env:Path" }
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Fail "uv が PATH にありません ($UvBin\uv.exe を確認)"
}
Write-Ok ("uv " + ((uv --version) -split ' ')[1])

# ── Python (= uv 管理。system python には触らない) ──
Write-Host "Ensuring Python $PythonVersion (uv managed)..."
& uv python install $PythonVersion 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Python $PythonVersion の取得に失敗しました (閉域網なら uv python install を手動で)" }
Write-Ok "Python $PythonVersion"

# ── 配置先 ──
New-Item -ItemType Directory -Force -Path $McpDir | Out-Null
try {
    $probe = Join-Path $McpDir ".write-test"
    Set-Content -Path $probe -Value "ok"
    Remove-Item $probe -Force
} catch {
    Fail "$McpDir に書き込めません"
}
Write-Ok $McpDir

# ── 初回保存を速くするため fastmcp の wheel を uv cache に載せておく (任意) ──
if (-not $NoPrewarm) {
    Write-Host "Pre-fetching fastmcp into uv cache (optional)..."
    $TmpVenv = Join-Path $McpDir ".prewarm"
    if (Test-Path $TmpVenv) { Remove-Item -Recurse -Force $TmpVenv }
    & uv venv --python $PythonVersion $TmpVenv 2>&1 | Out-Null
    $ok = $LASTEXITCODE -eq 0
    if ($ok) {
        & uv pip install --python "$TmpVenv\Scripts\python.exe" "fastmcp>=3.4,<4" 2>&1 | Out-Null
        $ok = $LASTEXITCODE -eq 0
    }
    if ($ok) { Write-Ok "fastmcp cached" } else { Write-Warn "fastmcp の事前取得に失敗 (初回の登録時にダウンロードされます)" }
    if (Test-Path $TmpVenv) { Remove-Item -Recurse -Force $TmpVenv }
}

# ── .env へ設定を追記 (既存キーは置換、無ければ追記。他の行は触らない) ──
if (-not (Test-Path $EnvFile)) { New-Item -ItemType File -Force -Path $EnvFile | Out-Null }
function Set-EnvLine {
    param($key, $value)
    $lines = @(Get-Content $EnvFile -ErrorAction SilentlyContinue)
    $found = $false
    $out = foreach ($line in $lines) {
        if ($line -match "^$key=") { $found = $true; "$key=$value" } else { $line }
    }
    if (-not $found) { $out = @($out) + "$key=$value" }
    Set-Content -Path $EnvFile -Value ($out -join "`n") -Encoding UTF8
    Add-Content -Path $EnvFile -Value ""
}
Set-EnvLine "MCP_MANAGED_DIR" $McpDir
Set-EnvLine "MCP_MANAGED_AUTO_START" "true"
Set-EnvLine "MCP_PYTHON_VERSION" $PythonVersion

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " Custom MCP runtime installed." -ForegroundColor Green
Write-Host "   uv      : $((Get-Command uv).Source)"
Write-Host "   python  : $PythonVersion (uv managed)"
Write-Host "   mcp dir : $McpDir"
Write-Host ""
Write-Host " 次: 本体を再起動し、「データ > カスタム MCP」から server を作成してください。" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
