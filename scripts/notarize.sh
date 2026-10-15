#!/bin/sh
# Builds Recorder.app signed for distribution, notarizes it with Apple, staples
# the ticket, and checks that Gatekeeper accepts it. Prints the app's path.
#
# Uses a notarytool keychain profile (NOTARY_PROFILE, default maxpane-notary,
# which holds the same Developer ID team's credentials). To make your own:
#   xcrun notarytool store-credentials <name> --apple-id <email> --team-id <team> --password <app-specific password>
set -eu
cd "$(dirname "$0")/.."

profile="${NOTARY_PROFILE:-maxpane-notary}"
app="build/Recorder.app"
zip="build/Recorder.zip"

TIMESTAMP=1 scripts/build-app.sh >/dev/null
codesign -dvv "$app" 2>&1 | grep -q '^Authority=Developer ID Application' || {
  echo "notarize: $app isn't signed with a Developer ID Application identity" >&2
  exit 1
}

# notarytool takes a zip, not a bare .app; ditto keeps the bundle intact.
ditto -c -k --keepParent "$app" "$zip"
echo "==> submitting to Apple with profile $profile (takes a few minutes)" >&2
out="$(xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait 2>&1)" || true
echo "$out" >&2
id="$(echo "$out" | awk '/^  id:/ {print $2; exit}')"
if ! echo "$out" | grep -q 'status: Accepted'; then
  [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$profile" >&2
  exit 1
fi
rm -f "$zip"

xcrun stapler staple "$app" >&2
spctl --assess --type execute --verbose=2 "$app" >&2
echo "$app"
