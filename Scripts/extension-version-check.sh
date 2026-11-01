#!/bin/bash
#
#  extension-version-check.sh — is the system extension macOS will run the one
#  this build carries?
#
#  macOS replaces an approved system extension only when the new bundle's
#  version is HIGHER than the one it already has. Equal means "same", and the
#  old binary keeps running behind a new app — measured on this Mac, twice.
#  Nothing reports it: the app starts, capture starts, and every result
#  describes the previous engine.
#
#      Scripts/extension-version-check.sh --before-install <new .app>
#          Refuses (exit 1) unless the new bundle's extension is newer than
#          every ReqRes extension macOS knows about AND than the one in the
#          ReqRes.app it is about to replace (which may not be activated yet —
#          it will be, on the next launch after a reboot). dev-install.sh.
#
#      Scripts/extension-version-check.sh --running [<installed .app>]
#          Refuses (exit 1) unless the ACTIVATED extension is the one inside
#          the installed app (default /Applications/ReqRes.app).
#          protocol-matrix.sh, before it measures anything.
#
#      Scripts/extension-version-check.sh --selftest
#          Checks the parsing and the comparison against fixed listings.
#
#  Read-only: it runs `systemextensionsctl list` and reads Info.plists.
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
set -euo pipefail

BUNDLE_ID="com.oloapps.ReqRes.vpn-tunnel"

# "1.1.0/7" — the extension inside an app bundle, or nothing.
bundle_extension_version() {
  local app="$1" ext
  ext="$(find "${app}/Contents/Library/SystemExtensions" -maxdepth 1 -name '*.systemextension' 2>/dev/null | head -1)"
  [ -n "${ext}" ] || return 0
  printf '%s/%s\n' \
    "$(plutil -extract CFBundleShortVersionString raw "${ext}/Contents/Info.plist")" \
    "$(plutil -extract CFBundleVersion raw "${ext}/Contents/Info.plist")"
}

# Every "short/build" macOS lists for ReqRes, one per line; with "activated"
# as the first argument, only the activated ones. Reads the listing on stdin.
listed_versions() {
  local only_activated="${1:-}"
  awk -v id="${BUNDLE_ID}" -v active="${only_activated}" '
    index($0, id " (") {
      if (active == "activated" && index($0, "[activated") == 0) next
      s = substr($0, index($0, id " (") + length(id) + 2)
      print substr(s, 1, index(s, ")") - 1)
    }'
}

# Exit 0 when "a/b" is strictly newer than "c/d": the marketing version
# compared field by field, then the build number.
is_newer() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, A, "/"); split(b, B, "/")
    na = split(A[1] "." A[2], x, "."); nb = split(B[1] "." B[2], y, ".")
    n = na > nb ? na : nb
    for (i = 1; i <= n; i++) {
      xi = (i in x) ? x[i] + 0 : 0; yi = (i in y) ? y[i] + 0 : 0
      if (xi > yi) exit 0
      if (xi < yi) exit 1
    }
    exit 1
  }'
}

# Prints the first known version the new one does not beat; exit 1 if any.
first_not_beaten() {
  local new="$1" known
  while IFS= read -r known; do
    [ -n "${known}" ] || continue
    if ! is_newer "${new}" "${known}"; then
      printf '%s\n' "${known}"
      return 1
    fi
  done
  return 0
}

selftest() {
  local listing failures=0
  listing="$(cat <<'EOF'
*	*	ZUP9ZNBCHM	com.oloapps.ReqRes.vpn-tunnel (1.1.0/6)	vpn-tunnel	[activated enabled]
		ZUP9ZNBCHM	com.oloapps.ReqRes.vpn-tunnel (1.0.5/5)	vpn-tunnel	[terminated waiting to uninstall on reboot]
*	*	ABCDE12345	com.example.vpn.extension (2.0/12)	Example VPN	[activated enabled]
EOF
)"
  check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2', want '$3'"; failures=$((failures + 1)); fi; }
  check "every ReqRes version listed" "$(printf '%s\n' "${listing}" | listed_versions | tr '\n' ' ')" "1.1.0/6 1.0.5/5 "
  check "only the activated one" "$(printf '%s\n' "${listing}" | listed_versions activated | tr '\n' ' ')" "1.1.0/6 "
  check "a higher build is newer" "$(is_newer 1.1.0/7 1.1.0/6 && echo y || echo n)" "y"
  check "the SAME version is not newer" "$(is_newer 1.1.0/6 1.1.0/6 && echo y || echo n)" "n"
  check "a lower marketing version is not newer" "$(is_newer 1.0.9/99 1.1.0/6 && echo y || echo n)" "n"
  check "1.10 is newer than 1.9" "$(is_newer 1.10.0/1 1.9.0/50 && echo y || echo n)" "y"
  check "7 beats everything listed" "$(printf '%s\n' "${listing}" | listed_versions | first_not_beaten 1.1.0/7 >/dev/null && echo y || echo n)" "y"
  check "6 does not beat the activated 6" "$(printf '%s\n' "${listing}" | listed_versions | first_not_beaten 1.1.0/6 || true)" "1.1.0/6"
  [ "${failures}" -eq 0 ] || { echo "${failures} failed"; exit 1; }
  echo "all passed"
}

case "${1:-}" in
  --selftest)
    selftest ;;
  --before-install)
    NEW_APP="${2:?--before-install needs the new ReqRes.app}"
    NEW="$(bundle_extension_version "${NEW_APP}")"
    [ -n "${NEW}" ] || { echo "no system extension inside ${NEW_APP}" >&2; exit 1; }
    KNOWN="$(systemextensionsctl list 2>/dev/null | listed_versions || true)"
    INSTALLED="$(bundle_extension_version /Applications/ReqRes.app || true)"
    if ! STUCK="$(printf '%s\n%s\n' "${KNOWN}" "${INSTALLED}" | first_not_beaten "${NEW}")"; then
      echo "the new build's extension is ${NEW}, but macOS already has (or is about to activate) ${STUCK}." >&2
      echo "macOS keeps an extension whose version is not HIGHER, so the old engine would keep running." >&2
      echo "Raise CURRENT_PROJECT_VERSION of the vpn-tunnel target (and the app's) and build again." >&2
      exit 1
    fi
    echo "extension ${NEW} is newer than every ReqRes extension macOS knows about"
    ;;
  --running)
    APP="${2:-/Applications/ReqRes.app}"
    WANT="$(bundle_extension_version "${APP}")"
    ACTIVE="$(systemextensionsctl list 2>/dev/null | listed_versions activated | head -1 || true)"
    if [ -z "${WANT}" ] || [ "${ACTIVE}" != "${WANT}" ]; then
      echo "the running extension is '${ACTIVE:-none}', but ${APP} carries '${WANT:-none}'." >&2
      echo "Results would describe another engine. Reboot if an older one is waiting to uninstall," >&2
      echo "launch ${APP}, start capture and approve the extension, then run again." >&2
      exit 1
    fi
    echo "running extension ${ACTIVE} is the one in ${APP}"
    ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed -e 's/^# \{0,2\}//' -e '/^set -euo/d'
    exit 2 ;;
esac
