#!/bin/bash
#
#  dev-install.sh — build, sign, notarize, staple and install ReqRes to /Applications.
#
#  WHY THIS EXISTS: on macOS 26 with SIP enabled, sysextd will only load a system
#  extension that is Developer ID signed, NOTARIZED, and running from /Applications.
#  `systemextensionsctl developer on` is not an option (it needs SIP disabled), so
#  every test of a code change to the extension has to go through notarization.
#  This makes that a single command.
#
#  ONE-TIME SETUP (do this once, IN AN INTERACTIVE TERMINAL — the keychain write
#  fails with "User interaction is not allowed" from a non-interactive shell):
#      xcrun notarytool store-credentials "reqres-notary" \
#          --apple-id "you@example.com" --team-id ZUP9ZNBCHM \
#          --password "app-specific-password"
#    (an App Store Connect API key works too: --key/--key-id/--issuer)
#  FALLBACK: if the profile is unusable (it vanished from the login keychain once,
#  2026-09-17), the gitignored .env's APPLE_ID + APP_SPECIFIC_PASSWORD are used
#  directly; from a git worktree, the main checkout's .env. Never commit that file.
#
#  Usage:
#      ./Scripts/dev-install.sh                 # full: build, notarize, install
#      ./Scripts/dev-install.sh --no-notarize   # build+install only (will NOT load on Tahoe)
#      ./Scripts/dev-install.sh --profile NAME  # use a different notarytool profile
#      ./Scripts/dev-install.sh --dev-keys      # accept a core with the DEVELOPMENT license
#                                               # keys: a test install, never a release
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${ROOT}/Sources/ReqRes.xcodeproj"
SCHEME="ReqRes"
PROFILE="reqres-notary"
NOTARIZE=1
DEV_KEYS=""
BUILD_DIR="${TMPDIR:-/tmp}/reqres-dev-install"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-notarize) NOTARIZE=0 ;;
    --profile)     PROFILE="$2"; shift ;;
    --dev-keys)    DEV_KEYS=1 ;;
    -h|--help)     sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\033[0;34m[dev-install]\033[0m %s\n' "$1"; }
ok()   { printf '\033[0;32m[dev-install]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[dev-install]\033[0m %s\n' "$1"; }
die()  { printf '\033[0;31m[dev-install]\033[0m %s\n' "$1" >&2; exit 1; }

# ------------------------------------------------------------ preflight

# First, before this script stops a capture, reads the keychain or spends
# minutes archiving: the embedded core must trust the PRODUCTION license keys.
# One built with the throwaway development keys can never get Pro from
# reqresapp.com, which signs with the production keys, so a release built from
# it would lock out every buyer. sync-core.sh records which keys it embedded
# (Sources/XReqResCore.provenance.json); core-keys-check.sh judges the record,
# and the embedded binary beside it, so a hand-copied framework or an edited
# record cannot pass for a production core.
"${ROOT}/Scripts/core-keys-check.sh" ${DEV_KEYS:+--dev-keys} \
  || die "not archiving: the embedded core's license keys are not cleared for release (above). A core with the DEVELOPMENT keys can never get Pro from reqresapp.com, and a release built from it would lock out every buyer. Swap in the production keys (the core's EntitlementKeys.swift, then Scripts/sync-core.sh), or pass --dev-keys for a test install that is never released."

# ReqRes capturing its own build breaks it: codesign fetches a secure timestamp
# from Apple, the running proxy MITMs that request and re-signs it with the ReqRes
# CA, and codesign correctly refuses the substituted certificate. The symptom is
# a baffling "A timestamp was expected but was not found" on a random framework.
if [ "$(scutil --nc status "HTTP Packet Capture" 2>/dev/null | head -1)" = "Connected" ]; then
  warn "ReqRes is CAPTURING right now. codesign cannot obtain a timestamp through"
  warn "its own proxy, so signing will fail. Stopping capture for this build…"
  scutil --nc stop "HTTP Packet Capture" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$(scutil --nc status "HTTP Packet Capture" 2>/dev/null | head -1)" = "Disconnected" ] && break
    sleep 1
  done
  ok "capture stopped"
fi

# How notarytool authenticates: the keychain profile, or the .env fallback.
NOTARY_AUTH=()
# The .env the fallback reads: this checkout's, else, from a git worktree, the
# main checkout's. The file is gitignored, so a worktree has no copy of its own
# (run from a worktree, the fallback used to find nothing although the main
# checkout had one, and the preflight died).
notary_env_file() {
  local common=""
  if [ -f "${ROOT}/.env" ]; then
    printf '%s' "${ROOT}/.env"
    return 0
  fi
  common="$(git -C "${ROOT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "${common}" ] && [ -f "${common}/../.env" ] || return 1
  printf '%s' "$(cd "${common}/.." && pwd)/.env"
}
# Points NOTARY_AUTH at the Apple ID in that .env; false when it has none.
# Never echo these values. NOTARY_ENV names the file, which may be printed.
NOTARY_ENV=".env"
use_env_notary_auth() {
  local apple_id="" app_pw="" env_file=""
  env_file="$(notary_env_file)" || return 1
  apple_id="$(. "${env_file}" >/dev/null 2>&1; printf '%s' "${APPLE_ID:-}")"
  app_pw="$(. "${env_file}" >/dev/null 2>&1; printf '%s' "${APP_SPECIFIC_PASSWORD:-}")"
  [ -n "${apple_id}" ] && [ -n "${app_pw}" ] || return 1
  NOTARY_AUTH=(--apple-id "${apple_id}" --team-id ZUP9ZNBCHM --password "${app_pw}")
  NOTARY_ENV="${env_file}"
}
if [ "${NOTARIZE}" -eq 1 ]; then
  # Fail early and helpfully rather than 15 minutes into a build.
  if xcrun notarytool history --keychain-profile "${PROFILE}" >/dev/null 2>&1; then
    NOTARY_AUTH=(--keychain-profile "${PROFILE}")
    ok "notarytool profile '${PROFILE}' is usable"
  elif use_env_notary_auth; then
    warn "notarytool profile '${PROFILE}' is unusable; using the Apple ID from ${NOTARY_ENV} instead"
  else
    die "No notarytool profile '${PROFILE}' and no APPLE_ID/APP_SPECIFIC_PASSWORD in .env (this checkout's, or the main checkout's from a git worktree). Run the ONE-TIME SETUP at the top of this script, or pass --no-notarize."
  fi
fi

if [ "$(csrutil status 2>/dev/null | grep -c 'enabled')" -gt 0 ] && [ "${NOTARIZE}" -eq 0 ]; then
  warn "SIP is ENABLED and you passed --no-notarize:"
  warn "sysextd will REFUSE to load the extension. Use this only for UI-only work."
fi

# Signing must use the identity the PROVISIONING PROFILES contain — several
# Developer ID identities exist in this keychain and only one can match.
# Picking arbitrarily produces xcodebuild's opaque "profile doesn't include
# signing certificate" error, so resolve it properly and explain any mismatch.
PROFILE_DIR="${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
VALID_HASHES="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2}')"
PROFILE_CERT=""
for f in "${PROFILE_DIR}"/*.provisionprofile; do
  [ -e "$f" ] || continue
  security cms -D -i "$f" > /tmp/.reqres-profile.plist 2>/dev/null || continue
  NAME="$(plutil -extract Name raw /tmp/.reqres-profile.plist 2>/dev/null)"
  case "${NAME}" in
    "ReqRes Developer ID & App Group")
      PROFILE_CERT="$(plutil -extract DeveloperCertificates.0 raw /tmp/.reqres-profile.plist 2>/dev/null \
        | base64 -d 2>/dev/null | openssl x509 -inform DER -noout -fingerprint -sha1 2>/dev/null \
        | sed 's/.*=//; s/://g')"
      ;;
  esac
done
rm -f /tmp/.reqres-profile.plist

if [ -z "${PROFILE_CERT}" ]; then
  die "Could not read the 'ReqRes Developer ID & App Group' provisioning profile from ${PROFILE_DIR}."
fi

VALID_LIST="$(printf '%s\n' ${VALID_HASHES})"
case "
${VALID_LIST}
" in
  *"
${PROFILE_CERT}
"*) PROFILE_CERT_VALID=1 ;;
  *) PROFILE_CERT_VALID=0 ;;
esac
if [ "${PROFILE_CERT_VALID}" -eq 0 ]; then
  EXPIRY="$(security find-identity -p codesigning | grep "${PROFILE_CERT}" | sed 's/.*(\(.*\))/\1/')"
  warn "The ReqRes provisioning profiles reference certificate:"
  warn "    ${PROFILE_CERT}  ${EXPIRY:-(not a valid signing identity)}"
  warn "which is NOT among the valid Developer ID identities in this keychain:"
  printf '%s\n' ${VALID_HASHES} | sed 's/^/        /' >&2
  die "The profiles must be regenerated to embed a current certificate before this app can be signed, notarized, or shipped: re-issue both provisioning profiles at developer.apple.com with a current Developer ID Application certificate selected, then download them (Xcode ▸ Settings ▸ Accounts ▸ Download Manual Profiles)."
fi

IDENTITY_HASH="${PROFILE_CERT}"
say "signing identity (matches the profile): ${IDENTITY_HASH}"
# Three CLI settings are needed together, and each one is load-bearing:
#   CODE_SIGN_IDENTITY  - the project asks for "Developer ID Application" by NAME,
#                         but two certificates share that name; Xcode resolves it to
#                         the one that is NOT in the profile. Pin the hash.
#   CODE_SIGN_STYLE     - CLI settings are GLOBAL and also hit SPM package targets,
#                         which sign automatically; an explicit identity then fails
#                         with "conflicting provisioning settings". Forcing manual
#                         makes them accept it (resource bundles need no profile).
#   DEVELOPMENT_TEAM    - SPM resource bundles have no team of their own.
#   OTHER_CODE_SIGN_FLAGS - forcing manual Developer ID signing onto SPM resource
#                         bundles makes them require a secure timestamp, which
#                         Xcode does not add for them on its own: "A timestamp was
#                         expected but was not found." Required for notarization
#                         anyway, so ask for it everywhere.
# (Same class of trap as the core's CLI archive bug: command-line build settings are
# not scoped to your targets.)

# ---------------------------------------------------------------- build

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

say "archiving (Release)…"
xcodebuild archive \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -archivePath "${BUILD_DIR}/ReqRes.xcarchive" \
  -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM=ZUP9ZNBCHM \
  >"${BUILD_DIR}/archive.log" 2>&1 \
  || { tail -40 "${BUILD_DIR}/archive.log"; die "archive failed — full log: ${BUILD_DIR}/archive.log"; }
ok "archived"

APP="${BUILD_DIR}/ReqRes.xcarchive/Products/Applications/ReqRes.app"
[ -d "${APP}" ] || die "No app in the archive at ${APP}"

# --------------------------------------------------- re-sign nested Sparkle
#
# Xcode copies Sparkle.framework without re-signing the XPC services nested
# inside it, so they keep Sparkle's own signature ("TeamIdentifier=not set")
# and Apple rejects the app: "not signed with a valid Developer ID certificate"
# / "does not include a secure timestamp".
#
# There are TWO copies: one in the app, and one inside the system extension
# (which links Utils, and Utils depends on Sparkle). Both must be fixed.
#
# Signing goes INSIDE-OUT — touching nested code invalidates every signature
# above it — so: XPC services -> framework -> the enclosing bundle, extension
# before app, each enclosing bundle re-signed with its OWN entitlements.
resign() {
  [ -e "$1" ] || return 0
  codesign --force --sign "${IDENTITY_HASH}" --options runtime --timestamp "$@" >/dev/null 2>&1 \
    || warn "could not re-sign $(basename "$1")"
}

resign_sparkle_inside() {
  local sparkle="$1/Contents/Frameworks/Sparkle.framework"
  [ -d "${sparkle}" ] || return 0
  local xpc
  for xpc in "${sparkle}"/Versions/*/XPCServices/*.xpc; do resign "${xpc}"; done
  resign "${sparkle}/Versions/B/Updater.app"
  resign "${sparkle}/Versions/B/Autoupdate"
  resign "${sparkle}"
}

# The sandboxed MCP helper in Contents/MacOS keeps ITS OWN entitlements (app
# sandbox + app group — the group is how it reads the handshake). Its own
# function, called unconditionally: nested inside the Sparkle helper it was
# skipped whenever Sparkle was absent, and the audit below only looked at
# Sparkle's XPC services, so an unhardened helper would have reached
# notarization unnoticed.
resign_mcp_helper() {
  local helper="$1/Contents/MacOS/reqres-mcp"
  [ -f "${helper}" ] || return 0
  codesign -d --entitlements :"${BUILD_DIR}/helper.entitlements" "${helper}" 2>/dev/null \
    || die "could not extract the MCP helper's entitlements"
  resign "${helper}" --entitlements "${BUILD_DIR}/helper.entitlements"
}

say "re-signing nested Sparkle components (app + system extension)…"

EXT_BUNDLE="$(find "${APP}/Contents/Library/SystemExtensions" -maxdepth 1 -name '*.systemextension' 2>/dev/null | head -1)"
if [ -n "${EXT_BUNDLE}" ]; then
  codesign -d --entitlements :"${BUILD_DIR}/ext.entitlements" "${EXT_BUNDLE}" 2>/dev/null \
    || die "could not extract the extension's entitlements"
  resign_sparkle_inside "${EXT_BUNDLE}"
  resign "${EXT_BUNDLE}" --entitlements "${BUILD_DIR}/ext.entitlements"
fi

codesign -d --entitlements :"${BUILD_DIR}/app.entitlements" "${APP}" 2>/dev/null \
  || die "could not extract the app's entitlements"
resign_sparkle_inside "${APP}"
resign_mcp_helper "${APP}"
resign "${APP}" --entitlements "${BUILD_DIR}/app.entitlements"

# Prove it, rather than hoping: no copy may keep Sparkle's own signature.
# (Process substitution, not a pipeline: a pipeline runs the loop in a subshell
# where a non-matching grep trips `set -e` and kills the script silently.)
UNSIGNED=0
while IFS= read -r xpc; do
  # Capture first — see the Gatekeeper note below. Here the pipeline form
  # was actively dangerous: grep -q exits early ON A MATCH, so finding an
  # unsigned service SIGPIPEd codesign, pipefail failed the pipeline, and the
  # `if` concluded the service was fine.
  XPC_INFO="$(codesign -dvv "${xpc}" 2>&1 || true)"
  case "${XPC_INFO}" in *'TeamIdentifier=not set'*) UNSIGNED_HERE=1 ;; *) UNSIGNED_HERE=0 ;; esac
  if [ "${UNSIGNED_HERE}" -eq 1 ]; then
    warn "still unsigned: ${xpc#${APP}/}"
    UNSIGNED=$((UNSIGNED + 1))
  fi
done < <(find "${APP}" -path '*Sparkle.framework*XPCServices/*.xpc' 2>/dev/null)
[ "${UNSIGNED}" -eq 0 ] || die "${UNSIGNED} Sparkle XPC service(s) still unsigned — notarization would fail"
ok "all Sparkle XPC services carry a Developer ID signature"

# Same proof for the MCP helper: Developer ID, hardened runtime, timestamped.
HELPER="${APP}/Contents/MacOS/reqres-mcp"
if [ -f "${HELPER}" ]; then
  HELPER_INFO="$(codesign -dvv "${HELPER}" 2>&1 || true)"
  case "${HELPER_INFO}" in
    *"TeamIdentifier=${TEAM_ID:-ZUP9ZNBCHM}"*) ;;
    *) die "reqres-mcp is not signed with the Developer ID team — notarization would fail" ;;
  esac
  case "${HELPER_INFO}" in
    *'flags='*'runtime'*) ;;
    *) die "reqres-mcp is missing the hardened runtime — notarization would fail" ;;
  esac
  ok "MCP helper is Developer ID signed with the hardened runtime"
fi

codesign --verify --deep --strict "${APP}" 2>/dev/null \
  && ok "app signature verifies after re-signing" \
  || die "app signature broken after re-signing"

# ------------------------------------------------------------- notarize

if [ "${NOTARIZE}" -eq 1 ]; then
  say "zipping for notarization…"
  ditto -c -k --keepParent "${APP}" "${BUILD_DIR}/ReqRes.zip"

  say "submitting to Apple (this usually takes a few minutes)…"
  # Write the log first, THEN inspect it. Piping into `grep -q` makes grep exit on
  # the first match, SIGPIPEs notarytool upstream, and with `pipefail` the whole
  # pipeline reports failure — for a submission Apple actually ACCEPTED.
  xcrun notarytool submit "${BUILD_DIR}/ReqRes.zip" \
    "${NOTARY_AUTH[@]}" --wait 2>&1 | tee "${BUILD_DIR}/notarize.log" || true
  # The keychain profile can vanish DURING a run: on 2026-10-01 the preflight
  # above found it usable and the submit, 12 minutes of archiving later, said
  # "No Keychain password item found" (it vanished the same way on 2026-09-17).
  # Fall back to .env once instead of throwing the build away.
  if [ "${NOTARY_AUTH[0]:-}" = "--keychain-profile" ] \
     && grep -q "No Keychain password item found" "${BUILD_DIR}/notarize.log" \
     && use_env_notary_auth; then
    warn "notarytool profile '${PROFILE}' vanished during the build; resubmitting with the Apple ID from ${NOTARY_ENV}"
    xcrun notarytool submit "${BUILD_DIR}/ReqRes.zip" \
      "${NOTARY_AUTH[@]}" --wait 2>&1 | tee "${BUILD_DIR}/notarize.log" || true
  fi
  if ! grep -q "status: Accepted" "${BUILD_DIR}/notarize.log"; then
    warn "notarization did not come back Accepted. Fetching the log…"
    SUBMISSION="$(grep -m1 '  id:' "${BUILD_DIR}/notarize.log" | awk '{print $2}')"
    [ -n "${SUBMISSION}" ] && xcrun notarytool log "${SUBMISSION}" "${NOTARY_AUTH[@]}" || true
    die "notarization failed — see above"
  fi
  ok "notarized"

  say "stapling…"
  xcrun stapler staple "${APP}" >/dev/null || die "stapling failed"
  ok "stapled"
fi

# -------------------------------------------------------------- install

# A running copy holds its extension; replacing underneath it is how you get a
# stale extension paired with a new app.
if pgrep -x ReqRes >/dev/null 2>&1; then
  say "quitting the running ReqRes…"
  osascript -e 'quit app "ReqRes"' >/dev/null 2>&1 || true
  sleep 2
fi

# macOS swaps an approved system extension only for a HIGHER version; an
# equal one keeps the old binary running behind the new app, silently. Check
# against what macOS knows AND the ReqRes.app about to be replaced (its
# extension may not be activated yet — it will be, after the next reboot).
say "checking the extension version is newer than the one macOS would keep…"
"${ROOT}/Scripts/extension-version-check.sh" --before-install "${APP}" \
  || die "not installing: macOS would keep running the old extension (see above)."

say "installing to /Applications…"
rm -rf /Applications/ReqRes.app
ditto "${APP}" /Applications/ReqRes.app

say "verifying Gatekeeper will accept it…"
# Capture FIRST, then match. `cmd | grep -q` exits the moment grep matches,
# which SIGPIPEs cmd — and under `set -o pipefail` that makes the whole
# pipeline "fail" precisely when the thing we are looking for IS there. That
# bug has now reported a notarization success as a failure once and a
# Gatekeeper-accepted app as rejected once. Never pipe into `grep -q` here.
GATEKEEPER="$(spctl -a -vvv -t exec /Applications/ReqRes.app 2>&1 || true)"
case "${GATEKEEPER}" in
  *accepted*)
    ok "Gatekeeper: accepted"
    ;;
  *)
    warn "Gatekeeper did NOT accept the app — sysextd will refuse the extension."
    printf '%s\n' "${GATEKEEPER}" | head -4 >&2
    ;;
esac

EXT="$(find /Applications/ReqRes.app/Contents/Library/SystemExtensions -maxdepth 1 -name '*.systemextension' 2>/dev/null | head -1)"
if [ -n "${EXT}" ]; then
  ok "extension version: $(plutil -extract CFBundleShortVersionString raw "${EXT}/Contents/Info.plist")/$(plutil -extract CFBundleVersion raw "${EXT}/Contents/Info.plist")"
fi

cat <<EOF

$(ok "installed")

NEXT — approve the extension (a human has to do this part):
  1. open /Applications/ReqRes.app
  2. click Start Monitoring; macOS will say the extension was blocked
  3. System Settings > General > Login Items & Extensions > Network Extensions
     -> enable ReqRes
  4. back in the app, install and TRUST the CA certificate (an install that
     still trusts the old shared "ReqRes CA" is offered its replacement)
  5. start capture FROM THE APP: the app/extension bus is authenticated with
     keys that only the app's start options carry, so a tunnel started from
     System Settings or scutil is refused

If you are REPLACING an already-approved extension, watch that it actually
swaps (the version above must change on disk; a wedged old extension only
goes away with a reboot):
  systemextensionsctl list | grep -i reqres
  log stream --predicate 'process == "sysextd" OR process == "ReqRes"' --info

Then measure what the engine does to real traffic (WebSockets included):
  brew install mkcert && mkcert -install    # once; without it every HTTPS row SKIPs
  Scripts/protocol-matrix.sh --baseline
The matrix's fixture uses an mkcert certificate the root extension trusts.
EOF
