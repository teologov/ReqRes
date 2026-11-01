#!/bin/bash
#
#  core-keys-check.sh — may a build of this shell be released, judged by the
#  license signing keys its embedded core trusts?
#
#  The core verifies every license answer from reqresapp.com with Ed25519
#  public keys compiled into it. A core built with the throwaway DEVELOPMENT
#  keys can never get Pro from the server, which signs with the production
#  keys, so a release built from it would lock out every buyer.
#  Scripts/sync-core.sh records which set it embedded, as "entitlementKeys" in
#  Sources/XReqResCore.provenance.json, once the built binary is shown to
#  carry them; this script judges that record, and then the embedded binary
#  itself, because a hand-copied framework or an edited record never passed
#  through sync-core.sh's check. It searches the binary for the three
#  DEVELOPMENT public keys and the three production ones (a 43-character
#  Swift string literal is stored as bytes, so `grep -aF` finds it).
#
#      Scripts/core-keys-check.sh [--dev-keys] [--legacy-core] [--binary <path>]
#                                 [<provenance.json>]
#          Exit 0 for "production" when the binary carries the three
#          production keys and none of the development keys.
#          Exit 1 for "development" (0 with --dev-keys, for a test install
#          that is never released, but only when the binary carries
#          development k1), for any other value, and for a missing or
#          unreadable file.
#          Exit 1 for "none" or no entitlementKeys at all: a record from an
#          older sync-core.sh, or a core whose EntitlementKeys.swift moved,
#          says nothing about the keys the binary trusts. Only --legacy-core
#          accepts them, for a core from before the keys (every core
#          embedded up to build 55), and only when the binary carries none
#          of the keys, development or production; --dev-keys does not.
#          Exit 1 when the record does not describe the binary: "production"
#          beside a binary that carries any development key or lacks any of
#          the production keys, a keyless record beside a binary that carries
#          any key of either set, or "development" beside one without
#          development k1. Re-run Scripts/sync-core.sh.
#          Exit 1 for a missing or unreadable binary.
#          Exit 2 for a usage error (an unknown option, a second file,
#          --binary without a path).
#          The default file is Sources/XReqResCore.provenance.json, the
#          default binary Sources/XReqResCore.xcframework/macos-arm64_x86_64/
#          XReqResCore.framework/Versions/A/XReqResCore.
#          dev-install.sh runs it before it archives anything.
#
#      Scripts/core-keys-check.sh --selftest
#          Checks every verdict against temporary files: records, and
#          fixture binaries of random bytes with and without the keys of
#          either set.
#
#  Read-only: it reads the provenance file and the binary; --selftest writes
#  only to a temporary folder, which it removes.
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BINARY="${ROOT}/Sources/XReqResCore.xcframework/macos-arm64_x86_64/XReqResCore.framework/Versions/A/XReqResCore"

# The throwaway DEVELOPMENT set's public keys, as in the core's
# XReqResCore/LicenseManager/EntitlementKeys.swift. Public by nature; their
# seeds were never committed. A binary that carries any of them trusts a key
# reqresapp.com never signs with.
DEV_K1="91_vEoebgdvgfRoRB8RPbv-zT3NUgxt6u8zvtGt1-r4"
DEV_K2="G18lb9JbWd2_h3Xot2xAUfv62E6b8tRuH5zPfgZfLsU"
DEV_K3="5ue9WmcswzmDiL35M6JMKe9lDg7Ll41ABgjGem-Fxd0"

# The PRODUCTION set's public keys, drawn on 2026-11-01, as in the core's
# EntitlementKeys.swift since then; their seeds are in neither repository.
# reqresapp.com signs every license answer with one of them (k1 active, k2
# standby, k3 spare), so a "production" record is cleared only beside a
# binary that carries all three. A binary without one of them trusts some
# other key in its place: its record is wrong, or the core's keys were
# replaced and this list was not. Replace a key here in the same change that
# replaces it in the core.
PROD_K1="j11U5Z_FKsLKJviBdLe5-Y3ly9BNZroZ5BS-Hw5NSw4"
PROD_K2="woNv-eyW_nt7kXRaxaphRl7UTCuX4AdK6gibiEaD5rI"
PROD_K3="wcii71tElXX2WCJs6LxLzk_0F6kcRNpW193rwcZAV90"

# Prints the names of the keys of set $1 ("development" or "production") that
# binary $2 carries ("k1 k3"), nothing for none. The same search as
# sync-core.sh: Swift stores a string literal longer than 15 bytes as bytes,
# so a 43-character key is found as is.
# grep's status 1 is "not there", 2 "could not read": an I/O error, or a
# framework sync-core.sh swapped out after the readability check. On 2 it
# says so and returns 2, so a caller never takes an unread binary for one
# without the keys; the absence checks would otherwise fail open, and the
# presence check would report keys as missing that were never looked for.
keys_in() {
  local set="$1" binary="$2" found="" name key status
  for name in k1 k2 k3; do
    case "${set}:${name}" in
      development:k1) key="${DEV_K1}" ;;
      development:k2) key="${DEV_K2}" ;;
      development:k3) key="${DEV_K3}" ;;
      production:k1)  key="${PROD_K1}" ;;
      production:k2)  key="${PROD_K2}" ;;
      production:k3)  key="${PROD_K3}" ;;
      *) echo "core-keys-check: no key set named '${set}'" >&2; return 2 ;;
    esac
    status=0
    LC_ALL=C grep -aqF -- "${key}" "${binary}" || status=$?
    case "${status}" in
      0) found="${found} ${name}" ;;
      1) ;;
      *)
        echo "core-keys-check: cannot read the core binary ${binary} (grep exit ${status}), so the record cannot be checked against it" >&2
        return 2
        ;;
    esac
  done
  echo "${found# }"
}

# The names among k1, k2 and k3 that the list $1 ("k1 k3") lacks ("k2").
missing_from() {
  local missing="" name
  for name in k1 k2 k3; do
    case " $1 " in
      *" ${name} "*) ;;
      *) missing="${missing} ${name}" ;;
    esac
  done
  echo "${missing# }"
}

# A record that does not describe the binary beside it. $1 = what the record
# says, $2 = what the binary carries.
mismatch() {
  echo "core-keys-check: $1, but $2: the record does not describe this binary." >&2
  echo "core-keys-check: re-run Scripts/sync-core.sh, which checks the built binary before it writes the record." >&2
  return 1
}

# Says why, and returns the verdict: 0 = may be released, 1 = may not.
# $1 = 1 when --dev-keys was given, $2 = 1 when --legacy-core was given,
# $3 = the provenance file, $4 = the core binary.
verdict() {
  local dev_keys="$1" legacy_core="$2" file="$3" binary="$4" keys found
  if [ ! -f "${file}" ] || [ ! -r "${file}" ]; then
    echo "core-keys-check: cannot read ${file}" >&2
    return 1
  fi
  # plutil reads JSON. A file that does not parse, or that names no core
  # commit, is not a record sync-core.sh wrote.
  if ! plutil -extract coreCommit raw -expect string -o - "${file}" >/dev/null 2>&1; then
    echo "core-keys-check: ${file} is not a provenance record written by sync-core.sh (no coreCommit)" >&2
    return 1
  fi
  # The record is judged against the binary it claims to describe, so a
  # binary that cannot be read clears nothing.
  if [ ! -f "${binary}" ] || [ ! -r "${binary}" ]; then
    echo "core-keys-check: cannot read the core binary ${binary}, so the record cannot be checked against it" >&2
    return 1
  fi
  if ! plutil -type entitlementKeys "${file}" >/dev/null 2>&1; then
    legacy "no entitlementKeys in ${file}" "${legacy_core}" "${binary}"
    return
  fi
  if ! keys="$(plutil -extract entitlementKeys raw -expect string -o - "${file}" 2>/dev/null)"; then
    echo "core-keys-check: entitlementKeys in ${file} is not a string" >&2
    return 1
  fi
  case "${keys}" in
    production)
      # A binary that could not be read clears nothing (it said why).
      found="$(keys_in development "${binary}")" || return 1
      if [ -n "${found}" ]; then
        mismatch "${file} says production" "${binary} carries the DEVELOPMENT license keys (${found})"
        return
      fi
      found="$(keys_in production "${binary}")" || return 1
      if [ "${found}" != "k1 k2 k3" ]; then
        echo "core-keys-check: ${file} says production, but ${binary} lacks production license keys this script lists (missing: $(missing_from "${found}"))." >&2
        echo "core-keys-check: re-run Scripts/sync-core.sh; if the core's EntitlementKeys.swift holds other production keys now, list them here as PROD_K1 to PROD_K3 in the same change." >&2
        return 1
      fi
      echo "core-keys-check: the embedded core trusts the production license keys"
      ;;
    none)
      legacy "entitlementKeys: none in ${file}" "${legacy_core}" "${binary}"
      return
      ;;
    development)
      if [ "${dev_keys}" != 1 ]; then
        echo "core-keys-check: the embedded core trusts the DEVELOPMENT license keys (entitlementKeys: development):" >&2
        echo "core-keys-check: reqresapp.com can never grant Pro to it, and a release built from it would lock out every buyer." >&2
        return 1
      fi
      # The same search, so a read error is reported as one, not as a
      # binary without k1.
      found="$(keys_in development "${binary}")" || return 1
      case " ${found} " in
        *" k1 "*) ;;
        *)
          mismatch "${file} says development" "${binary} does not carry development k1"
          return
          ;;
      esac
      echo "core-keys-check: WARNING: the embedded core trusts the DEVELOPMENT license keys, accepted by --dev-keys." >&2
      echo "core-keys-check: WARNING: reqresapp.com can never grant Pro to this build, so it must never be released." >&2
      ;;
    *)
      echo "core-keys-check: unknown entitlementKeys '${keys}' in ${file}; expected production, development or none" >&2
      return 1
      ;;
  esac
}

# A record that names no key set. $1 = what it says, $2 = 1 when
# --legacy-core was given, $3 = the core binary.
legacy() {
  local found
  if [ "$2" != 1 ]; then
    echo "core-keys-check: $1: a record from an older sync-core.sh, or a core whose EntitlementKeys.swift moved." >&2
    echo "core-keys-check: it does not say which license keys the binary trusts. Re-run Scripts/sync-core.sh, or pass --legacy-core for a core from before the keys." >&2
    return 1
  fi
  # A core from before the keys carries none of them, of either set; one
  # that could not be read is not shown to (it said why).
  found="$(keys_in development "$3")" || return 1
  if [ -n "${found}" ]; then
    mismatch "$1 (a core from before the keys)" "$3 carries the DEVELOPMENT license keys (${found})"
    return
  fi
  found="$(keys_in production "$3")" || return 1
  if [ -n "${found}" ]; then
    mismatch "$1 (a core from before the keys)" "$3 carries the production license keys (${found})"
    return
  fi
  echo "core-keys-check: $1: accepted by --legacy-core as a core from before the license signing keys"
}

SELFTEST_DIR=""
selftest() {
  local dir failures=0 warning status
  # A global for the EXIT trap: it runs after this function's locals are gone.
  SELFTEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/core-keys-check.XXXXXX")"
  trap 'rm -rf "${SELFTEST_DIR}"' EXIT
  dir="${SELFTEST_DIR}"
  # A record as sync-core.sh writes it. $2 is the entitlementKeys value as
  # JSON, or nothing for a record from before the field.
  record() {
    {
      printf '{\n  "coreCommit": "95062d18f2774aa1c82cd21796939f19511a18e8",\n'
      [ -z "$2" ] || printf '  "entitlementKeys": %s,\n' "$2"
      printf '  "builtWith": "Xcode 27.0"\n}\n'
    } > "${dir}/$1"
  }
  record production.json '"production"'
  record none.json '"none"'
  record before-the-keys.json ''
  record development.json '"development"'
  record unknown.json '"staging"'
  record empty.json '""'
  record null.json 'null'
  record unreadable.json '"production"'
  chmod 000 "${dir}/unreadable.json"
  printf '{\n  "coreCommit": "95062d18f2774aa1c82cd2' > "${dir}/truncated.json"
  printf '{\n  "entitlementKeys": "production"\n}\n' > "${dir}/no-commit.json"

  # The six keys this script knows are 43 base64url characters each and all
  # different: a typo in a production key would refuse every release, one in
  # a development key would let that key through unseen.
  local key all=""
  for key in "${DEV_K1}" "${DEV_K2}" "${DEV_K3}" "${PROD_K1}" "${PROD_K2}" "${PROD_K3}"; do
    if [[ "${key}" =~ ^[A-Za-z0-9_-]{43}$ ]]; then all="${all}${key}"$'\n'; else
      echo "FAIL a key constant is not 43 base64url characters: ${key}"; failures=$((failures + 1)); fi
  done
  if [ "$(printf '%s' "${all}" | LC_ALL=C sort -u | wc -l | tr -d ' ')" = 6 ]; then
    echo "PASS the six key constants are distinct keys of 43 base64url characters"
  else
    echo "FAIL the six key constants are not six distinct keys"; failures=$((failures + 1))
  fi

  # Fixture binaries: random bytes, with the given keys between them, as a
  # Swift string literal longer than 15 bytes is stored.
  binary() {
    local name="$1" key
    shift
    head -c 4096 /dev/urandom > "${dir}/${name}"
    for key in "$@"; do
      printf '%s' "${key}" >> "${dir}/${name}"
      head -c 4096 /dev/urandom >> "${dir}/${name}"
    done
  }
  binary plain.bin
  binary development.bin "${DEV_K1}" "${DEV_K2}" "${DEV_K3}"
  binary only-k2.bin "${DEV_K2}"
  binary only-k3.bin "${DEV_K3}"
  binary only-k1.bin "${DEV_K1}"
  binary production.bin "${PROD_K1}" "${PROD_K2}" "${PROD_K3}"
  binary only-prod-k1.bin "${PROD_K1}"
  binary prod-without-k3.bin "${PROD_K1}" "${PROD_K2}"
  binary prod-with-dev-k2.bin "${PROD_K1}" "${PROD_K2}" "${PROD_K3}" "${DEV_K2}"
  binary unreadable.bin
  chmod 000 "${dir}/unreadable.bin"
  local plain="${dir}/plain.bin" devbin="${dir}/development.bin" prodbin="${dir}/production.bin"

  # $1 = the case, $2 = the exit status it must give, then verdict's arguments.
  expect() {
    local what="$1" want="$2" got=0
    shift 2
    verdict "$@" >/dev/null 2>&1 || got=$?
    if [ "${got}" = "${want}" ]; then echo "PASS ${what}"; else echo "FAIL ${what}: exit ${got}, want ${want}"; failures=$((failures + 1)); fi
  }
  # verdict's arguments: --dev-keys (0/1), --legacy-core (0/1), the file, the
  # binary. The record cases use the binary that matches the record, so only
  # the record decides them.
  expect "production may be released"                     0 0 0 "${dir}/production.json" "${prodbin}"
  expect "none is refused"                                1 0 0 "${dir}/none.json" "${plain}"
  expect "a record without the field is refused"          1 0 0 "${dir}/before-the-keys.json" "${plain}"
  expect "none is accepted with --legacy-core"            0 0 1 "${dir}/none.json" "${plain}"
  expect "a record without the field is accepted with --legacy-core" 0 0 1 "${dir}/before-the-keys.json" "${plain}"
  expect "--dev-keys does not accept none"                1 1 0 "${dir}/none.json" "${plain}"
  expect "--dev-keys does not accept a record without the field" 1 1 0 "${dir}/before-the-keys.json" "${plain}"
  expect "development is refused"                         1 0 0 "${dir}/development.json" "${devbin}"
  expect "development is refused with --legacy-core"      1 0 1 "${dir}/development.json" "${devbin}"
  expect "development is accepted with --dev-keys"        0 1 0 "${dir}/development.json" "${devbin}"
  expect "a missing file is refused"                      1 0 0 "${dir}/missing.json" "${plain}"
  if [ "$(id -u)" -ne 0 ]; then
    expect "an unreadable file is refused"                1 0 0 "${dir}/unreadable.json" "${plain}"
  fi
  expect "a file that does not parse is refused"          1 0 0 "${dir}/truncated.json" "${plain}"
  expect "a record that names no core commit is refused"  1 0 0 "${dir}/no-commit.json" "${plain}"
  expect "an unknown key set is refused"                  1 0 0 "${dir}/unknown.json" "${plain}"
  expect "an empty key set is refused"                    1 0 0 "${dir}/empty.json" "${plain}"
  expect "a key set that is not a string is refused"      1 0 0 "${dir}/null.json" "${plain}"
  expect "--dev-keys accepts no unknown key set"          1 1 0 "${dir}/unknown.json" "${devbin}"
  expect "--legacy-core accepts no unknown key set"       1 0 1 "${dir}/unknown.json" "${plain}"
  expect "--dev-keys accepts no missing file"             1 1 0 "${dir}/missing.json" "${devbin}"
  expect "--legacy-core accepts no missing file"          1 0 1 "${dir}/missing.json" "${plain}"
  # The binary beside the record. A production record is refused when the
  # binary carries ANY development key or lacks ANY production key; a
  # keyless one under --legacy-core when it carries any key of either set; a
  # development record under --dev-keys when it lacks development k1.
  expect "production is refused beside the development keys"        1 0 0 "${dir}/production.json" "${devbin}"
  expect "production is refused beside development k1 alone"        1 0 0 "${dir}/production.json" "${dir}/only-k1.bin"
  expect "production is refused beside development k2 alone"        1 0 0 "${dir}/production.json" "${dir}/only-k2.bin"
  expect "production is refused beside development k3 alone"        1 0 0 "${dir}/production.json" "${dir}/only-k3.bin"
  expect "--dev-keys does not excuse production beside the development keys" 1 1 0 "${dir}/production.json" "${devbin}"
  expect "--legacy-core does not excuse production beside the development keys" 1 0 1 "${dir}/production.json" "${devbin}"
  expect "production is refused beside no keys at all"              1 0 0 "${dir}/production.json" "${plain}"
  expect "production is refused beside production k1 alone"         1 0 0 "${dir}/production.json" "${dir}/only-prod-k1.bin"
  expect "production is refused without production k3"             1 0 0 "${dir}/production.json" "${dir}/prod-without-k3.bin"
  expect "production is refused beside the production keys and development k2" 1 0 0 "${dir}/production.json" "${dir}/prod-with-dev-k2.bin"
  expect "--dev-keys does not excuse production without the production keys" 1 1 0 "${dir}/production.json" "${plain}"
  expect "--legacy-core does not excuse production without the production keys" 1 0 1 "${dir}/production.json" "${dir}/only-prod-k1.bin"
  expect "development with --dev-keys is refused beside no keys"    1 1 0 "${dir}/development.json" "${plain}"
  expect "development with --dev-keys is refused without k1 (k2)"   1 1 0 "${dir}/development.json" "${dir}/only-k2.bin"
  expect "development with --dev-keys is refused without k1 (k3)"   1 1 0 "${dir}/development.json" "${dir}/only-k3.bin"
  expect "development with --dev-keys needs only k1"                0 1 0 "${dir}/development.json" "${dir}/only-k1.bin"
  expect "development with --dev-keys is refused beside the production keys" 1 1 0 "${dir}/development.json" "${prodbin}"
  expect "none with --legacy-core is refused beside the development keys" 1 0 1 "${dir}/none.json" "${devbin}"
  expect "none with --legacy-core is refused beside development k2 alone" 1 0 1 "${dir}/none.json" "${dir}/only-k2.bin"
  expect "none with --legacy-core is refused beside development k3 alone" 1 0 1 "${dir}/none.json" "${dir}/only-k3.bin"
  expect "a record without the field, with --legacy-core, is refused beside the development keys" 1 0 1 "${dir}/before-the-keys.json" "${devbin}"
  expect "a record without the field, with --legacy-core, is refused beside development k1 alone" 1 0 1 "${dir}/before-the-keys.json" "${dir}/only-k1.bin"
  expect "none with --legacy-core is refused beside the production keys" 1 0 1 "${dir}/none.json" "${prodbin}"
  expect "none with --legacy-core is refused beside production k1 alone" 1 0 1 "${dir}/none.json" "${dir}/only-prod-k1.bin"
  expect "a record without the field, with --legacy-core, is refused beside the production keys" 1 0 1 "${dir}/before-the-keys.json" "${prodbin}"
  expect "a missing binary is refused for production"               1 0 0 "${dir}/production.json" "${dir}/missing.bin"
  expect "a missing binary is refused for development with --dev-keys" 1 1 0 "${dir}/development.json" "${dir}/missing.bin"
  expect "a missing binary is refused for none with --legacy-core"  1 0 1 "${dir}/none.json" "${dir}/missing.bin"
  expect "a folder is refused as the binary"                        1 0 0 "${dir}/production.json" "${dir}"
  if [ "$(id -u)" -ne 0 ]; then
    expect "an unreadable binary is refused"                        1 0 0 "${dir}/production.json" "${dir}/unreadable.bin"
  fi
  # A read that fails after the readability check (EIO, or sync-core.sh
  # swapping the framework in between): grep exits 2, and an unread binary
  # must clear nothing. A function named grep stands in for the failing read;
  # `LC_ALL=C grep` finds a function before the command.
  grep() { echo "grep: Input/output error" >&2; return 2; }
  expect "a grep read error is refused for production"              1 0 0 "${dir}/production.json" "${prodbin}"
  expect "a grep read error is refused for none with --legacy-core" 1 0 1 "${dir}/none.json" "${plain}"
  expect "a grep read error is refused for a record without the field, with --legacy-core" 1 0 1 "${dir}/before-the-keys.json" "${plain}"
  expect "a grep read error is refused for development with --dev-keys" 1 1 0 "${dir}/development.json" "${devbin}"
  warning="$(verdict 0 0 "${dir}/production.json" "${prodbin}" 2>&1 || true)"
  case "${warning}" in
    *"cannot read the core binary"*"grep exit 2"*) echo "PASS a grep read error says the binary could not be read" ;;
    *) echo "FAIL a grep read error said: ${warning}"; failures=$((failures + 1)) ;;
  esac
  warning="$(verdict 1 0 "${dir}/development.json" "${devbin}" 2>&1 || true)"
  unset -f grep
  case "${warning}" in
    *"does not carry development k1"*) echo "FAIL a grep read error under --dev-keys was reported as a binary without k1"; failures=$((failures + 1)) ;;
    *"cannot read the core binary"*) echo "PASS a grep read error under --dev-keys says the binary could not be read" ;;
    *) echo "FAIL a grep read error under --dev-keys said: ${warning}"; failures=$((failures + 1)) ;;
  esac
  # A read that fails only while the production keys are looked for: the
  # record is refused as unread, never as a binary that lacks those keys.
  grep() {
    case "$*" in *"${PROD_K2}"*) echo "grep: Input/output error" >&2; return 2 ;; esac
    command grep "$@"
  }
  warning="$(verdict 0 0 "${dir}/production.json" "${prodbin}" 2>&1)" && status=0 || status=$?
  unset -f grep
  case "${status}:${warning}" in
    *"lacks production license keys"*) echo "FAIL a read error on a production key was reported as a missing key"; failures=$((failures + 1)) ;;
    1:*"cannot read the core binary"*"grep exit 2"*) echo "PASS a read error on a production key is refused and says the binary could not be read" ;;
    *) echo "FAIL a read error on a production key said (exit ${status}): ${warning}"; failures=$((failures + 1)) ;;
  esac
  # And the real grep is back: the same record and binary pass again.
  expect "production may be released once grep reads again"        0 0 0 "${dir}/production.json" "${prodbin}"
  # The same through the command line, so the options reach verdict as
  # given: --dev-keys must not turn on --legacy-core, and --binary names the
  # binary wherever it stands.
  expect_cli() {
    local what="$1" want="$2" got=0
    shift 2
    "${BASH_SOURCE[0]}" "$@" >/dev/null 2>&1 || got=$?
    if [ "${got}" = "${want}" ]; then echo "PASS ${what}"; else echo "FAIL ${what}: exit ${got}, want ${want}"; failures=$((failures + 1)); fi
  }
  expect_cli "command line: none is refused"                       1 --binary "${plain}" "${dir}/none.json"
  expect_cli "command line: --dev-keys does not accept none"       1 --dev-keys --binary "${plain}" "${dir}/none.json"
  expect_cli "command line: --legacy-core accepts none"            0 --legacy-core --binary "${plain}" "${dir}/none.json"
  expect_cli "command line: --dev-keys accepts development"        0 --dev-keys --binary "${devbin}" "${dir}/development.json"
  expect_cli "command line: --legacy-core does not accept development" 1 --legacy-core --binary "${devbin}" "${dir}/development.json"
  expect_cli "command line: production may be released"           0 --binary "${prodbin}" "${dir}/production.json"
  expect_cli "command line: --binary after the file"              0 "${dir}/production.json" --binary "${prodbin}"
  expect_cli "command line: production is refused beside no keys" 1 --binary "${plain}" "${dir}/production.json"
  expect_cli "command line: --dev-keys does not excuse production without the production keys" 1 --dev-keys --binary "${plain}" "${dir}/production.json"
  expect_cli "command line: production is refused beside the development keys" 1 --binary "${devbin}" "${dir}/production.json"
  expect_cli "command line: production is refused beside development k2 alone" 1 --binary "${dir}/only-k2.bin" "${dir}/production.json"
  expect_cli "command line: --dev-keys refuses development beside no keys" 1 --dev-keys --binary "${plain}" "${dir}/development.json"
  expect_cli "command line: --legacy-core refuses none beside the development keys" 1 --legacy-core --binary "${devbin}" "${dir}/none.json"
  expect_cli "command line: a missing binary is refused"           1 --binary "${dir}/missing.bin" "${dir}/production.json"
  expect_cli "command line: --legacy-core refuses a record without the field beside development k1" 1 --legacy-core --binary "${dir}/only-k1.bin" "${dir}/before-the-keys.json"
  if [ "$(id -u)" -ne 0 ]; then
    expect_cli "command line: an unreadable binary is refused"     1 --binary "${dir}/unreadable.bin" "${dir}/production.json"
  fi
  expect_cli "command line: --binary without a path is a usage error" 2 "${dir}/production.json" --binary
  expect_cli "command line: --binary does not take an option as its path" 2 --binary --dev-keys "${dir}/development.json"
  expect_cli "command line: two binaries are a usage error"       2 --binary "${plain}" --binary "${plain}" "${dir}/production.json"
  warning="$(verdict 1 0 "${dir}/development.json" "${devbin}" 2>&1 || true)"
  case "${warning}" in
    *"must never be released"*) echo "PASS --dev-keys warns that the build must never be released" ;;
    *) echo "FAIL --dev-keys gave no warning that the build must never be released"; failures=$((failures + 1)) ;;
  esac
  warning="$(verdict 0 0 "${dir}/none.json" "${plain}" 2>&1 || true)"
  case "${warning}" in
    *"a record from an older sync-core.sh, or a core whose EntitlementKeys.swift moved"*) echo "PASS none says why it is refused" ;;
    *) echo "FAIL none gave no reason for the refusal"; failures=$((failures + 1)) ;;
  esac
  # $1 = the case, $2 = a pattern the refusal must match, then verdict's arguments.
  says() {
    local what="$1" want="$2"
    shift 2
    warning="$(verdict "$@" 2>&1 || true)"
    case "${warning}" in
      ${want}) echo "PASS ${what}" ;;
      *) echo "FAIL ${what}: said: ${warning}"; failures=$((failures + 1)) ;;
    esac
  }
  says "production beside a development key names the key and the cure" \
    "*production.json says production, but *only-k2.bin carries the DEVELOPMENT license keys (k2): the record does not describe this binary.*Scripts/sync-core.sh*" \
    0 0 "${dir}/production.json" "${dir}/only-k2.bin"
  says "development without k1 says the record does not describe the binary" \
    "*does not carry development k1: the record does not describe this binary.*Scripts/sync-core.sh*" \
    1 0 "${dir}/development.json" "${plain}"
  says "a legacy record beside the development keys names all three" \
    "*carries the DEVELOPMENT license keys (k1 k2 k3): the record does not describe this binary.*" \
    0 1 "${dir}/none.json" "${devbin}"
  says "production without production keys names the missing ones and the cure" \
    "*production.json says production, but *only-prod-k1.bin lacks production license keys this script lists (missing: k2 k3).*Scripts/sync-core.sh*PROD_K1 to PROD_K3*" \
    0 0 "${dir}/production.json" "${dir}/only-prod-k1.bin"
  says "a legacy record beside the production keys names them" \
    "*carries the production license keys (k1 k2 k3): the record does not describe this binary.*" \
    0 1 "${dir}/none.json" "${prodbin}"
  says "production beside the production keys is cleared" \
    "core-keys-check: the embedded core trusts the production license keys" \
    0 0 "${dir}/production.json" "${prodbin}"
  says "a missing binary says it cannot be read" \
    "*cannot read the core binary *missing.bin*" \
    0 0 "${dir}/production.json" "${dir}/missing.bin"
  [ "${failures}" -eq 0 ] || { echo "${failures} failed"; exit 1; }
  echo "all passed"
}

DEV_KEYS=0
LEGACY_CORE=0
FILE=""
BINARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) selftest; exit 0 ;;
    --dev-keys) DEV_KEYS=1 ;;
    --legacy-core) LEGACY_CORE=1 ;;
    --binary)
      # A path, never the next option: `--binary --dev-keys` must not read
      # a file named --dev-keys and drop the option.
      case "${2:-}" in ""|-*) echo "--binary needs a path" >&2; exit 2 ;; esac
      [ -z "${BINARY}" ] || { echo "one binary at most" >&2; exit 2; }
      BINARY="$2"
      shift ;;
    -h|--help)  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,2\}//' -e '/^set -euo/d'; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; exit 2 ;;
    *)          [ -z "${FILE}" ] || { echo "one provenance file at most" >&2; exit 2; }; FILE="$1" ;;
  esac
  shift
done

verdict "${DEV_KEYS}" "${LEGACY_CORE}" "${FILE:-${ROOT}/Sources/XReqResCore.provenance.json}" "${BINARY:-${DEFAULT_BINARY}}"
