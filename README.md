# LM Light Staging (Vite Edition)

テスト用。CIでビルドしたバイナリをdist_viteのGitHub Releasesから取得してテストします。
確認OK後、promote.shでR2にアップロードして本番反映。

## フロー

```
CI (vite*タグ) → dist_vite GitHub Releases
  ↓ stagingテスト (ここのスクリプト)
  ↓ 確認OK
promote.sh → R2 CDN (本番)
```

## URL構成

| | staging (ここ) | dist_vite (本番) |
|---|---|---|
| バイナリ | dist_vite GitHub Releases | R2 CDN |
| スクリプト | staging-vite raw (ここ) | dist_vite raw |
| db_setup.sh | dist_vite raw | dist_vite raw |

## インストール (staging)

### macOS

```bash
LMLIGHT_BASE_URL=https://github.com/lmlight-app/dist_vite/releases/latest/download \
  curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-macos.sh | bash
```

### Linux

```bash
LMLIGHT_BASE_URL=https://github.com/lmlight-app/dist_vite/releases/latest/download \
  curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-linux.sh | bash
```

### Windows

```powershell
$env:LMLIGHT_BASE_URL = "https://github.com/lmlight-app/dist_vite/releases/latest/download"
irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-windows.ps1 | iex
```

## 本番 curl コマンド (dist_vite → R2)

```bash
# macOS
curl -fsSL https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/install-macos.sh | bash

# Linux
curl -fsSL https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/install-linux.sh | bash

# Windows
irm https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/install-windows.ps1 | iex
```

## 本番昇格

```bash
cd /Users/yimai/localenv/dist_vite
./promote.sh
```
