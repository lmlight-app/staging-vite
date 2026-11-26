#   irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-ocr.ps1 | iex
# OCR for images (Tesseract and the Japanese data). Same as "Install" of OCR in Admin > License.
# Tesseract comes from winget (UB-Mannheim). The language data goes into the DigitalBase folder (tessdata), which needs no administrator.
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$InstallDir = if ($env:DB_INSTALL_DIR) { $env:DB_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "db" }
$TessData = Join-Path $InstallDir "tessdata"
$JpnUrl = "https://github.com/tesseract-ocr/tessdata_fast/raw/main/jpn.traineddata"

function Find-Tesseract {
    $cmd = Get-Command tesseract.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = Join-Path $env:ProgramFiles "Tesseract-OCR\tesseract.exe"
    if (Test-Path $p) { return $p }
    return $null
}

$tesseract = Find-Tesseract
if (-not $tesseract) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] winget was not found. Install Tesseract from https://github.com/UB-Mannheim/tesseract/wiki and run this again" -ForegroundColor Red
        exit 1
    }
    Write-Host "Installing Tesseract (winget)..." -ForegroundColor Yellow
    winget install -e --id UB-Mannheim.TesseractOCR --silent --accept-package-agreements --accept-source-agreements
    $tesseract = Find-Tesseract
    if (-not $tesseract) {
        Write-Host "[ERROR] Tesseract was not found after winget. Check: winget list --id UB-Mannheim.TesseractOCR" -ForegroundColor Red
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path $TessData | Out-Null
$bundled = Join-Path (Split-Path $tesseract -Parent) "tessdata"
foreach ($name in @("eng.traineddata", "osd.traineddata")) {
    $source = Join-Path $bundled $name
    if ((Test-Path $source) -and -not (Test-Path (Join-Path $TessData $name))) { Copy-Item $source $TessData }
}
$jpn = Join-Path $TessData "jpn.traineddata"
if (-not (Test-Path $jpn)) {
    Write-Host "Downloading the Japanese data..." -ForegroundColor Yellow
    Invoke-WebRequest -UseBasicParsing -Uri $JpnUrl -OutFile "$jpn.part"
    Move-Item -Force "$jpn.part" $jpn
}

$langs = & $tesseract --tessdata-dir $TessData --list-langs 2>$null
if (-not ($langs -contains "jpn")) {
    Write-Host "[ERROR] Tesseract cannot read the Japanese data in $TessData" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Installed: $tesseract (Japanese data in $TessData)" -ForegroundColor Green
Write-Host "   Check it in Admin > License > OCR (no restart needed)" -ForegroundColor Cyan
