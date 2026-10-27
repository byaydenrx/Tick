#!/bin/zsh
# Builds Tick from source and installs it into ~/Applications.
set -e
cd "$(dirname "$0")"
if [[ $(sw_vers -productVersion | cut -d. -f1) -lt 26 ]]; then
  echo "Tick needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."; exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Swift isn't installed. Run: xcode-select --install   (then run this script again)"; exit 1
fi
./build.sh
pkill -x Tick 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Tick.app
cp -R build/Tick.app ~/Applications/
echo "Installed ~/Applications/Tick.app"
open ~/Applications/Tick.app
