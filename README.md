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
# 環境設定（管理者 PowerShell。Linux の apt / macOS の brew 相当。PostgreSQL/pgvector/Ollama 導入）
irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/setup-windows.ps1 | iex
# 本体（通常ユーザー）
irm https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-windows.ps1 | iex
```

### vLLM版 (Linux のみ)

```bash
curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-linux-vllm.sh | bash
```

### Docker (vLLM 既定 / Ollama は `| EDITION=ollama bash`)

```bash
curl -fsSL https://raw.githubusercontent.com/lmlight-app/staging-vite/main/scripts/install-docker.sh | bash
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

# Docker (vLLM 既定 / Ollama は | EDITION=ollama bash)
curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-docker.sh | bash
```

## 本番昇格 (2段階)

```bash
# ① staging の script 編集を dist_vite/scripts へ反映
#    (コピー + URL書換: staging-vite→dist_vite raw, git→R2)
cd /Users/yimai/localenv/staging-vite && ./promote.sh

# ② dist_vite を確認・commit したら、binary + scripts + README を R2 へ配信
cd /Users/yimai/localenv/dist_vite && ./promote.sh
```

> script を直した時は ① が必須（抜くと古い dist scripts が R2 に上がる）。
> binary だけの更新（新タグ）なら ② だけでよい。
