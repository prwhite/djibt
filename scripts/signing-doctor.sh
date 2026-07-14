#!/bin/bash
# Code-signing preflight for local device builds.
#
# Surfaces, in ~2s, the state that decides whether `make build` can sign for the
# configured team — so a signed-out Apple ID or a missing watch profile is an
# instant diagnosis instead of a failed 5-minute build. Read-only; changes nothing.
#
# The lesson that motivated it: a *cert* for the team can be present while builds
# still fail, because automatic signing also needs that team's Apple ID signed into
# Xcode to CREATE the watch/widget profiles. A cert alone proves nothing — so the
# verdict keys on PROFILES, which can only exist if the account could mint them.
set -uo pipefail
cd "$(dirname "$0")/.."

read_setting() {  # last match wins → a local override beats the committed default
  cat Config/Signing.xcconfig Config/Signing.local.xcconfig 2>/dev/null \
    | grep -E "^[[:space:]]*$1" | tail -1 | sed -E 's/.*=[[:space:]]*//' | tr -d '[:space:]'
}
TEAM=$(read_setting DEVELOPMENT_TEAM)
PREFIX=$(read_setting BUNDLE_ID_PREFIX)

echo "Configured team:   $TEAM"
[ -f Config/Signing.local.xcconfig ] && echo "                   (via local override Config/Signing.local.xcconfig)"
echo "Bundle prefix:     $PREFIX"
echo

echo "1. Signing certs on this machine (team ← cert):"
cert_for_team=no
while IFS= read -r cn; do
  [ -z "$cn" ] && continue
  # The team is the cert's OU. (The parenthetical in the cert's common name is a
  # cert ID, NOT the team — reading that instead is how you end up chasing ghosts.)
  ou=$(security find-certificate -c "$cn" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
        | grep -oE 'OU ?= ?[A-Z0-9]{10}' | sed -E 's/OU ?= ?//' | head -1)
  mark="  "; [ "$ou" = "$TEAM" ] && { mark=" *"; cert_for_team=yes; }
  echo "  $mark ${ou:-??????????}  ($cn)"
done < <(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | sed -E 's/.*"([^"]*)".*/\1/')
echo

# Xcode 16 moved profiles under Developer/Xcode/UserData; older Xcodes used
# MobileDevice. Scan both — reading only the legacy path reports zero profiles on a
# healthy modern machine and produces a confident, wrong verdict.
PROFILE_DIRS=(
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  "$HOME/Library/MobileDevice/Provisioning Profiles"
)
echo "2. Provisioning profiles covering $PREFIX.* (team | app-id | expires):"
watch_profile_for_team=no
found_any=no
for dir in "${PROFILE_DIRS[@]}"; do
  for p in "$dir"/*.mobileprovision; do
    [ -e "$p" ] || continue
    pl=$(security cms -D -i "$p" 2>/dev/null)
    aid=$(echo "$pl" | plutil -extract Entitlements.application-identifier raw - 2>/dev/null)
    case "$aid" in *"$PREFIX"*) ;; *) continue ;; esac
    t=$(echo "$pl" | plutil -extract TeamIdentifier.0 raw - 2>/dev/null)
    exp=$(echo "$pl" | plutil -extract ExpirationDate raw - 2>/dev/null | cut -c1-10)
    echo "   $t | $aid | $exp"
    found_any=yes
    echo "$aid" | grep -q "watchkitapp" && [ "$t" = "$TEAM" ] && watch_profile_for_team=yes
  done
done
[ "$found_any" = no ] && echo "   (none)"
echo

# NOTE: we deliberately do NOT try to list the Apple IDs signed into Xcode.
# Xcode's DVTDeveloperAccountManagerAppleIDLists plist goes stale — it happily
# reports accounts that were REMOVED and omits the one actually signed in, so a
# check built on it confidently reports the opposite of reality. The watch profile
# above is the honest proxy: it can only exist if the account could mint it.

echo "── Verdict ──────────────────────────────────────────────────"
if [ "$cert_for_team" != yes ]; then
  echo "❌ No signing cert for team $TEAM on this machine."
elif [ "$watch_profile_for_team" != yes ]; then
  echo "⚠️  Cert for $TEAM is present, but there's no watch-app profile under it."
  echo "   Automatic signing only mints that profile while the Apple ID owning team"
  echo "   $TEAM is signed into Xcode → Settings → Accounts."
else
  echo "✅ Cert + watch profile for $TEAM present — a signed build should work."
fi
echo
echo "If \`make build\` fails with 'No Account for Team $TEAM' or 'No profiles for"
echo "…watchkitapp', the Apple ID owning team $TEAM is not signed into Xcode. That"
echo "sign-in drops every few weeks on its own, and a lingering cert does NOT cover"
echo "for it. Fix: Xcode → Settings → Accounts → add / re-auth that account, rebuild."
