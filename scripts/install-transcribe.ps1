# DigitalBase - Transcription Model Installer
# Whisper モデル (ggml / whisper.cpp 形式) を stt-model\whisper\ に配置する。
# Windows 配布はバイナリ版 (whisper.cpp 同梱) のため、faster-whisper (--gpu) は対象外。
# backend は本体がモデル形式と GPU の有無で自動選択する (.env に GPU 設定は不要)。

param(
    [Parameter(Position=0)]
    [ValidateSet("tiny", "base", "small", "medium", "large")]
    [string]$ModelName = "tiny",
    # 既定言語を .env に書く (ja / en 等。短い発話は指定した方が確実)
    [string]$Lang = ""
)

$ErrorActionPreference = "Stop"

$InstallDir = if ($env:DB_INSTALL_DIR) { $env:DB_INSTALL_DIR } else { "$env:LOCALAPPDATA\db" }
$ModelDir = "$InstallDir\stt-model\whisper"
$EnvFile = "$InstallDir\.env"

# Model definitions
$ModelSizes = @{
    "tiny"   = "75MB"
    "base"   = "145MB"
    "small"  = "480MB"
    "medium" = "1.5GB"
    "large"  = "3.0GB"
}

function Show-Usage {
    Write-Host "使用方法: install-transcribe.ps1 [モデル名] [-Lang <code>]" -ForegroundColor White
    Write-Host ""
    Write-Host "モデル一覧:"
    Write-Host "  tiny   - 75MB  (デフォルト、軽量・高速)"
    Write-Host "  base   - 145MB (バランス型)"
    Write-Host "  small  - 480MB (高精度)"
    Write-Host "  medium - 1.5GB (高精度・GPU推奨)"
    Write-Host "  large  - 3.0GB (最高精度・GPU必須、large-v3)"
    Write-Host ""
    Write-Host "例:"
    Write-Host "  .\install-transcribe.ps1                 # tinyモデルをインストール"
    Write-Host "  .\install-transcribe.ps1 small -Lang ja  # smallモデル + 日本語固定"
    Write-Host ""
    Write-Host "リモート実行:"
    Write-Host '  irm https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/install-transcribe.ps1 | iex'
    Write-Host '  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/install-transcribe.ps1))) -ModelName small -Lang ja'
}

# large uses v3 version
if ($ModelName -eq "large") {
    $ModelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"
    $ModelFile = "$ModelDir\ggml-large-v3.bin"
} else {
    $ModelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$ModelName.bin"
    $ModelFile = "$ModelDir\ggml-$ModelName.bin"
}
$ModelSize = $ModelSizes[$ModelName]

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  DigitalBase 文字起こしモデル インストーラー" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "選択モデル: $ModelName ($ModelSize)" -ForegroundColor White
Write-Host ""

# Check if already installed
if (Test-Path $ModelFile) {
    Write-Host "[OK] モデルは既にインストールされています: $ModelFile" -ForegroundColor Green
    Write-Host ""
    Write-Host "再インストールする場合は、まず以下を削除してください:"
    Write-Host "  Remove-Item -Recurse -Force `"$ModelDir`""
    exit 0
}

# Check install directory
if (-not (Test-Path $InstallDir)) {
    Write-Host "[ERROR] DigitalBase がインストールされていません: $InstallDir" -ForegroundColor Red
    Write-Host "   先に DigitalBase をインストールしてください (別の場所なら `$env:DB_INSTALL_DIR で指定)"
    exit 1
}

# 新しいモデルは作業ディレクトリに取り、揃ってから入れ替える (= 取得に失敗しても既存のモデルを残す)
$StageDir = "$ModelDir.new"
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
$FinalFile = $ModelFile
$ModelFile = Join-Path $StageDir (Split-Path $FinalFile -Leaf)

# Download model
Write-Host "Whisper ${ModelName}モデルをダウンロード中..." -ForegroundColor Yellow
Write-Host "   URL: $ModelUrl"
Write-Host "   サイズ: 約$ModelSize"
Write-Host ""

try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $ModelUrl -OutFile $ModelFile -UseBasicParsing
} catch {
    Write-Host "[ERROR] ダウンロードに失敗しました (既存のモデルはそのまま): $_" -ForegroundColor Red
    Remove-Item -Recurse -Force $StageDir -ErrorAction SilentlyContinue
    exit 1
} finally {
    $ProgressPreference = 'Continue'
}

# 取得できたら入れ替える (= 以前のモデルは残さない)。本体が動いているとモデルファイルが掴まれて消せない
try {
    if (Test-Path $ModelDir) {
        Write-Host "以前のモデルを削除..."
        Remove-Item -Recurse -Force $ModelDir
    }
    Move-Item $StageDir $ModelDir
} catch {
    Write-Host "[ERROR] モデルの入れ替えに失敗しました: $_" -ForegroundColor Red
    Write-Host "   DigitalBase を停止してから再実行してください (取得済みのファイルは $StageDir に残しています)"
    exit 1
}
$ModelFile = $FinalFile

# Update .env (WHISPER_MODEL、任意で WHISPER_LANGUAGE)。install-windows.ps1 と同じ UTF8 で書く
function Set-EnvValue([string]$Key, [string]$Value) {
    if (-not (Test-Path $EnvFile)) { return }
    $envContent = Get-Content $EnvFile -Raw
    if ($envContent -match "(?m)^$Key=") {
        $envContent = $envContent -replace "(?m)^$Key=.*", "$Key=$Value"
    } else {
        $envContent = $envContent.TrimEnd() + "`n$Key=$Value"
    }
    Set-Content -Path $EnvFile -Value ($envContent.TrimEnd() + "`n") -NoNewline -Encoding UTF8
    Write-Host ".envを更新: $Key=$Value"
}
Set-EnvValue "WHISPER_MODEL" $ModelName
if ($Lang) { Set-EnvValue "WHISPER_LANGUAGE" $Lang }

$Size = (Get-Item $ModelFile).Length / 1MB
$SizeStr = "{0:N1} MB" -f $Size
Write-Host ""
Write-Host "[OK] インストール完了!" -ForegroundColor Green
Write-Host "   モデル: $ModelName (whisper.cpp)"
Write-Host "   ファイル: $ModelFile"
Write-Host "   サイズ: $SizeStr"
Write-Host ""
Write-Host "[WARN] DigitalBase の再起動が必須です（再起動しないと旧モデルがキャッシュされ 503 になります）" -ForegroundColor Yellow
Write-Host "   再起動後、管理画面 → ライセンス → 文字起こし で確認できます" -ForegroundColor Cyan
