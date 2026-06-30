#!/bin/bash
# Slice a single master PNG into every macOS AppIcon size.
#
# Usage:  ./scripts/make-icon.sh [path-to-master.png]
# Default master: Sprawl/Resources/AppIcon.png  (a square 1024×1024 PNG you provide)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/Sprawl/Resources/AppIcon.png}"
DEST="$ROOT/Sprawl/Resources/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SRC" ]; then
  echo "No master icon found at: $SRC"
  echo "Put a square 1024×1024 PNG there (or pass a path), then re-run."
  exit 1
fi

gen() { sips -z "$1" "$1" "$SRC" --out "$DEST/$2" >/dev/null; }

gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

echo "Generated 10 icon sizes in AppIcon.appiconset from $(basename "$SRC")."
