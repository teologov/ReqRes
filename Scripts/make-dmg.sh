#!/bin/bash
#
#  make-dmg.sh: package a notarized, stapled ReqRes.app into the release DMG,
#  laid out like 1.0.4's, from the command line.
#
#  1.0.4's DMG was made with the DMG Canvas app. Its look is three things: the
#  volume name, the window background at .background/dmgcanvas_bg.tiff, and
#  the .DS_Store that Finder reads the window from (its size and place, the
#  icon positions, and an alias to the background that finds it by volume
#  name and path). Scripts/dmg/ holds them as taken from 1.0.4: VOLUME_NAME,
#  background.tiff and DS_Store. The same bytes on a volume of the same name
#  give the same window.
#
#  Usage:
#      Scripts/make-dmg.sh <ReqRes.app> [--out <dir>] [--dev-keys] [--no-notarize]
#                          [--repo <dir>] [--template <dir>] [--profile <name>]
#
#      <ReqRes.app>      the release build, notarized and stapled, built from
#                        the checkout as it stands by Scripts/dev-install.sh
#                        WITHOUT --dev-keys. Package the copy it archived,
#                        which has never run: $TMPDIR/reqres-dev-install/
#                        ReqRes.xcarchive/Products/Applications/ReqRes.app
#                        (dev-install empties that folder when it next runs).
#                        The copy in /Applications works too: the label macOS
#                        gives an app once it has run (com.apple.macl) is
#                        dropped from the copy this script stages, never from
#                        the app you pass.
#      --out <dir>       where the DMG is written (default:
#                        $HOME/Projects/ReqRes/Builds/appcast). Never inside a
#                        checkout of this repository; a DMG of the same name
#                        is never overwritten.
#      --dev-keys        accept an app whose core trusts the DEVELOPMENT
#                        license keys: a test DMG, named
#                        ReqRes-<version>-DEVKEYS.dmg, never to be published
#      --no-notarize     sign the DMG but neither notarize nor staple it: a
#                        test of the pipeline, named ...-UNNOTARIZED.dmg
#      --repo <dir>      the checkout the app was built from: its committed
#                        core and provenance record judge the app's cores, its
#                        project sets the version and build numbers, and its
#                        .env serves the notary fallback (default:
#                        $REQRES_REPO, else the checkout this script sits in,
#                        else the git checkout of the current folder)
#      --template <dir>  background.tiff, DS_Store and VOLUME_NAME (default:
#                        Scripts/dmg beside this script)
#      --profile <name>  the notarytool keychain profile (default:
#                        reqres-notary). When it is unusable, the APPLE_ID and
#                        APP_SPECIFIC_PASSWORD in the checkout's gitignored
#                        .env are used, as Scripts/dev-install.sh does.
#
#  In order, stopping at the first failure:
#    1. --out: outside every checkout of this repository, each of its git
#       worktrees included, and writable;
#    2. the template: 1.0.4's DS_Store only with the volume name it was made
#       on;
#    3. the app: ReqRes (com.oloapps.ReqRes) with its one system extension,
#       the version and build numbers the checkout's project sets, team
#       ZUP9ZNBCHM;
#    4. its cores: Sources/XReqResCore.xcframework and
#       Sources/XReqResCore.provenance.json are committed and unchanged in
#       the checkout (git status, then git hash-object of the record and of
#       the core binary against HEAD's blobs, which no index flag can hide);
#       the app's XReqResCore and its system extension's carry the committed
#       binary's Mach-O UUIDs; core-keys-check.sh clears the record and both
#       cores for the production keys (with --dev-keys: the development keys,
#       and a warning);
#    5. stops a running ReqRes capture before the first step that may reach
#       Apple, the check that the app's certificate is a valid signing
#       identity (trustd may look up its revocation online), so that nothing
#       below reaches Apple through ReqRes's own proxy (checked again before
#       codesign's timestamp, each notary upload, the notary log download
#       and the stapling);
#    6. the app's signature verifies, its ticket is stapled, and Gatekeeper
#       accepts it as Notarized Developer ID;
#    7. stages ReqRes.app (ditto keeps the signature and the ticket; the
#       com.apple.macl and com.apple.quarantine labels of the Mac it ran on
#       are dropped from the staged copy), the Applications symlink, the
#       background and the .DS_Store (copied without extended attributes),
#       and makes a ULFO (lzfse) image holding one APFS volume, as 1.0.4 was;
#    8. signs the DMG with the certificate that signed the app (--timestamp),
#       notarizes and staples it, then asks Gatekeeper and stapler about it;
#    9. mounts it read-only, hidden from Finder, and checks the layout files
#       byte for byte, the symlink, the volume, and the app inside
#       (signature, ticket, Gatekeeper, version, its cores' UUIDs and keys);
#       hdiutil verify checks the image;
#   10. moves it into --out without overwriting anything (a hard link gives
#       it its name, and fails on any name that exists), and prints its
#       size, SHA-256, what it checked and the next steps.
#  Every exit detaches the mount it made and removes its temporary folder;
#  when a volume will not detach, it prints the hdiutil detach -force command
#  and leaves that folder in place.
#
#  core-keys-check.sh clears "production" only for a binary that carries the
#  three production public keys it lists and none of the development keys, so
#  the committed binary, both of the app's cores (step 4) and both cores in
#  the mounted DMG (step 9) are each searched for them. That is the release
#  gate's step 0 on the DMG's own binaries.
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
set -euo pipefail
# An exported CDPATH would make cd print the folder it found, into the paths
# this script reads back from cd.
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ID="com.oloapps.ReqRes"
EXT_BUNDLE_ID="com.oloapps.ReqRes.vpn-tunnel"
TEAM_ID="ZUP9ZNBCHM"
# Finder places the icons by these names, and the .DS_Store's background
# alias looks for this path on a volume named as in VOLUME_NAME: none of them
# may change without a new .DS_Store.
APP_NAME="ReqRes.app"
BACKGROUND_PATH=".background/dmgcanvas_bg.tiff"
CAPTURE_SERVICE="HTTP Packet Capture"
# The core: committed in the checkout beside the record of the license keys
# it trusts, and copied by Xcode into the app and into its system extension.
PROVENANCE_PATH="Sources/XReqResCore.provenance.json"
XCFRAMEWORK_PATH="Sources/XReqResCore.xcframework"
CORE_IN_FRAMEWORK="XReqResCore.framework/Versions/A/XReqResCore"
COMMITTED_CORE_PATH="${XCFRAMEWORK_PATH}/macos-arm64_x86_64/${CORE_IN_FRAMEWORK}"
# The template as taken from ReqRes-1.0.4.dmg (2026-11-01). Other files are
# allowed, but reported: the window is then no longer 1.0.4's.
DS_STORE_SHA256_104="0acbd92ae576b6d3cc17c9d31e67c0fddc2f84e3f42e48be14ee132f933339e2"
BACKGROUND_SHA256_104="5a4bbaf8407828ed52d9b04baa81cb1194b71030b4081da862a92d1f862e305c"
# The volume 1.0.4's .DS_Store was made on: its background alias records
# this name.
VOLUME_NAME_104="ReqRes Installer"

APP=""
OUT=""
DEV_KEYS=0
NOTARIZE=1
REPO="${REQRES_REPO:-}"
TEMPLATE=""
PROFILE="reqres-notary"
SUBMISSION=""

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,2\}//' -e '/^set -euo/d'; }
needs_value() { case "${2:-}" in ""|-*) echo "$1 needs a value" >&2; exit 2 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out)         needs_value "$1" "${2:-}"; OUT="$2"; shift ;;
    --repo)        needs_value "$1" "${2:-}"; REPO="$2"; shift ;;
    --template)    needs_value "$1" "${2:-}"; TEMPLATE="$2"; shift ;;
    --profile)     needs_value "$1" "${2:-}"; PROFILE="$2"; shift ;;
    --dev-keys)    DEV_KEYS=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "unknown option: $1" >&2; exit 2 ;;
    *)             [ -z "${APP}" ] || { echo "one app at most" >&2; exit 2; }; APP="$1" ;;
  esac
  shift
done
[ -n "${APP}" ] || { usage >&2; exit 2; }

say()  { printf '\033[0;34m[make-dmg]\033[0m %s\n' "$1"; }
ok()   { printf '\033[0;32m[make-dmg]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[make-dmg]\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[0;31m[make-dmg]\033[0m %s\n' "$1" >&2; exit 1; }

# A rule this script shares with dev-install.sh: never `cmd | grep -q` under
# pipefail. grep -q exits on the first match, SIGPIPEs cmd, and the pipeline
# then FAILS exactly when the text is there. Output is captured into a
# variable first and matched with case.

sha256() { shasum -a 256 "$1" | awk '{ print $1 }'; }
plist_value() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
first_line() { printf '%s' "${1%%$'\n'*}"; }
# The lines of $1 on one line, separated by commas.
joined() { printf '%s\n' "$1" | awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 }'; }

# ------------------------------------------------------------- paths
#
# Physical paths come from /bin/pwd -P, not from the shell's own pwd -P: on a
# case-insensitive volume the builtin keeps the case it was given, and it
# keeps the /System/Volumes/Data spelling of a firmlinked folder, so one
# folder could compare unequal to itself.

physical_dir() { (cd -- "$1" 2>/dev/null && /bin/pwd -P); }

# The physical path folder $1 would have: its deepest existing folder,
# resolved, then the names still to be made. Fails when those include . or
# .., which only the file system could resolve.
physical_path() {
  local p="$1" rest="" name base
  case "${p}" in /*) ;; *) p="${PWD}/${p}" ;; esac
  while [ ! -d "${p}" ]; do
    name="${p##*/}"
    case "${name}" in
      .|..) return 1 ;;
      "") ;;  # a trailing or doubled slash
      *) rest="/${name}${rest}" ;;
    esac
    p="${p%/*}"
    [ -n "${p}" ] || p="/"
  done
  base="$(physical_dir "${p}")" || return 1
  case "${base}" in
    /) printf '%s' "${rest:-/}" ;;
    *) printf '%s%s' "${base}" "${rest}" ;;
  esac
}

# ------------------------------------------------------ cleanup, mounting

WORK=""
PARTIAL_DIR=""

# True when a volume is mounted at folder $1: the folder is on another device
# than its parent, or the mount table lists it.
is_mounted() {
  local dev parent table
  [ -d "$1" ] || return 1
  dev="$(stat -f %d "$1" 2>/dev/null || true)"
  parent="$(stat -f %d "$1/.." 2>/dev/null || true)"
  [ -z "${dev}" ] || [ "${dev}" = "${parent}" ] || return 0
  table="$(/sbin/mount 2>/dev/null || true)"
  case "${table}" in *" on $1 ("*) return 0 ;; *) return 1 ;; esac
}

# Detaches the image mounted at $1, if any. Only ever the mount point this
# script made: other images stay.
detach() {
  local log=""
  is_mounted "$1" || return 0
  log="$(diskutil eject "$1" 2>&1)" || true
  is_mounted "$1" || return 0
  sleep 2  # Spotlight or a verifier still reading: once more, then force
  log="$(diskutil eject "$1" 2>&1)" || true
  is_mounted "$1" || return 0
  log="$(hdiutil detach -force "$1" 2>&1)" || true
  is_mounted "$1" || return 0
  warn "could not detach $1: ${log}"
  return 1
}

cleanup() {
  local status=$?
  trap '' INT TERM  # a second Ctrl-C must not cut the detach short
  if [ -n "${PARTIAL_DIR}" ] && [ -d "${PARTIAL_DIR}" ]; then rm -rfx "${PARTIAL_DIR:?}"; fi
  if [ -n "${WORK}" ] && [ -d "${WORK}" ]; then
    detach "${WORK}/mnt" || true
    if is_mounted "${WORK}/mnt"; then
      # rm -rf would reach into the volume through its mount point, so the
      # folder stays until the volume is gone.
      warn "a volume is still mounted at ${WORK}/mnt; detach it with: hdiutil detach -force \"${WORK}/mnt\""
      warn "${WORK} was left in place; remove it once that volume is detached"
    else
      rm -rfx "${WORK:?}"
    fi
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Mounts image $1 read-only at $2, invisible to Finder and never opened in
# it. diskutil image attach where it exists (macOS 27 deprecates hdiutil
# attach), hdiutil attach on older systems.
attach_readonly() {
  local log=""
  mkdir -p "$2"
  if diskutil image attach --help >/dev/null 2>&1; then
    log="$(diskutil image attach --readOnly --nobrowse --mountPoint "$2" "$1" 2>&1)" \
      || { printf '%s\n' "${log}" >&2; return 1; }
  else
    log="$(hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$2" "$1" 2>&1)" \
      || { printf '%s\n' "${log}" >&2; return 1; }
  fi
  is_mounted "$2" || { printf '%s\n' "${log}" >&2; return 1; }
}

# The image's format, e.g. ULFO.
image_format() {
  local info=""
  if diskutil image info --help >/dev/null 2>&1; then
    info="$(diskutil image info "$1" 2>/dev/null)" || return 1
    printf '%s\n' "${info}" | awk -F': *' '/^Image Format:/ && !f { print $2; f = 1 }'
  else
    info="$(hdiutil imageinfo "$1" 2>/dev/null)" || return 1
    printf '%s\n' "${info}" | awk -F': *' '/^Format:/ && !f { print $2; f = 1 }'
  fi
}

# ---------------------------------------------------------- capture
#
# ReqRes capturing the Mac's traffic would put the revocation check of the
# app's signing certificate, Apple's checks of the app, codesign's timestamp
# request and the notary service's calls (with their credentials) through
# ReqRes's own proxy. Capture is stopped before the first of them, as
# dev-install.sh does, and checked again before the later ones that start
# after other work (codesign's timestamp, each notary upload, the notary log
# download, the stapling), since it can be started again while this runs.

is_capturing() {
  local status
  status="$(scutil --nc status "${CAPTURE_SERVICE}" 2>/dev/null || true)"
  case "$(first_line "${status}")" in
    Connected|Connecting|Reasserting|Disconnecting) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = what is about to reach Apple, for the message.
stop_capture() {
  is_capturing || return 0
  warn "ReqRes is capturing: $1 must not pass through its proxy. Stopping capture…"
  scutil --nc stop "${CAPTURE_SERVICE}" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    is_capturing || break
    sleep 1
  done
  ! is_capturing || die "capture did not stop: stop it in ReqRes, then run this again"
  ok "capture stopped"
}

# ---------------------------------------------------------- the checkout

is_checkout() { [ -n "$1" ] && [ -x "$1/Scripts/core-keys-check.sh" ] && [ -f "$1/${PROVENANCE_PATH}" ]; }
if [ -z "${REPO}" ]; then
  if is_checkout "${SCRIPT_DIR}/.."; then
    REPO="${SCRIPT_DIR}/.."
  else
    TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if is_checkout "${TOP}"; then REPO="${TOP}"; fi
  fi
fi
is_checkout "${REPO}" \
  || die "no ReqRes checkout to judge the app with: pass --repo <dir> (it needs Scripts/core-keys-check.sh and ${PROVENANCE_PATH})"
REPO="$(physical_dir "${REPO}")" || die "cannot resolve the checkout ${REPO}"
KEYS_CHECK="${REPO}/Scripts/core-keys-check.sh"
PROVENANCE="${REPO}/${PROVENANCE_PATH}"
COMMITTED_CORE="${REPO}/${COMMITTED_CORE_PATH}"
HEAD_SHORT="$(git -C "${REPO}" rev-parse --short HEAD 2>/dev/null || echo '?')"
BRANCH="$(git -C "${REPO}" branch --show-current 2>/dev/null || true)"
say "checkout: ${REPO} at ${HEAD_SHORT} (${BRANCH:-detached HEAD})"

# Every checkout a DMG must stay out of: this one, its main checkout when it
# is a git worktree, the one this script sits in, and every worktree of
# either repository, which can live anywhere. git would offer to commit a
# DMG there, and this repository is public.
CHECKOUTS=("${REPO}")
add_checkout() {
  local p
  p="$(physical_dir "$1")" || return 0
  CHECKOUTS[${#CHECKOUTS[@]}]="${p}"
}
# Adds every worktree of the repository checked out at $1, as git worktree
# list names them: the main checkout and each linked worktree. One whose
# folder is gone is skipped.
add_worktrees_of() {
  local list line
  list="$(git -C "$1" worktree list --porcelain 2>/dev/null)" || return 0
  while IFS= read -r line; do
    case "${line}" in "worktree "*) add_checkout "${line#worktree }" ;; esac
  done <<< "${list}"
}
COMMON_DIR="$(git -C "${REPO}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
case "${COMMON_DIR}" in */.git) add_checkout "${COMMON_DIR%/.git}" ;; esac
if is_checkout "${SCRIPT_DIR}/.."; then add_checkout "${SCRIPT_DIR}/.."; fi
add_worktrees_of "${REPO}"
if is_checkout "${SCRIPT_DIR}/.."; then add_worktrees_of "${SCRIPT_DIR}/.."; fi
# Prints the checkout that physical path $1 lies in; false for none.
checkout_holding() {
  local c
  for c in "${CHECKOUTS[@]}"; do
    case "$1/" in "${c}/"*) printf '%s' "${c}"; return 0 ;; esac
  done
  return 1
}

# ------------------------------------------------------------ the output
#
# Settled before any other work: outside the checkouts, and writable.

DEFAULT_OUT="${HOME:?}/Projects/ReqRes/Builds/appcast"
OUT="${OUT:-${DEFAULT_OUT}}"
OUT_P="$(physical_path "${OUT}")" \
  || die "--out ${OUT}: the folders still to be made may not include . or .."
if HELD_BY="$(checkout_holding "${OUT_P}")"; then
  die "--out ${OUT} is inside the checkout ${HELD_BY}: a DMG never goes where git could pick it up (this repository is public). Pass an --out outside it; the default is ${DEFAULT_OUT}."
fi
mkdir -p "${OUT_P}" 2>/dev/null || die "cannot create the output folder ${OUT_P}"
OUT="$(physical_dir "${OUT_P}")" || die "cannot resolve the output folder ${OUT_P}"
if HELD_BY="$(checkout_holding "${OUT}")"; then
  die "--out resolves to ${OUT}, inside the checkout ${HELD_BY}; nothing was written there"
fi
PROBE="$(mktemp "${OUT}/.make-dmg-write-test.XXXXXX" 2>/dev/null)" \
  || die "cannot write to the output folder ${OUT}"
rm -f "${PROBE}"

# ------------------------------------------------------------ the layout

TEMPLATE="${TEMPLATE:-${SCRIPT_DIR}/dmg}"
for f in DS_Store background.tiff VOLUME_NAME; do
  [ -f "${TEMPLATE}/${f}" ] || die "the layout template is incomplete: ${TEMPLATE} has no ${f} (DS_Store, background.tiff and VOLUME_NAME come from the 1.0.4 DMG)"
done
VOLUME_NAME=""
IFS= read -r VOLUME_NAME < "${TEMPLATE}/VOLUME_NAME" || true
VOLUME_NAME="${VOLUME_NAME%$'\r'}"
[ -n "${VOLUME_NAME}" ] || die "${TEMPLATE}/VOLUME_NAME is empty"
MAGIC="$(dd if="${TEMPLATE}/DS_Store" bs=1 skip=4 count=4 2>/dev/null || true)"
[ "${MAGIC}" = "Bud1" ] || die "${TEMPLATE}/DS_Store is not a Finder .DS_Store"
# What the hand-over says about the window: 1.0.4's only when both files are
# 1.0.4's.
LAYOUT_TEXT="the template's layout (${TEMPLATE}), not 1.0.4's"
if [ "$(sha256 "${TEMPLATE}/DS_Store")" = "${DS_STORE_SHA256_104}" ]; then
  # 1.0.4's background alias records the volume name as a Pascal string (a
  # length byte, then the name) and resolves only on a volume of exactly
  # that name: any other name, even one that contains it, leaves the window
  # without its background.
  [ "${VOLUME_NAME}" = "${VOLUME_NAME_104}" ] \
    || die "${TEMPLATE}/VOLUME_NAME says '${VOLUME_NAME}', but the DS_Store beside it is 1.0.4's, whose background alias records the volume name '${VOLUME_NAME_104}' as a Pascal string (a length byte, then the name) and resolves only on a volume of exactly that name. Use '${VOLUME_NAME_104}', or a .DS_Store made on a volume of the new name."
  if [ "$(sha256 "${TEMPLATE}/background.tiff")" = "${BACKGROUND_SHA256_104}" ]; then
    LAYOUT_TEXT="1.0.4's layout"
    say "layout: 1.0.4's window (template ${TEMPLATE}), volume '${VOLUME_NAME}'"
  else
    warn "layout: 1.0.4's .DS_Store with another background.tiff (template ${TEMPLATE})"
  fi
else
  # Another .DS_Store: its background alias must at least name the volume
  # and the file.
  LC_ALL=C grep -aqF -- "${VOLUME_NAME}" "${TEMPLATE}/DS_Store" \
    || die "${TEMPLATE}/DS_Store never names the volume '${VOLUME_NAME}': its background alias was made for another volume name"
  LC_ALL=C grep -aqF -- "${BACKGROUND_PATH##*/}" "${TEMPLATE}/DS_Store" \
    || die "${TEMPLATE}/DS_Store never names ${BACKGROUND_PATH##*/}: its background alias points elsewhere"
  warn "layout: the template in ${TEMPLATE} is not 1.0.4's; the window will not look like 1.0.4's"
fi

# --------------------------------------------------------------- the app
#
# Read from the bundle only. Nothing here asks Apple anything: that waits
# until capture is known to be off.

[ -d "${APP}" ] || die "no app at ${APP}"
APP="$(physical_dir "${APP}")" || die "cannot resolve the app ${APP}"
INFO="${APP}/Contents/Info.plist"
BID="$(plist_value "${INFO}" CFBundleIdentifier || true)"
[ "${BID}" = "${BUNDLE_ID}" ] || die "${APP} is not ReqRes (bundle id '${BID:-none}', want ${BUNDLE_ID})"
VERSION="$(plist_value "${INFO}" CFBundleShortVersionString || true)"
BUILD="$(plist_value "${INFO}" CFBundleVersion || true)"
case "${VERSION}" in ""|*[!0-9.]*) die "the app's CFBundleShortVersionString '${VERSION}' is not a version" ;; esac
case "${BUILD}" in ""|*[!0-9]*) die "the app's CFBundleVersion '${BUILD}' is not a build number" ;; esac
# One system extension, the capture tunnel. Its build number must be the
# project's too, and its own copy of the core is checked below.
EXT="${APP}/Contents/Library/SystemExtensions/${EXT_BUNDLE_ID}.systemextension"
[ -d "${EXT}" ] || die "the app holds no ${EXT_BUNDLE_ID}.systemextension"
[ "$(plist_value "${EXT}/Contents/Info.plist" CFBundleIdentifier || true)" = "${EXT_BUNDLE_ID}" ] \
  || die "${EXT##*/} is not ${EXT_BUNDLE_ID}"
for e in "${APP}"/Contents/Library/SystemExtensions/*; do
  [ "${e}" = "${EXT}" ] || die "the app holds an unexpected system extension: ${e##*/}"
done
EXT_BUILD="$(plist_value "${EXT}/Contents/Info.plist" CFBundleVersion || true)"
EXT_VERSION="$(plist_value "${EXT}/Contents/Info.plist" CFBundleShortVersionString || echo '?') (${EXT_BUILD:-?})"
say "app: ReqRes ${VERSION} (${BUILD}), extension ${EXT_VERSION}, from ${APP}"

# The checkout's provenance record judges the cores below, so the app must
# be a build this checkout describes: its version and both build numbers
# must be the ones the checkout's project sets.
PBXPROJ="${REPO}/Sources/ReqRes.xcodeproj/project.pbxproj"
[ -f "${PBXPROJ}" ] || die "no ${PBXPROJ} in the checkout"
LC_ALL=C grep -qF "MARKETING_VERSION = ${VERSION};" "${PBXPROJ}" \
  && LC_ALL=C grep -qF "CURRENT_PROJECT_VERSION = ${BUILD};" "${PBXPROJ}" \
  && LC_ALL=C grep -qF "CURRENT_PROJECT_VERSION = ${EXT_BUILD};" "${PBXPROJ}" \
  || die "the app is ${VERSION} (${BUILD}) with extension build ${EXT_BUILD:-?}, but the checkout at ${REPO} sets other numbers: package the app built from this checkout, whose provenance record judges its cores (or pass --repo for the checkout it came from)"

SIG="$(codesign -dvv "${APP}" 2>&1 || true)"
case "${SIG}" in *"TeamIdentifier=${TEAM_ID}"*) ;; *) die "the app is not signed by team ${TEAM_ID}" ;; esac

# --------------------------------------------------------- license keys
#
# A core built with the throwaway DEVELOPMENT keys can never get Pro from
# reqresapp.com, so a DMG of it would lock out every buyer. What is known
# about the keys is known about the committed binary: Scripts/sync-core.sh
# writes the provenance record only after finding, in the binary it built,
# the k1 of the key set it records. So the record and that binary must be
# committed as sync-core.sh left them, the app's cores must BE that binary
# (Xcode copies and re-signs the framework into the app and into its system
# extension, which changes its signature, not its Mach-O UUIDs), and
# core-keys-check.sh then judges the record, the committed binary and both
# copies.

# The Mach-O UUIDs of $1, one "arch UUID" per line, sorted.
uuids_of() {
  local out
  out="$(dwarfdump --uuid "$1" 2>/dev/null)" || return 1
  printf '%s\n' "${out}" | awk '$1 == "UUID:" { a = $3; gsub(/[()]/, "", a); print a, $2 }' | LC_ALL=C sort
}

# Dies unless app $1 (named $2 in messages) holds exactly the two cores
# Xcode puts there, the one in its Frameworks folder and the one in its
# system extension's, each the committed binary.
check_core_copies() {
  local app="$1" what="$2" core got label b
  local app_core="${app}/Contents/Frameworks/${CORE_IN_FRAMEWORK}"
  local ext_core="${app}/Contents/Library/SystemExtensions/${EXT_BUNDLE_ID}.systemextension/Contents/Frameworks/${CORE_IN_FRAMEWORK}"
  for core in "${app_core}" "${ext_core}"; do
    label="${what}/${core#"${app}"/}"
    [ -f "${core}" ] && [ ! -L "${core}" ] \
      || die "no XReqResCore binary at ${label}: the app must carry the core in its Frameworks folder and in its system extension's"
    got="$(uuids_of "${core}" || true)"
    [ -n "${got}" ] || die "could not read the Mach-O UUIDs of ${label} (dwarfdump --uuid)"
    if [ "${got}" != "${COMMITTED_UUIDS}" ]; then
      printf '  %s: %s\n  %s: %s\n' "${COMMITTED_CORE_PATH}" "$(joined "${COMMITTED_UUIDS}")" \
        "${label}" "$(joined "${got}")" >&2
      die "${label} is not the committed core: its Mach-O UUIDs differ (above), so the provenance record does not describe it. Package an app built from this checkout as it stands."
    fi
  done
  while IFS= read -r b; do
    case "${b}" in
      "${app_core}"|"${ext_core}") ;;
      *) die "an unexpected XReqResCore binary inside ${what}: ${b#"${app}"/}" ;;
    esac
  done < <(find "${app}" -name XReqResCore -type f 2>/dev/null)
}

# $1 = 1 for --dev-keys; then the core binaries to judge (the record, with
# the committed binary beside it, is always judged first). Prints
# core-keys-check's lines; 0 when all pass.
keys_check() {
  local flag="" b
  [ "$1" != 1 ] || flag="--dev-keys"
  shift
  "${KEYS_CHECK}" ${flag:+"${flag}"} "${PROVENANCE}" || return 1
  for b in "$@"; do
    "${KEYS_CHECK}" ${flag:+"${flag}"} --binary "${b}" "${PROVENANCE}" || return 1
  done
}

for f in "${PROVENANCE_PATH}" "${COMMITTED_CORE_PATH}"; do
  git -C "${REPO}" ls-files --error-unmatch -- "${f}" >/dev/null 2>&1 \
    || die "${f} is not tracked in the checkout at ${REPO}, so nothing records which license keys it trusts"
done
# --untracked-files=all: a status.showUntrackedFiles=no in the git config
# would otherwise hide a file added inside the xcframework.
DIRTY="$(git -C "${REPO}" --no-optional-locks status --porcelain --untracked-files=all -- "${PROVENANCE_PATH}" "${XCFRAMEWORK_PATH}" 2>&1)" \
  || die "git status failed in ${REPO}, so it is unknown whether its core and provenance record are committed: ${DIRTY}"
if [ -n "${DIRTY}" ]; then
  printf '%s\n' "${DIRTY}" >&2
  die "the checkout's core or its provenance record has uncommitted changes (above): the record describes only the binary Scripts/sync-core.sh wrote it with. Commit what sync-core.sh wrote, or restore both, then run this again."
fi
# git status trusts the index: a file flagged assume-unchanged or
# skip-worktree is reported unchanged whatever its bytes. So the record and
# the binary are also hashed as git would store them (git hash-object) and
# compared with their blobs in HEAD.
for f in "${PROVENANCE_PATH}" "${COMMITTED_CORE_PATH}"; do
  HEAD_BLOB="$(git -C "${REPO}" rev-parse --verify --quiet "HEAD:${f}" 2>/dev/null)" \
    || die "${f} is not in the checkout's HEAD commit (${HEAD_SHORT}), so nothing records which license keys it trusts"
  FILE_BLOB="$(git -C "${REPO}" hash-object -- "${f}" 2>/dev/null)" \
    || die "git hash-object could not read ${f} in the checkout at ${REPO}"
  [ "${FILE_BLOB}" = "${HEAD_BLOB}" ] \
    || die "${f} is not the copy in the checkout's HEAD commit (git hash-object ${FILE_BLOB}, HEAD:${f} ${HEAD_BLOB}), although git status reports it unchanged: an index flag such as assume-unchanged or skip-worktree hides the change (git -C \"${REPO}\" ls-files -v -- ${f} shows it). The record describes only the binary Scripts/sync-core.sh wrote it with: clear the flag, restore the file from HEAD, then run this again."
done
RECORD_CORE="$(plist_value "${PROVENANCE}" coreCommitShort || echo '?')"
RECORD_KEYS="$(plist_value "${PROVENANCE}" entitlementKeys || echo 'none')"
COMMITTED_UUIDS="$(uuids_of "${COMMITTED_CORE}" || true)"
[ -n "${COMMITTED_UUIDS}" ] || die "could not read the Mach-O UUIDs of ${COMMITTED_CORE_PATH} (dwarfdump --uuid)"
check_core_copies "${APP}" "${APP_NAME}"
ok "both cores in the app (its own and its system extension's) are the committed core (record: core ${RECORD_CORE}, keys '${RECORD_KEYS}'): $(joined "${COMMITTED_UUIDS}")"

CORES=("${APP}/Contents/Frameworks/${CORE_IN_FRAMEWORK}" "${EXT}/Contents/Frameworks/${CORE_IN_FRAMEWORK}")
KEY_SET=""
if KEYS_OUT="$(keys_check 0 "${CORES[@]}" 2>&1)"; then
  KEY_SET="production"
  ok "license keys: production, in the record and in both cores (no development key in any of them)"
elif [ "${DEV_KEYS}" -eq 1 ] && KEYS_OUT="$(keys_check 1 "${CORES[@]}" 2>&1)"; then
  KEY_SET="development"
else
  printf '%s\n' "${KEYS_OUT}" >&2
  die "not packaging: the app's license keys are not cleared for release (above). Build the release with the production keys (the core's EntitlementKeys.swift, Scripts/sync-core.sh, then Scripts/dev-install.sh without --dev-keys), or pass --dev-keys for a test DMG that is never published."
fi

never_publish() {
  warn "=========================================================================="
  warn " DEVELOPMENT LICENSE KEYS. This DMG is a test of the pipeline. NEVER"
  warn " publish it: reqresapp.com can never grant Pro to this build. Its name"
  warn " ends in -DEVKEYS so that it cannot be mistaken for the release."
  warn "=========================================================================="
}
if [ "${KEY_SET}" = "development" ]; then
  never_publish
  say "license keys: development, accepted by --dev-keys (the record and both cores)"
fi

# ------------------------------------------------------------- the name

NAME="ReqRes-${VERSION}"
[ "${KEY_SET}" = "production" ] || NAME="${NAME}-DEVKEYS"
[ "${NOTARIZE}" -eq 1 ] || NAME="${NAME}-UNNOTARIZED"
FINAL="${OUT}/${NAME}.dmg"
[ ! -e "${FINAL}" ] && [ ! -L "${FINAL}" ] \
  || die "${FINAL} exists already. A DMG is never overwritten: move it away first."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reqres-make-dmg.XXXXXX")" || die "cannot make a temporary folder"
WORK_P="$(physical_dir "${WORK}")" || die "cannot resolve the temporary folder ${WORK}"
WORK="${WORK_P}"
MNT="${WORK}/mnt"

# ------------------------------------------------- the signing identity
#
# The DMG carries the same Developer ID as the app inside it: the leaf
# certificate of the app's own signature, which must be a valid identity of
# team ZUP9ZNBCHM in this keychain. (Two Developer ID identities can share
# one name, so a name never selects one; the hash does.)

codesign -d --extract-certificates="${WORK}/cert" "${APP}" >/dev/null 2>&1 \
  || die "could not read the app's signing certificates"
FP="$(openssl x509 -inform DER -in "${WORK}/cert0" -noout -fingerprint -sha1 2>/dev/null || true)"
IDENTITY="$(printf '%s' "${FP#*=}" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
case "${IDENTITY}" in
  ""|*[!0-9A-F]*) die "could not read the SHA-1 of the app's signing certificate" ;;
esac
[ "${#IDENTITY}" -eq 40 ] || die "could not read the SHA-1 of the app's signing certificate"
# find-identity -v lists only the identities trustd judges valid, and trustd
# may look up a certificate's revocation online: the first step that can
# reach Apple, so capture is stopped before it.
stop_capture "the signing certificate's revocation check, Apple's checks of the app, codesign's timestamp and the notary upload"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
ID_LINE="$(printf '%s\n' "${IDENTITIES}" | awk -v h="${IDENTITY}" '$2 == h')"
case "${ID_LINE}" in
  *"\"Developer ID Application: "*"(${TEAM_ID})\""*) ;;
  *) die "the certificate that signed the app (${IDENTITY}) is not a valid Developer ID Application identity of team ${TEAM_ID} in this keychain, so the DMG cannot carry the same signature" ;;
esac
CONFIGURED=""
if [ -f "${REPO}/Sources/Config.xcconfig" ]; then
  CONFIGURED="$(awk -F'=' '/^[[:space:]]*REQRES_SIGN_IDENTITY[[:space:]]*=/ { v = $2; gsub(/[[:space:]]/, "", v); last = v } END { print last }' "${REPO}/Sources/Config.xcconfig")"
fi
if [ -n "${CONFIGURED}" ] && [ "${CONFIGURED}" != "${IDENTITY}" ]; then
  warn "Config.xcconfig's REQRES_SIGN_IDENTITY is ${CONFIGURED}, but the app was signed with ${IDENTITY}: the DMG is signed with the app's"
fi
say "signing identity (the app's own certificate): ${IDENTITY}"

# ------------------------------------------- the app, as Apple sees it
#
# Capture was stopped before find-identity, above.

codesign --verify --deep --strict "${APP}" 2>/dev/null \
  || die "the app's signature does not verify (codesign --verify --deep --strict)"
TICKET="$(xcrun stapler validate "${APP}" 2>&1 || true)"
case "${TICKET}" in
  *"The validate action worked!"*) ;;
  *) printf '%s\n' "${TICKET}" >&2; die "the app carries no valid stapled notarization ticket: notarize and staple it first (Scripts/dev-install.sh does)" ;;
esac
GK_APP="$(spctl -a -vv -t exec "${APP}" 2>&1 || true)"
case "${GK_APP}" in
  *": accepted"*"source=Notarized Developer ID"*) ok "the app's signature verifies, its ticket is stapled, and Gatekeeper accepts it: Notarized Developer ID" ;;
  *) printf '%s\n' "${GK_APP}" >&2; die "Gatekeeper does not accept the app as Notarized Developer ID" ;;
esac

# ------------------------------------------------- notary credentials
#
# How notarytool authenticates: the keychain profile, or the .env fallback
# (the same lookup as Scripts/dev-install.sh). Never echo these values.

NOTARY_AUTH=()
NOTARY_ENV=".env"
notary_env_file() {
  local common=""
  if [ -f "${REPO}/.env" ]; then
    printf '%s' "${REPO}/.env"
    return 0
  fi
  common="$(git -C "${REPO}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "${common}" ] && [ -f "${common}/../.env" ] || return 1
  printf '%s' "$(cd "${common}/.." && pwd)/.env"
}
use_env_notary_auth() {
  local apple_id="" app_pw="" env_file=""
  env_file="$(notary_env_file)" || return 1
  apple_id="$(. "${env_file}" >/dev/null 2>&1; printf '%s' "${APPLE_ID:-}")"
  app_pw="$(. "${env_file}" >/dev/null 2>&1; printf '%s' "${APP_SPECIFIC_PASSWORD:-}")"
  [ -n "${apple_id}" ] && [ -n "${app_pw}" ] || return 1
  NOTARY_AUTH=(--apple-id "${apple_id}" --team-id "${TEAM_ID}" --password "${app_pw}")
  NOTARY_ENV="${env_file}"
}
env_password_note() {
  warn "note: the app-specific password is passed to notarytool on its command line, visible to your own processes while the submission runs; the keychain profile avoids that (Scripts/dev-install.sh, ONE-TIME SETUP)"
}
if [ "${NOTARIZE}" -eq 1 ]; then
  if xcrun notarytool history --keychain-profile "${PROFILE}" >/dev/null 2>&1; then
    NOTARY_AUTH=(--keychain-profile "${PROFILE}")
    ok "notarytool profile '${PROFILE}' is usable"
  elif use_env_notary_auth; then
    warn "notarytool profile '${PROFILE}' is unusable; using the Apple ID from ${NOTARY_ENV} instead"
    env_password_note
  else
    die "no usable notarytool profile '${PROFILE}' and no APPLE_ID/APP_SPECIFIC_PASSWORD in the checkout's .env. Store the profile in Terminal (Scripts/dev-install.sh, ONE-TIME SETUP), or pass --no-notarize for a test."
  fi
fi

# -------------------------------------------------------------- staging

STAGE="${WORK}/stage"
mkdir -p "${STAGE}/${BACKGROUND_PATH%/*}"
ditto "${APP}" "${STAGE}/${APP_NAME}"
ln -s /Applications "${STAGE}/Applications"
# cp -X: the template's files enter the image without the extended
# attributes they picked up on the Mac (a quarantine label, for one); only
# their bytes are 1.0.4's.
cp -X "${TEMPLATE}/background.tiff" "${STAGE}/${BACKGROUND_PATH}"
cp -X "${TEMPLATE}/DS_Store" "${STAGE}/.DS_Store"

# Two labels belong to the Mac the app ran on, not to the release:
# com.apple.macl, which macOS puts on an app once it has run (TCC), and
# com.apple.quarantine. ditto copies them, so they are dropped from the
# staged copy. Neither is part of the code signature. (com.apple.provenance,
# on every file, stays: it cannot be removed, and 1.0.4's DMG carried it on
# every file too.)
labels_in() {
  local listing
  listing="$(xattr -r "$1" 2>/dev/null || true)"
  printf '%s\n' "${listing}" | awk '/: com\.apple\.(macl|quarantine)$/'
}
DROPPED=0
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  if xattr -d "${line##*: }" "${line%: *}" 2>/dev/null; then DROPPED=$((DROPPED + 1)); fi
done < <(labels_in "${STAGE}/${APP_NAME}")
LEFT="$(labels_in "${STAGE}/${APP_NAME}")"
[ -z "${LEFT}" ] || warn "these labels could not be dropped from the staged copy: $(joined "${LEFT}")"
[ "${DROPPED}" -eq 0 ] || say "dropped ${DROPPED} machine-local label(s) (com.apple.macl / com.apple.quarantine) from the staged copy"

codesign --verify --deep --strict "${STAGE}/${APP_NAME}" 2>/dev/null \
  || die "the staged copy of the app no longer verifies"
STAGED_TICKET="$(xcrun stapler validate "${STAGE}/${APP_NAME}" 2>&1 || true)"
case "${STAGED_TICKET}" in
  *"The validate action worked!"*) ;;
  *) printf '%s\n' "${STAGED_TICKET}" >&2; die "the staged copy of the app lost its stapled ticket" ;;
esac
ok "staged ${APP_NAME}, Applications -> /Applications, ${BACKGROUND_PATH}, .DS_Store"

# -------------------------------------------------------------- the image
#
# hdiutil create, although macOS 27 calls it deprecated: its suggested
# replacement, diskutil image create from <folder>, leaves the .DS_Store out
# of the image (measured 2026-11-01), which would lose the whole window
# layout. The checks after mounting compare the layout files byte for byte,
# so a later change in either tool fails here, not on a user's screen.

DMG="${WORK}/${NAME}.dmg"
say "creating the image (ULFO, APFS, volume '${VOLUME_NAME}')…"
hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${STAGE}" -format ULFO -fs APFS "${DMG}" \
  >"${WORK}/hdiutil-create.log" 2>&1 \
  || { cat "${WORK}/hdiutil-create.log" >&2; die "hdiutil create failed"; }
[ -f "${DMG}" ] || die "hdiutil create reported success but wrote no image"
FORMAT="$(image_format "${DMG}" || true)"
[ "${FORMAT}" = "ULFO" ] || die "the image's format is '${FORMAT:-unknown}', not ULFO"
ok "created ${NAME}.dmg ($(stat -f %z "${DMG}") bytes, ULFO)"

# ---------------------------------------------------------------- signing

stop_capture "codesign's timestamp request"
SIGN_LOG="$(codesign --sign "${IDENTITY}" --timestamp "${DMG}" 2>&1)" \
  || { printf '%s\n' "${SIGN_LOG}" >&2; die "codesign could not sign the DMG"; }
DMG_SIG="$(codesign -dvv "${DMG}" 2>&1 || true)"
case "${DMG_SIG}" in *"TeamIdentifier=${TEAM_ID}"*) ;; *) die "the DMG's signature does not name team ${TEAM_ID}" ;; esac
case "${DMG_SIG}" in *"Timestamp="*) ;; *) die "the DMG's signature has no secure timestamp" ;; esac
codesign --verify --strict "${DMG}" 2>/dev/null || die "the DMG's signature does not verify"
ok "signed the DMG (Developer ID, team ${TEAM_ID}, timestamped)"

# ------------------------------------------------------- notarizing

notary_submit() {
  stop_capture "the notary upload (with its credentials)"
  xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --timeout 1h --output-format json \
    >"${WORK}/notary.json" 2>"${WORK}/notary.log" || true
}

if [ "${NOTARIZE}" -eq 1 ]; then
  say "submitting the DMG to Apple's notary service (this usually takes a few minutes)…"
  notary_submit "${DMG}"
  # The keychain profile has vanished from the login keychain mid-run
  # before: fall back to .env once instead of failing.
  if [ "${NOTARY_AUTH[0]:-}" = "--keychain-profile" ] \
     && LC_ALL=C grep -qs "No Keychain password item found" "${WORK}/notary.json" "${WORK}/notary.log" \
     && use_env_notary_auth; then
    warn "notarytool profile '${PROFILE}' vanished during the run; resubmitting with the Apple ID from ${NOTARY_ENV}"
    env_password_note
    notary_submit "${DMG}"
  fi
  STATUS="$(plutil -extract status raw -o - "${WORK}/notary.json" 2>/dev/null || true)"
  SUBMISSION="$(plutil -extract id raw -o - "${WORK}/notary.json" 2>/dev/null || true)"
  if [ "${STATUS}" != "Accepted" ]; then
    cat "${WORK}/notary.json" "${WORK}/notary.log" >&2 2>/dev/null || true
    if [ -n "${SUBMISSION}" ]; then
      stop_capture "the notary log download (with its credentials)"
      if xcrun notarytool log "${SUBMISSION}" "${NOTARY_AUTH[@]}" "${WORK}/notary-developer-log.json" >/dev/null 2>&1; then
        warn "Apple's log for submission ${SUBMISSION}:"
        cat "${WORK}/notary-developer-log.json" >&2
      fi
    fi
    die "notarization came back '${STATUS:-without a status}' (submission ${SUBMISSION:-unknown})"
  fi
  ok "notarized: Accepted (submission ${SUBMISSION})"

  stop_capture "the ticket download"
  STAPLE="$(xcrun stapler staple "${DMG}" 2>&1 || true)"
  case "${STAPLE}" in
    *"The staple and validate action worked!"*) ok "stapled the ticket to the DMG" ;;
    *) printf '%s\n' "${STAPLE}" >&2; die "stapling the DMG failed" ;;
  esac
  codesign --verify --strict "${DMG}" 2>/dev/null || die "the DMG's signature does not verify after stapling"
  VALIDATE="$(xcrun stapler validate "${DMG}" 2>&1 || true)"
  case "${VALIDATE}" in
    *"The validate action worked!"*) ok "stapler validate: the DMG's ticket is valid" ;;
    *) printf '%s\n' "${VALIDATE}" >&2; die "stapler validate rejects the DMG" ;;
  esac
fi

GK_DMG="$(spctl -a -t open --context context:primary-signature -vv "${DMG}" 2>&1 || true)"
if [ "${NOTARIZE}" -eq 1 ]; then
  case "${GK_DMG}" in
    *": accepted"*"source=Notarized Developer ID"*) ok "Gatekeeper accepts the DMG: Notarized Developer ID" ;;
    *) printf '%s\n' "${GK_DMG}" >&2; die "Gatekeeper does not accept the DMG as Notarized Developer ID" ;;
  esac
else
  warn "not notarized (--no-notarize); Gatekeeper on the DMG: $(joined "${GK_DMG}")"
fi

# ------------------------------------------------- what is inside it

attach_readonly "${DMG}" "${MNT}" || die "could not mount the new DMG read-only to check it"
VINFO="$(diskutil info "${MNT}" 2>/dev/null || true)"
GOT_NAME="$(printf '%s\n' "${VINFO}" | awk -F': +' '/^ *Volume Name:/ && !f { print $2; f = 1 }')"
GOT_FS="$(printf '%s\n' "${VINFO}" | awk -F': +' '/^ *File System Personality:/ && !f { print $2; f = 1 }')"
[ "${GOT_NAME}" = "${VOLUME_NAME}" ] || die "the volume is named '${GOT_NAME}', not '${VOLUME_NAME}'"
[ "${GOT_FS}" = "APFS" ] || die "the volume's file system is '${GOT_FS}', not APFS"
cmp -s "${MNT}/.DS_Store" "${TEMPLATE}/DS_Store" \
  || die "the image's .DS_Store is missing or differs from the template: the window layout would be lost"
cmp -s "${MNT}/${BACKGROUND_PATH}" "${TEMPLATE}/background.tiff" \
  || die "the image's ${BACKGROUND_PATH} is missing or differs from the template"
[ -L "${MNT}/Applications" ] && [ "$(readlink "${MNT}/Applications")" = "/Applications" ] \
  || die "the image has no Applications symlink to /Applications"
INNER="${MNT}/${APP_NAME}"
[ -d "${INNER}" ] || die "the image holds no ${APP_NAME}"
UNEXPECTED=""
while IFS= read -r entry; do
  case "${entry}" in
    .DS_Store|.background|Applications|"${APP_NAME}") ;;
    .fseventsd|.Trashes) ;;  # the file system's own; hidden, and placed off-window by the .DS_Store
    .*) warn "an unexpected hidden entry at the volume root: ${entry}" ;;
    *) UNEXPECTED="${UNEXPECTED} ${entry}" ;;
  esac
done < <(ls -A "${MNT}")
[ -z "${UNEXPECTED}" ] || die "unexpected entries at the volume root, which the window would show:${UNEXPECTED}"
ok "the volume '${GOT_NAME}' (APFS) holds the template's .DS_Store and background byte for byte, Applications -> /Applications and ${APP_NAME}"

codesign --verify --deep --strict "${INNER}" 2>/dev/null \
  || die "the app inside the DMG does not verify (codesign --verify --deep --strict)"
INNER_TICKET="$(xcrun stapler validate "${INNER}" 2>&1 || true)"
case "${INNER_TICKET}" in
  *"The validate action worked!"*) ;;
  *) printf '%s\n' "${INNER_TICKET}" >&2; die "the app inside the DMG lost its stapled ticket" ;;
esac
INNER_GK="$(spctl -a -vv -t exec "${INNER}" 2>&1 || true)"
case "${INNER_GK}" in
  *": accepted"*"source=Notarized Developer ID"*) ;;
  *) printf '%s\n' "${INNER_GK}" >&2; die "Gatekeeper does not accept the app inside the DMG" ;;
esac
[ "$(plist_value "${INNER}/Contents/Info.plist" CFBundleShortVersionString || true)" = "${VERSION}" ] \
  && [ "$(plist_value "${INNER}/Contents/Info.plist" CFBundleVersion || true)" = "${BUILD}" ] \
  || die "the app inside the DMG is not ${VERSION} (${BUILD})"
check_core_copies "${INNER}" "the DMG's ${APP_NAME}"
INNER_CORES=("${INNER}/Contents/Frameworks/${CORE_IN_FRAMEWORK}"
  "${INNER}/Contents/Library/SystemExtensions/${EXT_BUNDLE_ID}.systemextension/Contents/Frameworks/${CORE_IN_FRAMEWORK}")
INNER_KEYS_FLAG=0
[ "${KEY_SET}" = "production" ] || INNER_KEYS_FLAG=1
KEYS_OUT="$(keys_check "${INNER_KEYS_FLAG}" "${INNER_CORES[@]}" 2>&1)" \
  || { printf '%s\n' "${KEYS_OUT}" >&2; die "the license keys of the cores inside the DMG are not what was checked before"; }
ok "the app inside verifies (deep, strict), keeps its ticket, is accepted by Gatekeeper, is ${VERSION} (${BUILD}), and both its cores are the committed core, cleared for the ${KEY_SET} keys"
detach "${MNT}" || die "could not detach the DMG after checking it"

VERIFY="$(hdiutil verify "${DMG}" 2>&1 || true)"
case "${VERIFY}" in
  *"is VALID"*) ok "hdiutil verify: the image's checksum is valid" ;;
  *) printf '%s\n' "${VERIFY}" >&2; die "hdiutil verify rejects the image" ;;
esac

# ------------------------------------------------------------ hand-over
#
# Into a fresh hidden folder in --out first (the move may copy across
# volumes, and nothing else is in that folder), then given its name beside
# it with a hard link, and the hidden name removed. link(2) refuses any name
# that exists, a dangling symlink included, so nothing is ever replaced, not
# even a file that appears while this runs. (mv -n checks the name first,
# through symlinks, so a dangling one reads as free, then renames over
# whatever is there.) ln -n: plain ln would follow a symlink to a folder at
# that name and put the link inside the folder.

SHA_BUILT="$(sha256 "${DMG}")"
PARTIAL_DIR="$(mktemp -d "${OUT}/.make-dmg.XXXXXX")" || die "cannot write to the output folder ${OUT}"
PARTIAL="${PARTIAL_DIR}/${NAME}.dmg"
mv -n "${DMG}" "${PARTIAL}" || true
[ -f "${PARTIAL}" ] && [ ! -e "${DMG}" ] || die "could not move the DMG into ${OUT}"
APPEARED="${FINAL} appeared while this ran; it was left as it is, and the new DMG was discarded"
[ ! -e "${FINAL}" ] && [ ! -L "${FINAL}" ] || die "${APPEARED}"
if ! LINK_LOG="$(ln -n "${PARTIAL}" "${FINAL}" 2>&1)"; then
  [ ! -e "${FINAL}" ] && [ ! -L "${FINAL}" ] || die "${APPEARED}"
  die "could not give the DMG its name ${FINAL} with a hard link (${LINK_LOG}); the volume of --out must support hard links, as APFS and HFS+ do"
fi
[ -f "${FINAL}" ] && [ ! -L "${FINAL}" ] && [ "${FINAL}" -ef "${PARTIAL}" ] \
  || die "the DMG did not arrive at ${FINAL}"
rm -f "${PARTIAL}"
if rmdir "${PARTIAL_DIR}" 2>/dev/null; then PARTIAL_DIR=""; fi
SHA="$(sha256 "${FINAL}")"
if [ "${SHA}" != "${SHA_BUILT}" ]; then
  rm -f "${FINAL}"
  die "the DMG changed on its way into ${OUT} (SHA-256 ${SHA}, built as ${SHA_BUILT}); it was removed"
fi
SIZE="$(stat -f %z "${FINAL}")"
if [ "${NOTARIZE}" -eq 1 ]; then
  # The image was validated before the move and arrived with the same bytes,
  # so a failure here is a warning.
  FINAL_TICKET="$(xcrun stapler validate "${FINAL}" 2>&1 || true)"
  case "${FINAL_TICKET}" in
    *"The validate action worked!"*) ;;
    *) warn "stapler validate did not confirm the ticket at ${FINAL} (it was valid before the move, with the same SHA-256): $(joined "${FINAL_TICKET}")" ;;
  esac
fi

printf '\n'
ok "${FINAL}"
printf '    ReqRes %s (%s), extension %s\n' "${VERSION}" "${BUILD}" "${EXT_VERSION}"
printf '    %s bytes\n' "${SIZE}"
printf '    SHA-256 %s\n' "${SHA}"
printf '    volume "%s", license keys: %s, notarized: %s\n\n' "${VOLUME_NAME}" "${KEY_SET}" \
  "$([ "${NOTARIZE}" -eq 1 ] && echo "yes, stapled (submission ${SUBMISSION})" || echo no)"

if [ "${KEY_SET}" != "production" ] || [ "${NOTARIZE}" -ne 1 ]; then
  [ "${KEY_SET}" = "production" ] || never_publish
  [ "${NOTARIZE}" -eq 1 ] || warn "NOT NOTARIZED: a test of the pipeline; never publish it."
  exit 0
fi

cat <<EOF
Checked by this script:
  - the app is ${VERSION} (${BUILD}), extension ${EXT_VERSION}: the numbers the checkout
    sets (${REPO} at ${HEAD_SHORT});
  - both its cores (the app's and the system extension's) carry the Mach-O UUIDs of the
    checkout's committed ${XCFRAMEWORK_PATH}, and neither that binary nor
    its provenance record (core ${RECORD_CORE}, keys "${RECORD_KEYS}") has uncommitted
    changes;
  - core-keys-check.sh cleared the record, the committed binary and both cores, in the
    app and again inside the mounted DMG: each carries the three production keys and no
    DEVELOPMENT key;
  - the DMG is signed with ${IDENTITY},
    notarized and stapled (submission ${SUBMISSION}),
    accepted by Gatekeeper, and holds, byte for byte, ${LAYOUT_TEXT}.

NEXT, for the release (nothing above published anything):
  1. Release gate step 0 is the check above: ${PROVENANCE_PATH} says
     "production", and both XReqResCore binaries inside this DMG carry the production
     keys and no development key (core-keys-check.sh, on the mounted image).
  2. Upload the DMG to a DRAFT GitHub release (tags are bare versions, like 1.0.4). The
     target is main's HEAD once it is pushed, without the appcast change (appcast.xml is
     served from main):
       gh release create ${VERSION} "${FINAL}" --repo teologov/ReqRes --draft --title ${VERSION} \\
         --target <the pushed main's HEAD sha> --notes "SHA-256 ${SHA}"
  3. Release gate: the Sparkle update from 1.0.4 to ${VERSION} on a clean Mac or VM, from a
     local appcast; then, once the website signs licences, the same update with a
     licensed 1.0.4, which must keep Pro through it.
  4. The appcast entry: copy the DMG into a folder of its own and run
       "${HOME}/Projects/ReqRes/Tools/Sparkle-2.9.6-bin/generate_appcast" \\
         --download-url-prefix "https://github.com/teologov/ReqRes/releases/download/${VERSION}/" <that folder>
     (it reads the EdDSA key from the login keychain; never run generate_keys without
     arguments), then copy its <item> into the checkout's appcast.xml: sparkle:version
     ${BUILD}, length ${SIZE}.
  5. Publish only after the website signs licences: the draft release first, the appcast
     last (pushing appcast.xml to main offers the update to every installed copy).
EOF
