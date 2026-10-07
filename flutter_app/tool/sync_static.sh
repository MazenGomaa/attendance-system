#!/usr/bin/env bash
# Copies the student/admin pages from the repo's static/ (the single source of
# truth, shared with the Python server) into the app's bundled assets.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p assets/web
cp ../static/*.html ../static/*.js assets/web/
echo "synced $(ls assets/web | wc -l) files into assets/web/"
