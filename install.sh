#!/bin/zsh
# Build Peripherals, put it in /Applications and hand it to launchd.
set -e
cd "${0:A:h}"
# Local.env (untracked) can set DEVELOPMENT_TEAM and DEVELOPER_DIR.
[[ -f Local.env ]] && source Local.env
: ${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple team ID, e.g. in Local.env}
export DEVELOPMENT_TEAM
xcodegen generate --quiet
xcodebuild -project Peripherals.xcodeproj -scheme Peripherals -configuration Release \
    -derivedDataPath build -quiet build
app=build/Build/Products/Release/Peripherals.app

# Whatever copy launchd knows about steps down first, so the new one registers cleanly.
for old in /Applications/Peripherals.app build/Build/Products/Debug/Peripherals.app; do
    [[ -d $old ]] && "$old/Contents/MacOS/Peripherals" --unregister || true
done
pkill -x Peripherals || true
rm -rf /Applications/Peripherals.app
cp -R "$app" /Applications/
open /Applications/Peripherals.app
echo "installed /Applications/Peripherals.app"
