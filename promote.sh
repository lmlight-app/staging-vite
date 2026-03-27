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

# Copy scripts
cp "$STAGING_DIR/scripts/"* "$DIST_DIR/scripts/"

# Update URLs back to dist_vite
cd "$DIST_DIR/scripts"
for f in *.sh *.ps1; do
  [ -f "$f" ] && sed -i '' 's|lmlight-app/staging-vite|lmlight-app/dist_vite|g' "$f"
done

echo "Done. Review changes in $DIST_DIR and commit."
