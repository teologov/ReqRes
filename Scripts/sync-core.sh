#!/bin/bash
#
#  sync-core.sh — rebuild XReqResCore and swap it into this repo, with provenance.
#
#  The hand-copy of a 20 MB binary between two repos is how 1.0.4 shipped without
#  the ModelBridge fix: nothing recorded which core commit was inside the binary.
#  This script makes that question answerable with one command, forever.
#
#  Usage:
#    ./Scripts/sync-core.sh                 # build the core, then swap it in
#    ./Scripts/sync-core.sh --no-build      # swap the core's existing Frameworks/ output
#    ./Scripts/sync-core.sh --dry-run       # show what would change, touch nothing
#    ./Scripts/sync-core.sh --allow-dirty   # proceed even if the core tree is dirty
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
set -euo pipefail

SHELL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_ROOT="${CORE_ROOT:-$(cd "${SHELL_ROOT}/../XReqResCore" 2>/dev/null && pwd || true)}"
FRAMEWORK_NAME="XReqResCore.xcframework"
DEST="${SHELL_ROOT}/Sources/${FRAMEWORK_NAME}"
PROVENANCE="${SHELL_ROOT}/Sources/XReqResCore.provenance.json"

DO_BUILD=1
DRY_RUN=0
ALLOW_DIRTY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build)    DO_BUILD=0 ;;
    --dry-run)     DRY_RUN=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\033[0;34m[sync-core]\033[0m %s\n' "$1"; }
ok()   { printf '\033[0;32m[sync-core]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[sync-core]\033[0m %s\n' "$1"; }
die()  { printf '\033[0;31m[sync-core]\033[0m %s\n' "$1" >&2; exit 1; }

# Ask git, not the file system: a clone has a .git folder, but a git worktree
# has a .git FILE pointing into the main checkout, and testing for the folder
# refused every worktree. A folder outside any repository is still refused.
[ -n "${CORE_ROOT}" ] && git -C "${CORE_ROOT}" rev-parse --git-dir >/dev/null 2>&1 \
  || die "Core repo not found. Expected a sibling checkout at ../XReqResCore, or set CORE_ROOT."

# ---------------------------------------------------------------- provenance

CORE_SHA="$(git -C "${CORE_ROOT}" rev-parse HEAD)"
CORE_SHORT="$(git -C "${CORE_ROOT}" rev-parse --short HEAD)"
CORE_BRANCH="$(git -C "${CORE_ROOT}" rev-parse --abbrev-ref HEAD)"
CORE_SUBJECT="$(git -C "${CORE_ROOT}" log -1 --pretty=%s)"

CORE_DIRTY=false
if [ -n "$(git -C "${CORE_ROOT}" status --porcelain --untracked-files=no)" ]; then
  CORE_DIRTY=true
fi

# Unpushed is a WARNING, not a failure: this project deliberately works on local
# branches and pushes only when a release is ready. Provenance records it either way.
CORE_PUSHED=true
if ! git -C "${CORE_ROOT}" merge-base --is-ancestor HEAD "@{upstream}" 2>/dev/null; then
  CORE_PUSHED=false
fi

say "core:   ${CORE_ROOT}"
say "commit: ${CORE_SHORT} (${CORE_BRANCH}) — ${CORE_SUBJECT}"
[ "${CORE_DIRTY}" = true ]  && warn "core working tree is DIRTY — the binary will not match any commit"
[ "${CORE_PUSHED}" = false ] && warn "core commit is NOT pushed — nobody else can reproduce this binary yet"

if [ "${CORE_DIRTY}" = true ] && [ "${ALLOW_DIRTY}" -eq 0 ] && [ "${DRY_RUN}" -eq 0 ]; then
  die "Refusing to embed a binary built from a dirty tree. Commit the core, or pass --allow-dirty."
fi

# ------------------------------------------------- the license signing keys
#
# The core verifies every license answer with the Ed25519 public keys compiled
# from this file. A core with the throwaway DEVELOPMENT keys can never get Pro
# from reqresapp.com, which signs with the production keys, so a release built
# from it would lock out every buyer. The provenance records which set the
# binary trusts: "development", "production", or "none" for a core from before
# the keys. Scripts/core-keys-check.sh, which dev-install.sh runs, passes only
# "production": its --dev-keys admits "development" and its --legacy-core
# "none" (dev-install.sh passes the first, never the second). It also reads
# the embedded binary and refuses a record the binary contradicts: production
# or keyless beside any development key, or development without development
# k1. The cure for either is to re-run this script.
# Read here, before the build, so a bad file fails fast; the built binary is
# checked against it after the build. The declarations have a fixed form:
#     static let keySetName = "production"
#     static let k1 = "<43 base64url characters>"
ENTITLEMENT_KEYS_SOURCE="XReqResCore/LicenseManager/EntitlementKeys.swift"
# The verifier that uses the keys. A core that has it trusts some key set, so
# "none" would be false for it.
ENTITLEMENT_VERIFIER_SOURCE="XReqResCore/LicenseManager/Entitlement.swift"
ENTITLEMENT_KEYS=none
ENTITLEMENT_K1=""

# The build compiles the core's working tree, untracked files included, and
# the dirty check above does not count untracked files. A keys file that is
# not exactly the commit's would put keys in the binary that the provenance
# does not name, so --allow-dirty does not cover this file.
if [ -n "$(git -C "${CORE_ROOT}" status --porcelain --ignored --untracked-files=all -- "${ENTITLEMENT_KEYS_SOURCE}")" ]; then
  if [ "${DRY_RUN}" -eq 1 ]; then
    warn "${ENTITLEMENT_KEYS_SOURCE} in the core's working tree is not ${CORE_SHORT}'s; a real sync refuses this"
  else
    die "${ENTITLEMENT_KEYS_SOURCE} in the core's working tree is not ${CORE_SHORT}'s. Commit or discard the change first: the provenance must name the keys the binary carries."
  fi
fi

if git -C "${CORE_ROOT}" cat-file -e "${CORE_SHA}:${ENTITLEMENT_KEYS_SOURCE}" 2>/dev/null; then
  ENTITLEMENT_KEYS_TEXT="$(git -C "${CORE_ROOT}" show "${CORE_SHA}:${ENTITLEMENT_KEYS_SOURCE}")" \
    || die "could not read ${ENTITLEMENT_KEYS_SOURCE} at ${CORE_SHORT}"
  # The literal assigned by each `static let <name> = "…"`, one line per
  # declaration: two (an #if/#else pair, say) fail the checks below.
  entitlement_literal() {
    printf '%s\n' "${ENTITLEMENT_KEYS_TEXT}" | sed -nE \
      "s#^[[:space:]]*((public|internal|fileprivate|private)[[:space:]]+)?static[[:space:]]+let[[:space:]]+$1[[:space:]]*(:[[:space:]]*String[[:space:]]*)?=[[:space:]]*\"([^\"]*)\"[[:space:]]*(//.*)?\$#\\4#p"
  }
  KEY_SET_NAME="$(entitlement_literal keySetName)"
  ENTITLEMENT_K1="$(entitlement_literal k1)"
  case "${KEY_SET_NAME}" in
    development|production) ;;
    *) die "${ENTITLEMENT_KEYS_SOURCE} at ${CORE_SHORT}: keySetName must be one \"development\" or \"production\" literal, found '${KEY_SET_NAME}'" ;;
  esac
  [[ "${ENTITLEMENT_K1}" =~ ^[A-Za-z0-9_-]{43}$ ]] \
    || die "${ENTITLEMENT_KEYS_SOURCE} at ${CORE_SHORT}: k1 must be one literal of 43 base64url characters, found '${ENTITLEMENT_K1}'"
  ENTITLEMENT_KEYS="${KEY_SET_NAME}"
elif git -C "${CORE_ROOT}" cat-file -e "${CORE_SHA}:${ENTITLEMENT_VERIFIER_SOURCE}" 2>/dev/null; then
  # "none" is only for a core from before the keys. One with the verifier but
  # no keys file where this script looks (moved or renamed) would be recorded
  # as keyless, and core-keys-check could not tell it from a 1.0.x core.
  die "${CORE_SHORT} has ${ENTITLEMENT_VERIFIER_SOURCE} but no ${ENTITLEMENT_KEYS_SOURCE}: the core verifies licenses with keys this script cannot find. Update ENTITLEMENT_KEYS_SOURCE to where the keys moved; never record \"none\" for it."
fi

# ---------------------------------------------------------------------- build

SOURCE_FRAMEWORK="${CORE_ROOT}/Frameworks/${FRAMEWORK_NAME}"

if [ "${DO_BUILD}" -eq 1 ]; then
  if [ "${DRY_RUN}" -eq 1 ]; then
    say "(dry run) would run ${CORE_ROOT}/build-xcframework.sh"
  else
    say "building the core (headless archive + create-xcframework)…"
    ( cd "${CORE_ROOT}" && ./build-xcframework.sh >/dev/null ) \
      || die "core build failed — run ./build-xcframework.sh in ${CORE_ROOT} to see why"
    ok "core built"
  fi
fi

[ -d "${SOURCE_FRAMEWORK}" ] || die "No framework at ${SOURCE_FRAMEWORK}. Run without --no-build."

# ------------------------------------------------------------ interface diff

interface_of() {
  # $1 = xcframework root; prints the arm64 swiftinterface if present
  find "$1" -path "*arm64-apple-macos.swiftinterface" 2>/dev/null | head -1
}

OLD_IFACE="$(interface_of "${DEST}")"
NEW_IFACE="$(interface_of "${SOURCE_FRAMEWORK}")"

if [ -n "${OLD_IFACE}" ] && [ -n "${NEW_IFACE}" ]; then
  # Order-independent comparison: the compiler does not emit declarations in a
  # stable order, so a raw diff is mostly noise.
  norm() { grep -vE '^//|^$' "$1" | sed 's/^ *//;s/ *$//' | sort; }
  REMOVED="$(comm -23 <(norm "${OLD_IFACE}") <(norm "${NEW_IFACE}") | wc -l | tr -d ' ')"
  ADDED="$(comm -13 <(norm "${OLD_IFACE}") <(norm "${NEW_IFACE}") | wc -l | tr -d ' ')"

  say "public API diff vs the embedded binary: -${REMOVED} +${ADDED}"
  if [ "${REMOVED}" != "0" ] || [ "${ADDED}" != "0" ]; then
    # `sed -n 1,25p`, never `| head -25`: head exits after 25 lines, SIGPIPEs
    # the producer, and with `set -o pipefail` + `set -e` the script dies right
    # here — silently, BEFORE the swap. (Third time this trap has bitten this
    # repo; the other two are documented in dev-install.sh.)
    comm -23 <(norm "${OLD_IFACE}") <(norm "${NEW_IFACE}") | sed -n '1,25p' | sed 's/^/    - /'
    comm -13 <(norm "${OLD_IFACE}") <(norm "${NEW_IFACE}") | sed -n '1,25p' | sed 's/^/    + /'
  fi

  # Xcode 26 emits these guards; Xcode 16 cannot parse them, which would raise
  # the minimum Xcode for everyone building this public repo.
  if grep -q 'NonescapableTypes' "${NEW_IFACE}" 2>/dev/null; then
    warn "the new interface contains \$NonescapableTypes guards — consuming this"
    warn "binary now REQUIRES Xcode 26+. Update the README before committing."
  fi
else
  warn "could not compare swiftinterfaces (missing on one side)"
fi

# ---------------------------------------------- the keys in the built binary

if [ "${ENTITLEMENT_KEYS}" != none ]; then
  CORE_BINARY="${SOURCE_FRAMEWORK}/macos-arm64_x86_64/XReqResCore.framework/Versions/A/XReqResCore"
  if [ "${DRY_RUN}" -eq 1 ] && [ "${DO_BUILD}" -eq 1 ]; then
    say "(dry run) would check that the built binary carries k1 of ${ENTITLEMENT_KEYS_SOURCE}"
  else
    # Swift stores a string literal longer than 15 bytes as bytes (shorter ones
    # become instruction immediates), so a 43-character key is found as is:
    # "https://reqresapp.com/api" appears in the core binary twice.
    [ -f "${CORE_BINARY}" ] || die "No core binary at ${CORE_BINARY}"
    LC_ALL=C grep -aqF -- "${ENTITLEMENT_K1}" "${CORE_BINARY}" \
      || die "the built binary does not carry the keys its source names (k1 of ${ENTITLEMENT_KEYS_SOURCE} at ${CORE_SHORT}). Rebuild the core: run without --no-build."
  fi
fi

case "${ENTITLEMENT_KEYS}" in
  production)
    ok "entitlementKeys: production" ;;
  development)
    warn "entitlementKeys: development"
    warn "  !!! This core trusts the throwaway DEVELOPMENT license keys. reqresapp.com"
    warn "  !!! signs with the production keys, so it can never grant Pro to this build,"
    warn "  !!! and a release built from it would lock out every buyer. dev-install.sh"
    warn "  !!! refuses it unless given --dev-keys (a test install, never released)."
    warn "  !!! Release only after the core's ${ENTITLEMENT_KEYS_SOURCE##*/} has the production keys." ;;
  *)
    say "entitlementKeys: none (this core has no license signing keys)" ;;
esac

# ------------------------------------------------ names the core retired
#
# The core's Scripts/retired-markers-check.sh greps a built framework for the
# names of the code the core removed or renamed: its binary for the names in
# the core's Scripts/retired-names.txt, its swiftinterfaces for the public
# ones in Scripts/retired-public-names.txt (both beside the script, in the
# core's checkout). A framework that still carries one was built before the
# core took its current names; the shell follows those names, so such a
# binary would not compile against this shell, and an older shell would
# quietly ship code the core retired. Checked on the framework about to be
# embedded, after the build and before the swap, as the keys are.
RETIRED_MARKERS_CHECK="${CORE_ROOT}/Scripts/retired-markers-check.sh"
if [ "${DRY_RUN}" -eq 1 ] && [ "${DO_BUILD}" -eq 1 ]; then
  say "(dry run) would check the built framework with ${RETIRED_MARKERS_CHECK}"
else
  [ -f "${RETIRED_MARKERS_CHECK}" ] \
    || die "no ${RETIRED_MARKERS_CHECK}: a core without the retired-names check predates the names this shell uses. Sync a core that has it."
  if RETIRED_MARKERS="$(/bin/bash "${RETIRED_MARKERS_CHECK}" "${SOURCE_FRAMEWORK}" 2>&1)"; then
    ok "no retired name in the built framework"
  else
    printf '%s\n' "${RETIRED_MARKERS}" | sed 's/^/    /'
    die "the built framework carries a name the core retired, or the check could not read it (above). Rebuild the core from a commit that has its current names, then run this script again."
  fi
fi

if [ "${DRY_RUN}" -eq 1 ]; then
  say "(dry run) would replace ${DEST}"
  say "(dry run) would write ${PROVENANCE}"
  exit 0
fi

# ----------------------------------------------------------------- the swap

# The framework attaches by ONE relative path, linked+embedded in both targets.
# Updating it is a directory swap — never a pbxproj edit.
say "swapping ${DEST}…"
BACKUP="$(mktemp -d)/${FRAMEWORK_NAME}"
if [ -d "${DEST}" ]; then
  mv "${DEST}" "${BACKUP}"
fi
if ! cp -R "${SOURCE_FRAMEWORK}" "${DEST}"; then
  warn "copy failed — restoring the previous framework"
  rm -rf "${DEST}"
  [ -d "${BACKUP}" ] && mv "${BACKUP}" "${DEST}"
  die "swap aborted"
fi

cat > "${PROVENANCE}" <<EOF
{
  "note": "Written by Scripts/sync-core.sh. Records which XReqResCore commit produced the committed binary — do not edit by hand.",
  "coreCommit": "${CORE_SHA}",
  "coreCommitShort": "${CORE_SHORT}",
  "coreBranch": "${CORE_BRANCH}",
  "coreSubject": $(printf '%s' "${CORE_SUBJECT}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "coreTreeDirty": ${CORE_DIRTY},
  "coreCommitPushed": ${CORE_PUSHED},
  "entitlementKeys": "${ENTITLEMENT_KEYS}",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "builtWith": "$(xcodebuild -version | head -1)",
  "frameworkSizeBytes": $(du -sk "${DEST}" | awk '{print $1 * 1024}')
}
EOF

ok "framework swapped and provenance written"
say "provenance: ${PROVENANCE}"
echo
say "NEXT: clean-build the shell (a stale explicit-modules PCM will otherwise fail),"
say "      then smoke-test rule save/apply before committing."
