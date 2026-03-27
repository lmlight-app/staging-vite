# LM Light Staging (Vite Edition)

テスト用のスクリプトです。dist_viteの本番リリース前にここで検証します。

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

## 本番昇格

検証完了後、dist_viteにスクリプトをコピー:

```bash
./promote.sh
```
