#!/bin/zsh
# Archive Hermes Glasses and upload it to App Store Connect (TestFlight).
#
# Usage (from the repo root):
#   tools/release.sh <build-number>          archive, export and upload
#   tools/release.sh <build-number> --dry    archive and export only (no upload)
#
# Needs an App Store Connect app record for com.flowsxr.hermesglasses (Apple
# has no API to create one - do it once on appstoreconnect.apple.com) and an
# API key for team FLOWXR (3U4384584Z). Defaults to the key in
# ~/.appstoreconnect/private_keys; override with ASC_KEY_ID, ASC_ISSUER_ID
# and ASC_KEY_PATH. The build number must be higher than every build already
# uploaded for the current MARKETING_VERSION.
#
# The ElevenLabs key in Config/Secrets.xcconfig is NOT compiled into a
# release unless BUNDLE_VOICE_KEY=1 is set: anything in the bundle can be
# read out of the .ipa by whoever installs it. Without it the app speaks
# with the iPhone voice until a key is pasted in Settings -> Voice.
set -euo pipefail

BUILD=${1:?usage: tools/release.sh <build-number> [--dry]}
DEST=upload
[[ ${2:-} == --dry ]] && DEST=export

KEY_ID=${ASC_KEY_ID:-F26W9MD3G9}
ISSUER=${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect -> Users and Access -> Integrations)}
KEY=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8}
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY"
      -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")

# A release without the Meta app id cannot link to glasses.
grep -qE '^META_APP_ID *= *[0-9]{6,}' Config/Secrets.xcconfig \
  || { echo "Config/Secrets.xcconfig has no real META_APP_ID"; exit 1; }

VOICE=(ELEVENLABS_API_KEY= ELEVENLABS_VOICE_ID=)
if [[ ${BUNDLE_VOICE_KEY:-0} == 1 ]]; then
  VOICE=()
  echo "warning: the ElevenLabs key WILL be inside this build"
fi

OUT=build/release
rm -rf $OUT
xcodebuild archive -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath $OUT/HermesGlasses.xcarchive -derivedDataPath $OUT/dd \
  CURRENT_PROJECT_VERSION=$BUILD "${VOICE[@]}" "${AUTH[@]}" | grep -E 'error:|\*\* ARCHIVE'

cat > $OUT/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>teamID</key><string>3U4384584Z</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>$DEST</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath $OUT/HermesGlasses.xcarchive \
  -exportPath $OUT/export -exportOptionsPlist $OUT/ExportOptions.plist \
  "${AUTH[@]}" | grep -E 'error|\*\* EXPORT|Upload'
echo "done: build $BUILD ($DEST)"
