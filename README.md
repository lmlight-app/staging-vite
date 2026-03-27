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
curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-macos.sh | bash
```

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-linux.sh | bash
```

### Windows

```powershell
irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-windows.ps1 | iex
```

### vLLM版 (Linux のみ)

```bash
curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-linux-vllm.sh | bash
```

## 本番 curl コマンド (dist_vite → R2)

```bash
# macOS
curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-macos.sh | bash

# Linux
curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-linux.sh | bash

# Windows
irm https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-windows.ps1 | iex

# vLLM (Linux)
curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-linux-vllm.sh | bash
```

## 本番昇格

```bash
cd /Users/yimai/localenv/dist_vite
./promote.sh
```
