#!/bin/zsh
# Builds the app for this Mac ("Designed for iPad") and opens it.
# macOS will not open the bare .app, so it is wrapped: Voice Agent.app/Wrapper/VoiceAgent.app
# plus the symlink WrappedBundle, installed as ~/Applications/Voice Agent.app.
#   ./run-on-mac.sh          build and open
#   ./run-on-mac.sh --open   open the last build without building
set -e
cd "${0:A:h}"
derived="$HOME/Library/Developer/Xcode/DerivedData/VoiceAgent-Mac"
app="$derived/Build/Products/Debug-iphoneos/VoiceAgent.app"

if [[ "$1" != "--open" ]]; then
  xcodebuild -project VoiceAgent.xcodeproj -scheme VoiceAgent -configuration Debug \
    -destination 'platform=macOS,variant=Designed for iPad' \
    -derivedDataPath "$derived" -quiet build
fi
[[ -d "$app" ]] || { echo "No Mac build yet, run ./run-on-mac.sh without --open."; exit 1; }

pkill -x VoiceAgent 2>/dev/null || true
sleep 1
# The copy in ~/Applications opens from Finder, Launchpad and Spotlight like any app.
wrapper="$HOME/Applications/Voice Agent.app"
[[ -L "$wrapper/WrappedBundle" ]] && rm -rf "$wrapper"   # only ever our own wrapper
mkdir -p "$wrapper/Wrapper"
ditto "$app" "$wrapper/Wrapper/VoiceAgent.app"
ln -s Wrapper/VoiceAgent.app "$wrapper/WrappedBundle"
if ! open "$wrapper"; then
  # A wrapper path reused after a rebuild can fail with launchd error 162; a new folder works.
  wrapper="$(mktemp -d "${TMPDIR:-/tmp}/voice-agent-mac.XXXXXX")/Voice Agent.app"
  mkdir -p "$wrapper/Wrapper"
  ditto "$app" "$wrapper/Wrapper/VoiceAgent.app"
  ln -s Wrapper/VoiceAgent.app "$wrapper/WrappedBundle"
  open "$wrapper"
fi
echo "Opened $wrapper"
