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
  [ -f "$f" ] && sed -i '' 's|lmlight-app/staging-vite|lmlight-app/dist_vite|g' "$f"
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
  sed -i '' \
    's|"https://raw.githubusercontent.com/lmlight-app/dist_vite/main/scripts/install-windows.ps1"|"https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-windows.ps1"|' \
    "$IW"
fi

echo "Done. Review changes in $DIST_DIR and commit."
