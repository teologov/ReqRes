#!/bin/bash
#
#  bundle-libraries-check.sh — can every binary in a ReqRes build load the
#  libraries it needs, on every macOS the build supports?
#
#  macOS does not run the system extension from inside the app. It copies the
#  extension's bundle to /Library/SystemExtensions/<UUID>/ and starts it from
#  there, so the extension can load only what its own bundle carries and what
#  the OS provides. ReqRes 1.1.0 (build 62) shipped an extension whose core
#  loads @rpath/libswiftCompatibilitySpan.dylib, a Swift library that Xcode
#  copies into an app's bundle but not into a system extension's. macOS 26 and
#  later provide it in /usr/lib/swift; macOS 14 and 15 do not, so there the
#  extension died at launch (dyld: "Library not loaded") and capture never
#  started. The Mac that builds a release runs a newer macOS than the oldest
#  one the release supports, so what its own /usr/lib/swift holds proves
#  nothing. This check therefore accepts a library loaded through @rpath,
#  @executable_path or @loader_path only when it is found INSIDE the bundle
#  that loads it.
#
#  Usage:
#      Scripts/bundle-libraries-check.sh <ReqRes.app>
#      Scripts/bundle-libraries-check.sh --selftest
#
#  The app and each system extension inside it are checked as separate
#  bundles. For every Mach-O file in a bundle and each of its architectures,
#  every load command macOS must satisfy (LC_LOAD_DYLIB, LC_REEXPORT_DYLIB,
#  LC_LOAD_UPWARD_DYLIB) is resolved through that file's run paths and, for a
#  library, the run paths of the bundle's main executable too (dyld searches
#  the run paths of every image above it in the load chain), with
#  @loader_path as the file's folder and @executable_path as the bundle's
#  Contents/MacOS (an executable's own folder, for an executable). A weak load
#  command (LC_LOAD_WEAK_DYLIB) may stay unresolved, and a library named by an
#  absolute path (/usr/lib, /System) is the OS's and is not checked.
#  Exit 0 when every library is found inside its bundle, 1 otherwise; each
#  miss is printed with the run paths searched. Read-only.
#
#  --selftest builds small binaries with clang in a temporary folder, runs the
#  check on bundles made from them (among them 1.1.0's case: an extension
#  that finds the library only in the app), and removes the folder.
#
#  Copyright © 2026 Andrey Teologov. All rights reserved.
#  Licensed under the Functional Source License, Version 1.1 — see LICENSE.md.
#
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

say()  { printf '\033[0;34m[bundle-libraries]\033[0m %s\n' "$1"; }
ok()   { printf '\033[0;32m[bundle-libraries]\033[0m %s\n' "$1"; }
bad()  { printf '\033[0;31m[bundle-libraries]\033[0m %s\n' "$1" >&2; }

# The file a path names, with every symlink followed; fails when there is none.
physical() { [ -f "$1" ] && /bin/realpath "$1" 2>/dev/null; }

# The Mach-O file type of one architecture of a file: EXECUTE, DYLIB, BUNDLE…
filetype() { otool -arch "$2" -hv "$1" 2>/dev/null | awk '$1 ~ /^MH_(MAGIC|CIGAM)/ { print $5; exit }'; }

# The run paths and the required libraries of one architecture of a file, as
# lines "RPATH<tab>path" and "NEED<tab>name". Weak libraries are left out.
load_commands() {
  otool -arch "$2" -l "$1" | awk '
    $1 == "cmd" { cmd = $2; next }
    $1 == "path" && cmd == "LC_RPATH" {
      line = $0; sub(/^[ \t]*path /, "", line); sub(/ \(offset [0-9]+\)$/, "", line)
      print "RPATH\t" line; next }
    $1 == "name" && (cmd == "LC_LOAD_DYLIB" || cmd == "LC_REEXPORT_DYLIB" || cmd == "LC_LOAD_UPWARD_DYLIB") {
      line = $0; sub(/^[ \t]*name /, "", line); sub(/ \(offset [0-9]+\)$/, "", line)
      print "NEED\t" line; next }'
}

CHECKED=0
MISSES=0

# Prints the physical path of a candidate when it exists inside the bundle.
inside() {
  local p
  p="$(physical "$2")" || return 1
  case "${p}" in "$1"/*) printf '%s\n' "${p}" ;; *) return 1 ;; esac
}

# check_bundle <bundle> <label> [<folder left out: the app's system extensions>]
check_bundle() {
  local root="$1" label="$2" prune="${3:-}" macos main f a kind exe_dir loader_dir key value
  local need rest r searched found
  macos="${root}/Contents/MacOS"
  main="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${root}/Contents/Info.plist" 2>/dev/null || true)"
  [ -z "${main}" ] || main="${macos}/${main}"
  while IFS= read -r f; do
    case "$(file -b "${f}" 2>/dev/null)" in *Mach-O*) ;; *) continue ;; esac
    CHECKED=$((CHECKED + 1))
    loader_dir="$(dirname "${f}")"
    for a in $(lipo -archs "${f}" 2>/dev/null); do
      kind="$(filetype "${f}" "${a}")"
      if [ "${kind}" = "EXECUTE" ]; then exe_dir="${loader_dir}"; else exe_dir="${macos}"; fi
      local rpaths=() needs=()
      while IFS=$'\t' read -r key value; do
        case "${key}" in
          RPATH) rpaths+=("${value}") ;;
          NEED)  needs+=("${value}") ;;
        esac
      done < <(load_commands "${f}" "${a}")
      # A library is loaded by the bundle's main executable (or by a library
      # it loads), so dyld also searches the main executable's run paths.
      if [ "${kind}" != "EXECUTE" ] && [ -n "${main}" ] && [ -f "${main}" ]; then
        while IFS=$'\t' read -r key value; do
          [ "${key}" = "RPATH" ] || continue
          value="${value/#@executable_path/${macos}}"
          rpaths+=("${value/#@loader_path/${macos}}")
        done < <(load_commands "${main}" "${a}" 2>/dev/null)
      fi
      for need in ${needs[@]+"${needs[@]}"}; do
        found=""; searched=""
        case "${need}" in
          @rpath/*)
            rest="${need#@rpath/}"
            for r in ${rpaths[@]+"${rpaths[@]}"}; do
              r="${r/#@executable_path/${exe_dir}}"
              r="${r/#@loader_path/${loader_dir}}"
              searched="${searched}${searched:+, }${r}"
              if found="$(inside "${root}" "${r}/${rest}")"; then break; fi
              found=""
            done ;;
          @executable_path/*)
            searched="${exe_dir}"
            found="$(inside "${root}" "${exe_dir}/${need#@executable_path/}")" || found="" ;;
          @loader_path/*)
            searched="${loader_dir}"
            found="$(inside "${root}" "${loader_dir}/${need#@loader_path/}")" || found="" ;;
          *) continue ;;
        esac
        if [ -z "${found}" ]; then
          bad "${label}: ${f#"${root}"/} (${a}) needs ${need}, which is not inside ${label} (searched: ${searched:-no run paths})"
          MISSES=$((MISSES + 1))
        fi
      done
    done
  done < <(
    if [ -n "${prune}" ]; then
      find "${root}" -path "${prune}" -prune -o -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print
    else
      find "${root}" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print
    fi)
}

selftest() {
  command -v clang >/dev/null 2>&1 || { bad "--selftest needs clang (Xcode or its Command Line Tools)"; exit 1; }
  local T passed=0 failed=0
  T="$(mktemp -d "${TMPDIR:-/tmp}/bundle-libraries-selftest.XXXXXX")"
  trap 'rm -rf "${T:?}"' EXIT
  printf 'int f(void) { return 1; }\n' > "${T}/f.c"
  printf 'int f(void);\nint g(void) { return f(); }\n' > "${T}/g.c"
  printf 'int f(void);\nint main(void) { return f(); }\n' > "${T}/main-f.c"
  printf 'int g(void);\nint main(void) { return g(); }\n' > "${T}/main-g.c"
  clang -dynamiclib -install_name @rpath/libf.dylib -o "${T}/libf.dylib" "${T}/f.c"
  clang -dynamiclib -install_name @rpath/libg.dylib -o "${T}/libg.dylib" "${T}/g.c" -L"${T}" -lf -Wl,-rpath,@loader_path
  clang -dynamiclib -install_name @rpath/libh.dylib -o "${T}/libh.dylib" "${T}/g.c" -L"${T}" -lf
  # program <path> <main source> <clang arguments…>
  program() { local out="$1" src="$2"; shift 2; mkdir -p "$(dirname "${out}")"; clang -o "${out}" "${T}/${src}" -L"${T}" "$@"; }
  # expect <0 or 1> <description> <bundle>
  expect() {
    local got=0
    /bin/bash "${SELF}" "$3" >"${T}/out.txt" 2>&1 || got=1
    if [ "${got}" = "$1" ]; then
      passed=$((passed + 1)); printf '  ok    %s\n' "$2"
    else
      failed=$((failed + 1)); printf '  FAIL  %s (exit %s, wanted %s)\n' "$2" "${got}" "$1"; sed 's/^/        /' "${T}/out.txt"
    fi
  }
  local A X
  A="${T}/found.app"
  program "${A}/Contents/MacOS/found" main-f.c -lf -Wl,-rpath,@executable_path/../Frameworks
  mkdir -p "${A}/Contents/Frameworks"; cp "${T}/libf.dylib" "${A}/Contents/Frameworks/"
  expect 0 "a library in the bundle's Contents/Frameworks is found" "${A}"

  A="${T}/missing.app"
  program "${A}/Contents/MacOS/missing" main-f.c -lf -Wl,-rpath,@executable_path/../Frameworks
  expect 1 "a library the bundle does not carry is refused" "${A}"

  mkdir -p "${T}/outside"; cp "${T}/libf.dylib" "${T}/outside/"
  A="${T}/outside.app"
  program "${A}/Contents/MacOS/outside" main-f.c -lf -Wl,-rpath,"${T}/outside"
  expect 1 "a library found only outside the bundle (as in this Mac's /usr/lib/swift) is refused" "${A}"

  A="${T}/tunnel.app"
  program "${A}/Contents/MacOS/tunnel" main-f.c -lf -Wl,-rpath,@executable_path/../Frameworks
  mkdir -p "${A}/Contents/Frameworks"; cp "${T}/libf.dylib" "${A}/Contents/Frameworks/"
  X="${A}/Contents/Library/SystemExtensions/tunnel.systemextension"
  program "${X}/Contents/MacOS/tunnel" main-f.c -lf -Wl,-rpath,@executable_path/../Frameworks \
    -Wl,-rpath,@executable_path/../../../../../Frameworks
  expect 1 "a system extension cannot borrow the app's copy (1.1.0's extension on macOS 14 and 15)" "${A}"
  mkdir -p "${X}/Contents/Frameworks"; cp "${T}/libf.dylib" "${X}/Contents/Frameworks/"
  expect 0 "the same system extension with its own copy is found" "${A}"

  A="${T}/weak.app"
  program "${A}/Contents/MacOS/weak" main-f.c -Wl,-weak-lf -Wl,-rpath,@executable_path/../Frameworks
  expect 0 "a weak library may be absent" "${A}"

  A="${T}/loader.app"
  program "${A}/Contents/MacOS/loader" main-g.c -lg -Wl,-rpath,@executable_path/../Frameworks
  mkdir -p "${A}/Contents/Frameworks"; cp "${T}/libg.dylib" "${T}/libf.dylib" "${A}/Contents/Frameworks/"
  expect 0 "a library's own @loader_path run path is followed" "${A}"
  rm "${A}/Contents/Frameworks/libf.dylib"
  expect 1 "a library that a library needs is checked too" "${A}"

  A="${T}/chain.app"
  program "${A}/Contents/MacOS/chain" main-g.c -lh -Wl,-rpath,@executable_path/../Frameworks
  mkdir -p "${A}/Contents/Frameworks"; cp "${T}/libh.dylib" "${T}/libf.dylib" "${A}/Contents/Frameworks/"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string chain' "${A}/Contents/Info.plist" >/dev/null
  expect 0 "a library with no run paths of its own is found through the main executable's" "${A}"
  rm "${A}/Contents/Frameworks/libf.dylib"
  expect 1 "…and what it needs must still be inside the bundle" "${A}"

  printf '%s passed, %s failed\n' "${passed}" "${failed}"
  [ "${failed}" -eq 0 ]
  exit $?
}

[ "$#" -eq 1 ] || { echo "usage: $(basename "$0") <ReqRes.app> | --selftest" >&2; exit 2; }
[ "$1" = "--selftest" ] && selftest
[ -d "$1/Contents" ] || { bad "no app bundle at $1"; exit 1; }

APP="$(cd "$1" && pwd -P)"
EXTENSIONS="${APP}/Contents/Library/SystemExtensions"
BUNDLES=1
check_bundle "${APP}" "${APP##*/}" "${EXTENSIONS}"
for ext in "${EXTENSIONS}"/*.systemextension; do
  [ -d "${ext}" ] || continue
  check_bundle "${ext}" "${ext##*/}"
  BUNDLES=$((BUNDLES + 1))
done

if [ "${MISSES}" -gt 0 ]; then
  bad "${MISSES} required librar$([ "${MISSES}" -eq 1 ] && echo y || echo ies) not inside the bundle that loads them: on a Mac whose macOS does not provide them, that bundle dies at launch."
  bad "A Swift back-deployment library (libswiftCompatibility*.dylib) is copied into a bundle's Contents/Frameworks only when its target builds with ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES; Xcode does it for an app on its own, not for a system extension."
  exit 1
fi
ok "${CHECKED} Mach-O files in ${BUNDLES} bundles: every library loaded through @rpath, @executable_path or @loader_path is inside the bundle that loads it"
