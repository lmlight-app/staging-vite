# DigitalBase - Text-to-Speech (読み上げ) Engine Installer
# 読み上げ用の音声合成サーバーをこのサーバー機に Docker Desktop で立て、.env の TTS_* を設定する。
#   kokoro   … Kokoro-FastAPI (OpenAI 互換 /v1/audio/speech、Apache-2.0)。多言語、日本語は女性 1 声 (jf_alpha)
#   voicevox … VOICEVOX ENGINE (日本語特化、話者が多い)。話者ごとに利用規約 (クレジット表記等) がある

param(
    [Parameter(Position=0)]
    [ValidateSet("kokoro", "voicevox")]
    [string]$Engine = "kokoro",
    # NVIDIA GPU 版 image を使う (Docker Desktop の WSL2 GPU 対応が必要)
    [switch]$Gpu,
    # 待ち受けポート (既定: kokoro 8880 / voicevox 50021。127.0.0.1 のみで待ち受け)
    [int]$Port = 0
)

$ErrorActionPreference = "Stop"

$InstallDir = if ($env:DB_INSTALL_DIR) { $env:DB_INSTALL_DIR } else { "$env:LOCALAPPDATA\db" }
$EnvFile = "$InstallDir\.env"
$Container = "db-tts"

if ($Engine -eq "kokoro") {
    $InnerPort = 8880
    if ($Port -eq 0) { $Port = 8880 }
    $Image = if ($Gpu) { "ghcr.io/remsky/kokoro-fastapi-gpu:latest" } else { "ghcr.io/remsky/kokoro-fastapi-cpu:latest" }
    $HealthPath = "/v1/audio/voices"
    $BaseUrl = "http://127.0.0.1:$Port/v1"
} else {
    $InnerPort = 50021
    if ($Port -eq 0) { $Port = 50021 }
    $Image = if ($Gpu) { "voicevox/voicevox_engine:nvidia-latest" } else { "voicevox/voicevox_engine:cpu-latest" }
    $HealthPath = "/speakers"
    $BaseUrl = "http://127.0.0.1:$Port"
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  DigitalBase 読み上げエンジン インストーラー" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "エンジン: $Engine ($Image)"
Write-Host "待ち受け: 127.0.0.1:$Port"
Write-Host ""

if (-not (Test-Path $InstallDir)) {
    Write-Host "[ERROR] DigitalBase がインストールされていません: $InstallDir" -ForegroundColor Red
    Write-Host "   先に DigitalBase をインストールしてください (別の場所なら `$env:DB_INSTALL_DIR で指定)"
    exit 1
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Docker が見つかりません。読み上げエンジンは Docker Desktop で動かします。" -ForegroundColor Red
    Write-Host "   https://docs.docker.com/desktop/setup/install/windows-install/"
    Write-Host "   Docker を使えない場合は、OpenAI 互換の読み上げ API を .env で直接指定できます:"
    Write-Host "     TTS_ENGINE=openai  TTS_BASE_URL=<接続先>/v1  TTS_API_KEY=<キー>  TTS_MODEL=<モデル>"
    exit 1
}
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Docker に接続できません。Docker Desktop を起動してから再実行してください" -ForegroundColor Red
    exit 1
}

# 同名コンテナ (= 以前のインストール / 別エンジン) は置き換える
$existing = docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq $Container }
if ($existing) {
    Write-Host "既存の $Container コンテナを置き換えます..."
    docker rm -f $Container | Out-Null
}

Write-Host "image を取得中 (初回は数 GB のダウンロードがあります)..."
docker pull $Image
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] image の取得に失敗しました" -ForegroundColor Red; exit 1 }

Write-Host "コンテナを起動中..."
$runArgs = @("run", "-d", "--name", $Container, "--restart", "unless-stopped")
if ($Gpu) { $runArgs += @("--gpus", "all") }
$runArgs += @("-p", "127.0.0.1:${Port}:${InnerPort}", $Image)
docker @runArgs | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] コンテナの起動に失敗しました" -ForegroundColor Red; exit 1 }

Write-Host "起動を待っています (最大 180 秒)..."
$ready = $false
for ($i = 0; $i -lt 90; $i++) {
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:$Port$HealthPath" -UseBasicParsing -TimeoutSec 5 | Out-Null
        $ready = $true
        break
    } catch {
        Start-Sleep -Seconds 2
    }
}
if (-not $ready) {
    Write-Host "[ERROR] $HealthPath が応答しません。ログを確認してください: docker logs $Container" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] 読み上げエンジンが応答しました" -ForegroundColor Green

function Set-EnvValue([string]$Key, [string]$Value) {
    if (-not (Test-Path $EnvFile)) { New-Item -ItemType File -Path $EnvFile | Out-Null }
    $envContent = Get-Content $EnvFile -Raw
    if ($null -eq $envContent) { $envContent = "" }
    if ($envContent -match "(?m)^$Key=") {
        $envContent = $envContent -replace "(?m)^$Key=.*", "$Key=$Value"
    } else {
        $envContent = $envContent.TrimEnd() + "`n$Key=$Value"
    }
    Set-Content -Path $EnvFile -Value $envContent.TrimEnd() -NoNewline
    Add-Content -Path $EnvFile -Value ""
    Write-Host ".envを更新: $Key=$Value"
}
if ($Engine -eq "kokoro") {
    Set-EnvValue "TTS_ENGINE" "openai"
    Set-EnvValue "TTS_MODEL" "kokoro"
    Set-EnvValue "TTS_VOICE" "jf_alpha"
} else {
    Set-EnvValue "TTS_ENGINE" "voicevox"
    Set-EnvValue "TTS_MODEL" ""
    Set-EnvValue "TTS_VOICE" ""
}
Set-EnvValue "TTS_BASE_URL" $BaseUrl
Set-EnvValue "TTS_API_KEY" ""

Write-Host ""
Write-Host "[OK] インストール完了!" -ForegroundColor Green
Write-Host "   エンジン: $Engine"
Write-Host "   接続先:   $BaseUrl"
Write-Host "   コンテナ: $Container (docker logs $Container / docker rm -f $Container で削除)"
if ($Engine -eq "voicevox") {
    Write-Host ""
    Write-Host "[注意] VOICEVOX の音声は話者ごとに利用規約があります (クレジット表記「VOICEVOX:<話者名>」等)。" -ForegroundColor Yellow
    Write-Host "   業務で使う前に https://voicevox.hiroshiba.jp/ の各話者の規約を確認してください。"
}
Write-Host ""
Write-Host "[WARN] DigitalBase の再起動が必要です (.env の TTS_* は起動時に読み込みます)" -ForegroundColor Yellow
Write-Host "   再起動後、管理画面 → ライセンス → 読み上げ で状態を確認できます。"
