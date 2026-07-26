#!/bin/bash
# DigitalBase の GPU 監視 (温度/電力/使用率 overlay) 用に DCGM exporter を導入する。
#
#   curl -fsSL https://pub-a2cab4360f1748cab5ae1c0f12cddc0a.r2.dev/vite-scripts/install-dcgm-exporter.sh | bash
#
# 本家 dcgm-exporter は arm64 (GB10/DGX 系) に apt/バイナリ配布が無いため、
# アプリが読む 5 metric だけを dcgmi で出す最小 exporter を systemd で常駐させる。
# 依存: datacenter-gpu-manager (dcgmi) + python3。ポートは 9400 (アプリ既定と同じ)。
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# ── 前提: DCGM 本体 ────────────────────────────────────────────────
if ! command -v dcgmi >/dev/null 2>&1; then
    echo "[ERROR] dcgmi が見つかりません。先に NVIDIA DCGM を導入してください:" >&2
    echo "  https://developer.nvidia.com/dcgm  (apt: datacenter-gpu-manager-4-cuda13 等)" >&2
    exit 1
fi

echo "[1/4] nvidia-dcgm サービスを有効化"
$SUDO systemctl enable --now nvidia-dcgm

echo "[2/4] exporter 本体を配置 (/usr/local/bin/dcgm-mini-exporter)"
$SUDO tee /usr/local/bin/dcgm-mini-exporter >/dev/null <<'PYEOF'
#!/usr/bin/env python3
# DCGM の主要メトリクスを Prometheus 形式で :9400 に出す最小 exporter。
# DigitalBase が読むのは DCGM_FI_DEV_{GPU_TEMP,POWER_USAGE,GPU_UTIL,FB_USED,FB_FREE}
# の 5 つだけなので、dcgmi dmon を都度叩いて変換する。依存は標準ライブラリのみ。
import re
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 9400
# field id: 150=温度(C) 155=電力(W) 203=GPU利用率(%) 252=FB使用(MiB) 251=FB空き(MiB)
FIELDS = [(150, "DCGM_FI_DEV_GPU_TEMP"), (155, "DCGM_FI_DEV_POWER_USAGE"),
          (203, "DCGM_FI_DEV_GPU_UTIL"), (252, "DCGM_FI_DEV_FB_USED"),
          (251, "DCGM_FI_DEV_FB_FREE")]


def collect() -> str:
    out = subprocess.run(
        ["dcgmi", "dmon", "-e", ",".join(str(f) for f, _ in FIELDS), "-c", "1", "-d", "100"],
        capture_output=True, text=True, timeout=5,
    ).stdout
    lines = []
    for m in re.finditer(r"^GPU\s+(\d+)\s+(.+)$", out, re.M):
        gpu, values = m.group(1), m.group(2).split()
        for (_, name), v in zip(FIELDS, values):
            if v.upper() == "N/A":
                continue  # unified memory 機 (GB10 等) は FB 系が N/A
            lines.append(f'{name}{{gpu="{gpu}"}} {v}')
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404); self.end_headers(); return
        try:
            body = collect().encode()
        except Exception as e:
            self.send_response(500); self.end_headers()
            self.wfile.write(str(e).encode()); return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF
$SUDO chmod 755 /usr/local/bin/dcgm-mini-exporter

echo "[3/4] systemd unit を登録"
$SUDO tee /etc/systemd/system/dcgm-mini-exporter.service >/dev/null <<UNIT
[Unit]
Description=Minimal DCGM Prometheus exporter (:9400, DigitalBase GPU overlay)
After=nvidia-dcgm.service
Requires=nvidia-dcgm.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/dcgm-mini-exporter
Restart=always
RestartSec=5
User=$(id -un 1000 2>/dev/null || echo root)

[Install]
WantedBy=multi-user.target
UNIT
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now dcgm-mini-exporter

echo "[4/4] 動作確認"
sleep 2
if curl -fsS --max-time 5 http://127.0.0.1:9400/metrics | grep -q "^DCGM_FI_"; then
    echo "[OK] http://<このホスト>:9400/metrics で GPU metrics を配信中"
    echo "     モデル管理画面の [更新] で温度/電力が表示されます (DCGM_PORT 既定 9400)"
else
    echo "[WARN] :9400 の応答に DCGM_FI_ がありません。dcgmi discovery -l で GPU 認識を確認してください" >&2
    exit 1
fi
