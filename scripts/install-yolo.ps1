# AI Server - YOLO Model Installer
# Downloads YOLO model for object detection functionality

param(
    [Parameter(Position=0)]
    [ValidateSet("yolov8n", "yolov8s", "yolov8m", "yolov8l", "yolov8x")]
    [string]$ModelName = "yolov8n"
)

$ErrorActionPreference = "Stop"

$InstallDir = "$env:LOCALAPPDATA\lmlight"
$ModelDir = "$InstallDir\models\yolo"
$EnvFile = "$InstallDir\.env"

# Model definitions
$ModelSizes = @{
    "yolov8n" = "6MB"
    "yolov8s" = "22MB"
    "yolov8m" = "52MB"
    "yolov8l" = "87MB"
    "yolov8x" = "131MB"
}

function Show-Usage {
    Write-Host "使用方法: install-yolo.ps1 [モデル名]" -ForegroundColor White
    Write-Host ""
    Write-Host "モデル一覧:"
    Write-Host "  yolov8n - 6MB   (デフォルト、軽量・高速)"
    Write-Host "  yolov8s - 22MB  (バランス型)"
    Write-Host "  yolov8m - 52MB  (高精度)"
    Write-Host "  yolov8l - 87MB  (高精度・GPU推奨)"
    Write-Host "  yolov8x - 131MB (最高精度・GPU推奨)"
    Write-Host ""
    Write-Host "例:"
    Write-Host "  .\install-yolo.ps1              # yolov8nをインストール"
    Write-Host "  .\install-yolo.ps1 yolov8s      # yolov8sをインストール"
    Write-Host ""
    Write-Host "カスタムモデル:"
    Write-Host "  学習済み .pt ファイルを $ModelDir\ に配置してください"
}

$ModelUrl = "https://github.com/ultralytics/assets/releases/download/v8.3.0/$ModelName.pt"
$ModelFile = "$ModelDir\$ModelName.pt"
$ModelSize = $ModelSizes[$ModelName]

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  AI Server YOLO物体検出モデル インストーラー" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "選択モデル: $ModelName ($ModelSize)" -ForegroundColor White
Write-Host ""

# Check if already installed
if (Test-Path $ModelFile) {
    Write-Host "✅ モデルは既にインストールされています: $ModelFile" -ForegroundColor Green
    Write-Host ""
    Write-Host "再インストールする場合は、まず以下を削除してください:"
    Write-Host "  Remove-Item `"$ModelFile`""
    exit 0
}

# Check install directory
if (-not (Test-Path $InstallDir)) {
    Write-Host "❌ AI Serverがインストールされていません" -ForegroundColor Red
    Write-Host "   先にAI Serverをインストールしてください"
    exit 1
}

# Create model directory (don't remove existing - allow multiple models)
Write-Host "📁 モデルディレクトリを作成: $ModelDir"
New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null

# Download model
Write-Host "📥 YOLO ${ModelName}モデルをダウンロード中..." -ForegroundColor Yellow
Write-Host "   URL: $ModelUrl"
Write-Host "   サイズ: 約$ModelSize"
Write-Host ""

try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $ModelUrl -OutFile $ModelFile -UseBasicParsing
    $ProgressPreference = 'Continue'
} catch {
    Write-Host "❌ ダウンロードに失敗しました: $_" -ForegroundColor Red
    exit 1
}

# Install ultralytics via uv + venv
Write-Host ""
Write-Host "📦 ultralyticsパッケージを確認中..."

# Check if uv is available
$uvPath = $null
if (Get-Command uv -ErrorAction SilentlyContinue) {
    $uvPath = "uv"
} elseif (Test-Path "$env:USERPROFILE\.local\bin\uv.exe") {
    $uvPath = "$env:USERPROFILE\.local\bin\uv.exe"
} else {
    Write-Host "📥 uv をインストール中..."
    irm https://astral.sh/uv/install.ps1 | iex
    if (Test-Path "$env:USERPROFILE\.local\bin\uv.exe") {
        $uvPath = "$env:USERPROFILE\.local\bin\uv.exe"
    } else {
        $uvPath = "uv"
    }
}

$VenvDir = "$InstallDir\.venv"
$VenvPython = "$VenvDir\Scripts\python.exe"

# pyproject.toml があれば uv sync
if (Test-Path "$InstallDir\pyproject.toml") {
    Push-Location $InstallDir
    try {
        & $uvPath run python -c "import ultralytics" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ ultralytics は既にインストール済み" -ForegroundColor Green
        } else {
            Write-Host "📥 ultralytics をインストール中... (uv sync)"
            & $uvPath sync --extra yolo --quiet
        }
    } finally {
        Pop-Location
    }
} else {
    # venv なければ作成
    if (-not (Test-Path $VenvDir)) {
        Write-Host "📥 venv を作成中..."
        & $uvPath venv $VenvDir --quiet
    }

    try {
        & $VenvPython -c "import ultralytics" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ ultralytics は既にインストール済み" -ForegroundColor Green
        } else {
            throw "not installed"
        }
    } catch {
        Write-Host "📥 ultralytics をインストール中... (uv pip install)"
        & $uvPath pip install ultralytics --python $VenvPython --quiet
    }

    # Set VENV_PYTHON in .env
    if (Test-Path $EnvFile) {
        $envContent = Get-Content $EnvFile -Raw
        if ($envContent -match "(?m)^VENV_PYTHON=") {
            $envContent = $envContent -replace "(?m)^VENV_PYTHON=.*", "VENV_PYTHON=$VenvPython"
        } else {
            $envContent += "`nVENV_PYTHON=$VenvPython"
        }
        Set-Content -Path $EnvFile -Value $envContent.TrimEnd() -NoNewline
        Add-Content -Path $EnvFile -Value ""
        Write-Host "📝 .envを更新: VENV_PYTHON=$VenvPython"
    }
}

# Verify download
if (Test-Path $ModelFile) {
    $Size = (Get-Item $ModelFile).Length / 1MB
    $SizeStr = "{0:N1} MB" -f $Size
    Write-Host ""
    Write-Host "✅ インストール完了!" -ForegroundColor Green
    Write-Host "   モデル: $ModelName"
    Write-Host "   ファイル: $ModelFile"
    Write-Host "   サイズ: $SizeStr"
    Write-Host ""
    Write-Host "AI Serverを再起動すると、画像処理ページで物体検出が利用可能になります" -ForegroundColor Cyan
} else {
    Write-Host "❌ ダウンロードに失敗しました" -ForegroundColor Red
    exit 1
}
