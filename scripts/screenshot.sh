#!/bin/zsh
# Capture a window by title to screenshots/<name>.png (needs Screen Recording
# permission for the calling terminal). Usage: scripts/screenshot.sh "gPTP Studio" 01-overview
set -e
TITLE="${1:-gPTP Studio}"
NAME="${2:-shot}"
WID=$(osascript -e "tell app \"System Events\" to get id of front window of (first process whose name is \"$TITLE\")" 2>/dev/null || \
      osascript -e "tell app \"$TITLE\" to id of window 1" 2>/dev/null || echo "")
if [ -z "$WID" ]; then echo "window not found; falling back to interactive capture"; screencapture -i "screenshots/$NAME.png"; exit 0; fi
screencapture -l"$WID" "screenshots/$NAME.png"
echo "saved screenshots/$NAME.png"
