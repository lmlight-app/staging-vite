# LM Light Staging (Vite Edition)

テスト用のスクリプトです。dist_viteの本番リリース前にここで検証します。

## インストール (staging)

バイナリは dist_vite GitHub Releases から取得、スクリプトは dist_vite raw から取得。

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

## 本番との差分

| 項目 | staging-vite | dist_vite (本番) |
|------|-------------|-----------------|
| バイナリ取得 | `github.com/lmlight-app/dist_vite/releases/latest/download` | `pub-a2cab...r2.dev/vite-latest` (R2 CDN) |
| スクリプト取得 | `raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/` | 同左 |
| curl コマンド | `staging-vite/main/scripts/install-*.sh` | `dist_vite/main/scripts/install-*.sh` |

### 本番 curl コマンド (dist_vite)

```bash
# macOS
curl -fsSL https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/install-macos.sh | bash

# Linux
curl -fsSL https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/install-linux.sh | bash

# Windows
irm https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/install-windows.ps1 | iex
```

## 本番昇格

検証完了後、dist_viteにスクリプトをコピー:

```bash
./promote.sh
```
