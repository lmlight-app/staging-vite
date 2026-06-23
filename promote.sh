#!/bin/bash
# Promote staging-vite scripts to dist_vite
set -e

STAGING_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${STAGING_DIR}/../dist_vite"

if [ ! -d "$DIST_DIR" ]; then
  echo "Error: dist_vite not found at $DIST_DIR"
  exit 1
fi

echo "Promoting staging-vite → dist_vite"

# Top-level scripts (sh / ps1).
# `cp scripts/*` only copies direct children, so the installer/
# subdir is handled separately below.
cp "$STAGING_DIR/scripts/"*.sh  "$DIST_DIR/scripts/" 2>/dev/null || true
cp "$STAGING_DIR/scripts/"*.ps1 "$DIST_DIR/scripts/" 2>/dev/null || true

# Inno Setup installer (EXE wizard) — .iss + post-install.ps1.
# Without this, edits to installer/ in staging never reach dist_vite.
mkdir -p "$DIST_DIR/scripts/installer"
cp "$STAGING_DIR/scripts/installer/"*.iss "$DIST_DIR/scripts/installer/" 2>/dev/null || true
cp "$STAGING_DIR/scripts/installer/"*.ps1 "$DIST_DIR/scripts/installer/" 2>/dev/null || true

# Update repo URL refs back to dist_vite. Both the top-level scripts
# and the installer's post-install.ps1 reference raw.githubusercontent
# / api.github.com paths that include the org/repo path.
cd "$DIST_DIR/scripts"
for f in *.sh *.ps1; do
  [ -f "$f" ] || continue
  # repo path: staging-vite → dist_vite
  sed -i '' 's|lmlight-app/staging-vite|lmlight-app/dist_vite|g' "$f"
  # binary $BASE_URL: staging は dist_vite の GitHub Releases を見るが、dist(本番) は R2 CDN。
  # macOS / Linux / vLLM の install-*.sh と install-windows.ps1 すべてに適用。
  sed -i '' 's|https://github.com/lmlight-app/dist_vite/releases/latest/download|https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-latest|g' "$f"
  # pgvector $PGVECTOR_URL: staging は dist_vite の pgvector-latest release、dist(本番) は R2 vite-latest
  # (promote(dist→R2) が pgvector-latest の zip を vite-latest に同梱するため binary と同居)。
  sed -i '' 's|https://github.com/lmlight-app/dist_vite/releases/download/pgvector-latest|https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-latest|g' "$f"
  # script の self-reference (= 使い方コメント等の raw.githubusercontent .../main/scripts/X)
  # を R2 CDN (vite-scripts/X) へ。install-docker.sh / install-windows.ps1 等すべてに適用。
  sed -i '' 's|https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/|https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/|g' "$f"
done
for f in installer/*.iss installer/*.ps1; do
  [ -f "$f" ] && sed -i '' 's|lmlight-app/staging-vite|lmlight-app/dist_vite|g' "$f"
done

# install-windows.ps1 has a separate convention: in staging the binary
# $BASE_URL points at dist_vite GitHub Releases (staging tests scripts
# against released binaries), but in dist itself it points at the R2
# CDN. Same for $relaunchUrl (staging → raw GitHub, dist → R2 CDN).
IW="$DIST_DIR/scripts/install-windows.ps1"
if [ -f "$IW" ]; then
  sed -i '' \
    's|"https://github.com/lmlight-app/dist_vite/releases/latest/download"|"https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-latest"|' \
    "$IW"
  # クォート無しのベア URL でマッチ。$relaunchUrl (クォート付き) と
  # ヘッダの「使い方」コメント (クォート無し) の両方を R2 CDN へ書き換える。
  # ここを取りこぼすと本番インストーラが昇格時に staging を再取得してしまう。
  sed -i '' \
    's|https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/install-windows.ps1|https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-windows.ps1|g' \
    "$IW"
fi

echo "Done. Review changes in $DIST_DIR and commit."
