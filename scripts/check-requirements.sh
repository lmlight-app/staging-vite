#!/bin/bash
# AI Server Requirements Check (Vite Edition - no Node.js required)
command -v psql &>/dev/null && echo "OK: PostgreSQL" || echo "NG: PostgreSQL"
command -v ollama &>/dev/null && echo "OK: Ollama" || echo "NG: Ollama"
