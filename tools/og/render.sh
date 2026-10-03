#!/usr/bin/env bash
# Render a 1200x630 social preview card with headless Chrome.
#   tools/og/render.sh OUTPUT.png "Title" ["Subtitle" ["Eyebrow"]]
# Set CHROME to use a different browser binary, CHROME_FLAGS for extra flags (e.g. --no-sandbox in containers).
set -euo pipefail

out=${1:?usage: render.sh OUTPUT.png "Title" ["Subtitle" ["Eyebrow"]]}
title=${2:?missing title}
subtitle=${3:-}
eyebrow=${4:-}

dir=$(cd "$(dirname "$0")" && pwd)
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }
url="file://$dir/card.html?title=$(enc "$title")&subtitle=$(enc "$subtitle")&eyebrow=$(enc "$eyebrow")"

mkdir -p "$(dirname "$out")"
"${CHROME:-google-chrome}" --headless=new --disable-gpu --hide-scrollbars \
  --allow-file-access-from-files --virtual-time-budget=6000 \
  --window-size=1200,630 ${CHROME_FLAGS:-} --screenshot="$out" "$url" >/dev/null 2>&1
echo "wrote $out"
