#!/usr/bin/env bash
# One-time: store Apple notary credentials in your keychain so `build.sh --notarize`
# can submit unattended. Re-running overwrites the stored profile.
#
# You need an APP-SPECIFIC PASSWORD (NOT your Apple ID password):
#   https://account.apple.com → Sign-In and Security → App-Specific Passwords → +
#
# The Team ID is read automatically from your installed Developer ID certificate.
set -euo pipefail

PROFILE="${CLAUDE_USAGE_NOTARY_PROFILE:-claude-usage-notary}"

TEAM="$(security find-identity -v -p codesigning \
        | sed -n 's/.*Developer ID Application: .*(\([A-Z0-9]*\)).*/\1/p' | head -1)"
if [[ -z "$TEAM" ]]; then
    echo "ERROR: no 'Developer ID Application' identity found in your keychain." >&2
    echo "       Install your Developer ID certificate first." >&2
    exit 1
fi

echo "==> Storing notary credentials under profile '$PROFILE' (Team ID $TEAM)."
echo "    You'll be prompted for your Apple ID and an APP-SPECIFIC PASSWORD"
echo "    (create one at https://account.apple.com → Sign-In and Security)."
echo
exec xcrun notarytool store-credentials "$PROFILE" --team-id "$TEAM"
