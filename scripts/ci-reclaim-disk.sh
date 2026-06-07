#!/usr/bin/env bash
# Reclaim disk on space-constrained CI runners after the app bundle is staged.
# Safe to run once `build/dist/Magenta Jam (AU).app` exists and no further compile is needed.

set -euo pipefail

echo "=== Disk before reclaim ==="
df -h .

if [ -d build/dist ]; then
  echo "Removing CMake build tree except build/dist..."
  find build -mindepth 1 -maxdepth 1 ! -name dist -exec rm -rf {} + 2>/dev/null || true
fi

echo "Removing node_modules (UI is already bundled)..."
rm -rf node_modules

echo "Removing local ccache (saved via actions/cache)..."
rm -rf .ccache

echo "Removing Python venv (build finished)..."
rm -rf .venv

# macOS runner images ship large tool caches we do not use after compile.
if [ -n "${AGENT_TOOLSDIRECTORY:-}" ]; then
  for tool in Python Ruby; do
    if [ -d "${AGENT_TOOLSDIRECTORY}/${tool}" ]; then
      echo "Removing ${AGENT_TOOLSDIRECTORY}/${tool}..."
      sudo rm -rf "${AGENT_TOOLSDIRECTORY}/${tool}" || true
    fi
  done
fi

if [ -d /usr/local/share/boost ]; then
  echo "Removing /usr/local/share/boost..."
  sudo rm -rf /usr/local/share/boost || true
fi

echo "=== Disk after reclaim ==="
df -h .
if [ -d build/dist ]; then
  du -sh build/dist/*
fi
