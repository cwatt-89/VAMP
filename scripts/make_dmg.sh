#!/bin/bash
# Packs build/VAMP.app into build/VAMP.dmg: open it, drag VAMP onto Applications. Nothing else to install.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d build/VAMP.app ] || ./scripts/build.sh
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/VAMP.app "$STAGE/VAMP.app"
ln -s /Applications "$STAGE/Applications"
rm -f build/VAMP.dmg
hdiutil create -quiet -volname VAMP -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov build/VAMP.dmg
echo "Built build/VAMP.dmg ($(du -h build/VAMP.dmg | cut -f1))"
