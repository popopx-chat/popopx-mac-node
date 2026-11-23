#!/usr/bin/env bash
#
# build-release.sh - Developer ID signing + Apple notarization pipeline
#                    for POPOPX Mac Node.
#
# Produces distributable .zip and .dmg artifacts that pass Gatekeeper without a
# manual right-click override, in six stages:
#
#   1  preflight      tools, repo shape, signing identity, entitlements
#   2  assemble       bundle via Scripts/build_dmg.sh --emit-app (unsigned)
#   3  deep sign      Mach-O inside-out, hardened runtime + secure timestamp
#   4  notarize       notarytool submit + wait, then staple what can be stapled
#   5  package        signed DMG and ZIP, DMG notarized and stapled
#   6  checksums      dist/SHA256SUMS.txt plus the acceptance report
#
# Bundle assembly, Info.plist generation, universal lipo, debug-symbol stripping
# and the developer-path privacy audit all stay in Scripts/build_dmg.sh and are
# reused through its --emit-app seam. This script deliberately does not write an
# Info.plist of its own: a second generator is how a release ends up reporting a
# version that differs from the one the packer stamped.
#
# Requirements: a macOS host with Xcode, a "Developer ID Application" identity in
# the keychain, and a notarytool credential profile (see --help).
#
# Copyright (C) 2026 POPOPX Chat
# SPDX-License-Identifier: AGPL-3.0-only
#
set -euo pipefail
IFS=$'\n\t'

as_bool() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|y|Y) printf 'true\n'  ;;
        *)                       printf 'false\n' ;;
    esac
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_NAME=$(basename -- "$0")
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PACKAGE_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)

PACKAGER="${SCRIPT_DIR}/build_dmg.sh"
ENTITLEMENTS_DEFAULT="${SCRIPT_DIR}/entitlements.plist"

# Bundle layout facts, mirrored from Scripts/build_dmg.sh. Used only to locate
# and seal what the packer emits; the version values themselves are read back
# from the produced Info.plist and asserted in stage 2.
APP_BUNDLE_NAME="POPOPX Mac Node.app"
EXEC_NAME="PopopxMacNodeApp"
BUNDLE_ID="chat.popopx.node"
VOL_NAME="POPOPX Mac Node"
PRODUCT_STEM="POPOPX-Mac-Node"

# ---------------------------------------------------------------------------
# Overridable parameters (environment first, flags win)
# ---------------------------------------------------------------------------
# `${VAR-default}`, not `${VAR:-default}`: an explicitly empty TEAM_ID is the
# documented "match by certificate name only" mode and must survive here.
TEAM_ID="${TEAM_ID-PDBA6XRBQT}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-popopx-notary}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-1800s}"
ENTITLEMENTS="${ENTITLEMENTS:-${ENTITLEMENTS_DEFAULT}}"
ARCH="${ARCH:-}"                                     # empty = universal
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD:-}"
SKIP_NOTARY="$(as_bool "${NOTARY_SKIP:-${SKIP_NOTARY:-0}}")"
SKIP_BUILD="$(as_bool "${SKIP_BUILD:-0}")"
OUTPUT_DIR="${OUTPUT_DIR:-}"

# ---------------------------------------------------------------------------
# Derived state
# ---------------------------------------------------------------------------
RESOLVED_IDENTITY=""
ARTIFACT_BASENAME=""
STAGE_DIR=""
APP_PATH=""
DMG_PATH=""
DIST_ZIP=""
MOUNT_POINT=""
SIGNING_ENTITLEMENTS=""
NOTARIZED=false
STAPLED_TARGET=""
WORK=""

TOTAL_STEPS=6

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RESET=$(tput sgr0); C_BOLD=$(tput bold); C_DIM=$(tput dim)
    C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3); C_BLUE=$(tput setaf 4)
fi

step() { printf '%s[%s%d/%d%s]%s %s%s%s\n' "$C_BOLD" "$C_GREEN" "$1" "$TOTAL_STEPS" "$C_RESET" "$C_BOLD" "$C_BLUE" "$2" "$C_RESET"; }
info() { printf '       %s\n' "$1"; }
dim()  { printf '       %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
die()  { printf '%sFATAL:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

# codesign reports the hardened runtime inside CodeDirectory flags=0x...(...)
# and the string is space-free, so take exactly the run after flags=.
signing_flags() {
    codesign -dvv "$1" 2>&1 | sed -n 's/.*flags=\([^ ]*\).*/\1/p' | head -n 1 || true
}

usage() {
    cat <<USAGE
${SCRIPT_NAME} - Developer ID signing and Apple notarization pipeline

Usage:
    bash Scripts/build-release.sh [options]

Options:
    --team-id <id>              Apple Developer Team ID, matched against the
                                parenthesised suffix of the certificate name and
                                then asserted against the sealed TeamIdentifier.
                                "any" selects by certificate name only and skips
                                that assertion (default: ${TEAM_ID})
    --sign-identity <name>      Identity kind to search the keychain for
                                (default: ${SIGN_IDENTITY})
    --notary-profile <name>     Stored notarytool credential profile
                                (default: ${NOTARY_PROFILE})
    --entitlements <file>       plist to seal into the bundle
                                (default: Scripts/entitlements.plist)
    --output <dir>              Artifact directory (default: <repo>/dist)
    --version <x.y.z>           Version forwarded to the packer, then asserted
                                against the emitted Info.plist
    --build <n>                 Build number forwarded to the packer
    --single-arch <arch>        arm64 or x86_64 only (default: universal, and the
                                artifact name follows the arches actually built)
    --skip-notary               Sign only: no submission, no ticket. For local
                                checks only, the result must not be distributed.
    --skip-build                Reuse the existing .build/release output
    -h, --help                  This help

Environment overrides:
    TEAM_ID, SIGN_IDENTITY, NOTARY_PROFILE, NOTARY_TIMEOUT, ENTITLEMENTS,
    ARCH, VERSION, BUILD, OUTPUT_DIR, SKIP_NOTARY, SKIP_BUILD

Examples:
    bash Scripts/build-release.sh
    bash Scripts/build-release.sh --version 1.1.0 --build 4
    bash Scripts/build-release.sh --single-arch arm64
    bash Scripts/build-release.sh --skip-notary

Outputs, named after the architectures actually built:
    dist/POPOPX-Mac-Node-Universal.dmg     universal arm64 + x86_64
    dist/POPOPX-Mac-Node-macOS-arm64.*     single-arch builds
    dist/SHA256SUMS.txt                    '<64hex>  <relative name>' per artifact

Implementation notes:
    * Notarization requires three things at once: a Developer ID signature, the
      hardened runtime (--options runtime) and a secure timestamp (--timestamp).
      Missing any one of them costs a submission cycle to discover, so stage 3
      asserts all three before anything is submitted.
    * The hardened runtime is applied here, at signing time. SwiftPM has no
      ENABLE_HARDENED_RUNTIME build setting; that knob belongs to xcodebuild, and
      this repository has no Xcode project.
    * A notarization ticket lives in a resource fork, which a .app directory does
      not have on APFS. Stage 4 tries the bundle, reports what happened, and
      stage 5 staples the DMG - the artifact users actually download.
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
need_value() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        die "option --${1} requires a value"
    fi
    return 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)         usage; exit 0 ;;
            --team-id)         need_value "$@"; TEAM_ID="$2"; shift 2 ;;
            --sign-identity)   need_value "$@"; SIGN_IDENTITY="$2"; shift 2 ;;
            --notary-profile)  need_value "$@"; NOTARY_PROFILE="$2"; shift 2 ;;
            --entitlements)    need_value "$@"; ENTITLEMENTS="$2"; shift 2 ;;
            --output)          need_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
            --version)         need_value "$@"; VERSION="$2"; shift 2 ;;
            --build)           need_value "$@"; BUILD_NUMBER="$2"; shift 2 ;;
            --single-arch)     need_value "$@"; ARCH="$2"; shift 2 ;;
            --skip-notary)     SKIP_NOTARY=true; shift ;;
            --skip-build)      SKIP_BUILD=true; shift ;;
            --)                shift; break ;;
            *)                 usage >&2; die "unknown option: $1" ;;
        esac
    done
    if [[ $# -gt 0 ]]; then
        die "unexpected positional arguments: $*"
    fi
    return 0
}

normalize_and_validate() {
    # "any" is the readable spelling of the same escape hatch as an empty value:
    # pick the identity by certificate name alone and skip the sealed Team check.
    case "$TEAM_ID" in
        any|ANY|Any|'') TEAM_ID="" ;;
    esac

    if [[ -n "$ARCH" ]]; then
        case "$ARCH" in
            arm64|x86_64) ARTIFACT_BASENAME="${PRODUCT_STEM}-macOS-${ARCH}" ;;
            *) die "--single-arch accepts arm64 or x86_64 (got: ${ARCH})" ;;
        esac
    else
        ARTIFACT_BASENAME="${PRODUCT_STEM}-Universal"
    fi

    case "$ENTITLEMENTS" in
        /*) : ;;
        *)  ENTITLEMENTS="$(pwd)/${ENTITLEMENTS}" ;;
    esac

    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="${PACKAGE_ROOT}/dist"
    fi
    case "$OUTPUT_DIR" in
        /*) : ;;
        *)  OUTPUT_DIR="$(pwd)/${OUTPUT_DIR}" ;;
    esac
    OUTPUT_DIR="${OUTPUT_DIR%/}"
    if [[ -z "$OUTPUT_DIR" || "$OUTPUT_DIR" == "/" || "$OUTPUT_DIR" == "$PACKAGE_ROOT" ]]; then
        die "--output must be a directory below the repository root (got: ${OUTPUT_DIR:-empty})"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
require_tools() {
    local t missing=""
    for t in swift codesign hdiutil ditto plutil spctl shasum lipo od security \
             find grep sed awk tr xcrun; do
        if ! command -v "$t" >/dev/null 2>&1; then missing="${missing} ${t}"; fi
    done
    if [[ -n "$missing" ]]; then
        die "missing required command line tools:${missing}"
    fi
    if ! xcrun notarytool --help >/dev/null 2>&1; then
        die "xcrun notarytool is unavailable: a full Xcode install is required, not just the CLT"
    fi
    if [[ "$(uname -s)" != "Darwin" ]]; then
        die "codesign, hdiutil and notarytool require a macOS host"
    fi
    return 0
}

require_repo_shape() {
    [[ -f "${PACKAGE_ROOT}/Package.swift" ]] || die "Package.swift not found at ${PACKAGE_ROOT}"
    [[ -f "$PACKAGER" ]] || die "packer not found: $PACKAGER"
    # A project or workspace would change where the bundle and its Info.plist
    # come from, so this pipeline has to be re-read rather than silently run.
    if find "$PACKAGE_ROOT" -maxdepth 2 \
            \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) \
            -not -path "${PACKAGE_ROOT}/.build/*" 2>/dev/null | grep -q .; then
        die "an Xcode project appeared in the repository: bundle assembly no longer matches this script"
    fi
    if [[ ! -f "$ENTITLEMENTS" ]]; then
        die "entitlements file not found: ${ENTITLEMENTS}"
    fi
    if ! plutil -lint "$ENTITLEMENTS" >/dev/null 2>&1; then
        die "entitlements file is not a valid plist: ${ENTITLEMENTS}"
    fi
    # plutil -lint is lenient where AMFI is not: an entitlements plist can lint
    # clean and still fail the seal, the usual culprit being a double hyphen
    # inside a comment. Catch it here rather than in stage 3, after a build.
    if command -v xmllint >/dev/null 2>&1; then
        if ! xmllint --noout "$ENTITLEMENTS" >/dev/null 2>&1; then
            xmllint --noout "$ENTITLEMENTS" 2>&1 | sed 's/^/         /' >&2
            die "entitlements file is not strictly valid XML, which the AMFI parser inside codesign requires: ${ENTITLEMENTS}"
        fi
    else
        warn "xmllint is unavailable: the entitlements file is only checked by plutil -lint"
    fi
    return 0
}

# Resolve one exact keychain identity. TEAM_ID is matched against the
# parenthesised suffix because two Teams can hold a certificate of the same name.
resolve_identity() {
    local listing matches n
    listing=$(security find-identity -v -p codesigning 2>/dev/null || true)
    if [[ -z "$listing" ]]; then
        die "security find-identity returned nothing: is the keychain unlocked?"
    fi
    matches=$(printf '%s\n' "$listing" | grep -F "\"${SIGN_IDENTITY}" || true)
    if [[ -n "$TEAM_ID" ]]; then
        matches=$(printf '%s\n' "$matches" | grep -F "(${TEAM_ID})" || true)
    fi
    n=$(printf '%s\n' "$matches" | grep -c '"' | tr -d ' ' || true)
    if [[ "${n:-0}" -eq 0 ]]; then
        {
            printf 'no signing identity matches "%s" for Team ID "%s"\n' "$SIGN_IDENTITY" "${TEAM_ID:-any}"
            printf '       identities available on this machine:\n'
            printf '%s\n' "$listing" | grep -F '"' | sed 's/^/         /' || printf '         (none)\n'
            printf '       import one: security import <DeveloperID.p12> -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign\n'
            printf '       or name the Team that owns it: --team-id <id> / TEAM_ID=<id>\n'
        } >&2
        die "cannot sign: see the identity list above"
    fi
    if [[ "$n" -gt 1 ]]; then
        {
            printf 'several identities match "%s" for Team "%s", refusing to guess:\n' "$SIGN_IDENTITY" "${TEAM_ID:-any}"
            printf '%s\n' "$matches" | sed 's/^/         /'
        } >&2
        die "narrow the match with --team-id or --sign-identity"
    fi
    RESOLVED_IDENTITY=$(printf '%s\n' "$matches" | grep -o '"[^"]*"' | head -n 1 | sed 's/^"//; s/"$//')
    if [[ -z "$RESOLVED_IDENTITY" ]]; then
        die "an identity matched but its name could not be parsed out of find-identity output"
    fi
    # Developer ID is what notarization accepts. Anything else signs fine, gets
    # rejected on submission, and would otherwise produce an uninstallable zip.
    case "$RESOLVED_IDENTITY" in
        "Developer ID Application"*) : ;;
        *)
            if $SKIP_NOTARY; then
                warn "${RESOLVED_IDENTITY} cannot be notarized; accepted only because notarization is skipped"
            else
                die "notarization requires a Developer ID Application certificate, but the match is '${RESOLVED_IDENTITY}'"
            fi ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Scratch dir and cleanup
# ---------------------------------------------------------------------------
make_scratch() {
    local base="${TMPDIR:-/tmp}"
    base="${base%/}"
    WORK=$(mktemp -d "${base}/popopx-node-release.XXXXXX") || die "mktemp -d failed"
    chmod 700 "$WORK"
    STAGE_DIR="${WORK}/stage"
    mkdir -p "$STAGE_DIR" || die "cannot create the staging directory ${STAGE_DIR}"
    return 0
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK" && -d "$WORK" ]]; then
        case "$WORK" in
            /var/folders/*|/private/var/folders/*|/tmp/*|/private/tmp/*)
                rm -rf -- "$WORK" || true ;;
            *)
                if [[ -n "${TMPDIR:-}" && "$WORK" == "${TMPDIR%/}/popopx-node-release."* ]]; then
                    rm -rf -- "$WORK" || true
                else
                    warn "refusing to remove an unexpected scratch directory: ${WORK}"
                fi ;;
        esac
    fi
    if [[ $rc -ne 0 ]]; then
        printf '%sFAILED:%s build-release.sh aborted (exit=%d)\n' "$C_RED" "$C_RESET" "$rc" >&2
    fi
    exit "$rc"
}

# ---------------------------------------------------------------------------
# [2/6] Assemble the unsigned bundle through the packer's seam
# ---------------------------------------------------------------------------
assemble_step() {
    step 2 "Assemble the unsigned bundle (Scripts/build_dmg.sh --emit-app)"
    local -a pack_args=(--emit-app "$STAGE_DIR")
    if [[ -n "$VERSION" ]];      then pack_args+=(--version "$VERSION"); fi
    if [[ -n "$BUILD_NUMBER" ]]; then pack_args+=(--build "$BUILD_NUMBER"); fi
    if [[ -n "$ARCH" ]];         then pack_args+=(--single-arch "$ARCH"); fi
    if $SKIP_BUILD;              then pack_args+=(--skip-build); fi

    # IFS is newline/tab here, so "${pack_args[*]}" would scatter the echo over
    # several lines; join with spaces for the transcript only.
    local display="" a
    for a in "${pack_args[@]}"; do display="${display}${display:+ }${a}"; done
    dim "\$ bash Scripts/build_dmg.sh ${display}"
    if ! bash "$PACKAGER" "${pack_args[@]}"; then
        die "bundle assembly failed inside Scripts/build_dmg.sh"
    fi

    APP_PATH="${STAGE_DIR}/${APP_BUNDLE_NAME}"
    if [[ ! -x "${APP_PATH}/Contents/MacOS/${EXEC_NAME}" ]]; then
        die "the packer emitted no executable at ${APP_PATH}/Contents/MacOS/${EXEC_NAME}"
    fi

    assert_version_identity
    drop_inherited_signature
    derive_artifact_basename
    return 0
}

# The name has to describe what was built, not what was asked for: --skip-build
# hands back whatever already sits in .build, which is universal even when a
# single architecture was requested.
derive_artifact_basename() {
    local archs="" label=""
    archs=$(lipo -archs "${APP_PATH}/Contents/MacOS/${EXEC_NAME}" 2>/dev/null | tr -d '\r' || true)
    case "$archs" in
        *arm64*x86_64*|*x86_64*arm64*) label="Universal" ;;
        *arm64*)  label="macOS-arm64" ;;
        *x86_64*) label="macOS-x86_64" ;;
        *) die "cannot name the artifacts: lipo -archs reported nothing useful for the emitted binary (${archs:-empty})" ;;
    esac
    if [[ -n "$ARCH" && "$label" != "macOS-${ARCH}" ]]; then
        warn "--single-arch ${ARCH} was requested, but the emitted binary carries [${archs}]: the name follows what was actually built"
    fi
    ARTIFACT_BASENAME="${PRODUCT_STEM}-${label}"
    info "artifacts: ${ARTIFACT_BASENAME}.dmg / .zip (architectures measured, not assumed)"
    return 0
}

# Guards the release incident this pipeline exists to prevent: an artifact whose
# reported version differed from the tag it shipped under. The packer owns the
# plist, so the only check worth making happens after it has been written.
assert_version_identity() {
    local plist="${APP_PATH}/Contents/Info.plist" short build want_core
    short=$(plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || true)
    build=$(plutil -extract CFBundleVersion raw "$plist" 2>/dev/null || true)
    if [[ -z "$short" ]]; then
        die "CFBundleShortVersionString could not be read from the emitted Info.plist: ${plist}"
    fi
    if [[ -z "$build" ]]; then
        die "CFBundleVersion could not be read from the emitted Info.plist: ${plist}"
    fi
    if [[ -n "$VERSION" ]]; then
        want_core="${VERSION#v}"
        want_core=$(printf '%s\n' "$want_core" \
            | sed -n 's/^\([0-9][0-9]*\(\.[0-9][0-9]*\)\{1,2\}\).*/\1/p')
        if [[ -z "$want_core" ]]; then
            die "--version carries no numeric core to compare against: '${VERSION}'"
        fi
        if [[ "$short" != "$want_core" ]]; then
            die "version mismatch: the bundle reports ${short}, --version asked for ${want_core} (build ${build})"
        fi
        info "version asserted against the emitted Info.plist: ${short}"
    else
        info "version taken from Scripts/build_dmg.sh defaults: ${short}"
    fi
    info "CFBundleShortVersionString = ${short}"
    info "CFBundleVersion            = ${build}"
    return 0
}

# The Swift toolchain ad-hoc signs the binary it links, so a freshly assembled
# bundle is not unsigned: it carries an adhoc,linker-signed code directory whose
# Identifier is the target name rather than the bundle id. Clear it so the
# Developer ID seal cannot inherit a signature that disagrees with its plist.
drop_inherited_signature() {
    local flags=""
    flags=$(signing_flags "$APP_PATH")
    if [[ -z "$flags" ]]; then
        info "the bundle carries no code signature"
        return 0
    fi
    info "pre-existing signature ${flags}: removing it before Developer ID signing"
    codesign --remove-signature "$APP_PATH" >/dev/null 2>&1 || true
    codesign --remove-signature "${APP_PATH}/Contents/MacOS/${EXEC_NAME}" >/dev/null 2>&1 || true
    if [[ -n "$(signing_flags "$APP_PATH")" ]]; then
        die "the pre-existing signature survived codesign --remove-signature; refusing to seal over it"
    fi
    if ! is_macho "${APP_PATH}/Contents/MacOS/${EXEC_NAME}"; then
        # Covers both shapes: a universal slice starts with the fat magic, a
        # single-arch build with the thin one.
        die "the executable stopped being a Mach-O under codesign --remove-signature"
    fi
    info "signature cleared (no CodeDirectory is reported any more)"
    return 0
}

# ---------------------------------------------------------------------------
# Mach-O discovery
# ---------------------------------------------------------------------------
is_macho() {
    local magic=""
    magic=$(LC_ALL=C od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n' || true)
    case "$magic" in
        cffaedfe|cefaedfe|fefaedcf|fefaced|cafebabe|bebafeca|deadcafe|cafedade) return 0 ;;
        *) return 1 ;;
    esac
}

# Every Mach-O under a directory, NUL-delimited, regular files only, so a
# framework's Versions/Current symlink is never walked twice.
list_macho() {
    local root="$1" f
    [[ -d "$root" ]] || return 0
    while IFS= read -r -d '' f; do
        if is_macho "$f"; then printf '%s\0' "$f"; fi
    done < <(find "$root" -type f ! -path '*.dSYM/*' -print0 2>/dev/null)
    return 0
}

describe_archs() {
    local a=""
    a=$(lipo -archs "$1" 2>/dev/null | tr -d '\r' || true)
    printf '%s\n' "${a:-unknown}"
    return 0
}

# ---------------------------------------------------------------------------
# [3/6] Inside-out deep signing
# ---------------------------------------------------------------------------
# Entitlement key names, read from a plist on stdin. codesign writes the sealed
# copy back as a single XML line, so whole-line matching finds nothing: split on
# '<' first, then a key name is simply the body of a line starting with "key>".
entitlement_keys() {
    LC_ALL=C tr '<' '\n' | sed -n 's:^key>\(.*\)$:\1:p' | LC_ALL=C sort
}

# codesign hands the entitlements to AMFI, which parses more strictly than
# plutil does. Re-converting with plutil strips comments and any layout a given
# AMFI build cannot handle, while the annotated file stays in the repository as
# the human-editable interface. XML, not binary, is the shape this codesign
# accepts: a binary entitlements plist fails with "Could not create string from
# entitlements data". The key set is compared against the source, so
# normalization can never quietly alter what is being requested.
prepare_entitlements() {
    local want got
    SIGNING_ENTITLEMENTS="${WORK}/entitlements-signing.plist"
    if ! plutil -convert xml1 -o "$SIGNING_ENTITLEMENTS" "$ENTITLEMENTS" 2>/dev/null; then
        die "plutil could not normalize the entitlements file: ${ENTITLEMENTS}"
    fi
    if ! plutil -lint "$SIGNING_ENTITLEMENTS" >/dev/null 2>&1; then
        die "the normalized entitlements file does not lint: ${SIGNING_ENTITLEMENTS}"
    fi
    want=$(plutil -convert xml1 -o - "$ENTITLEMENTS" 2>/dev/null | entitlement_keys)
    got=$(plutil -convert xml1 -o - "$SIGNING_ENTITLEMENTS" 2>/dev/null | entitlement_keys)
    if [[ "$want" != "$got" ]]; then
        {
            printf 'source keys:     %s\n' "$(printf '%s\n' "$want" | tr '\n' ' ')"
            printf 'normalized keys: %s\n' "$(printf '%s\n' "$got" | tr '\n' ' ')"
        } >&2
        die "normalizing the entitlements file changed the requested key set"
    fi
    return 0
}

# Nested code has to be sealed before the bundle containing it, otherwise the
# outer seal covers a signature Apple rejects at notarization time.
deep_sign_step() {
    step 3 "Deep-sign under the hardened runtime (inside-out)"
    local contents="${APP_PATH}/Contents"
    local main_exec="${contents}/MacOS/${EXEC_NAME}"
    local nested=0 f item err=""
    local -a base=(--force --options runtime --timestamp --sign "$RESOLVED_IDENTITY")
    err="${WORK}/codesign.err"

    # Fail before any code is touched, not after the nested seals.
    prepare_entitlements

    if [[ ! -f "$main_exec" ]]; then
        die "the main executable vanished from the staged bundle: ${main_exec}"
    fi
    info "identity: ${RESOLVED_IDENTITY}"
    info "architectures: $(describe_archs "$main_exec")"
    dim "\$ codesign --force --options runtime --timestamp --sign \"${RESOLVED_IDENTITY}\" [--entitlements ...] <target>"

    # Pass 1 - loose Mach-O files: dylibs, framework binaries and any embedded
    # server helper (an smp-server / xftp-server / *.dylib would land here). The
    # main executable is skipped; it is sealed with the bundle, which is how its
    # entitlements get attached.
    while IFS= read -r -d '' f; do
        if [[ "$f" == "$main_exec" ]]; then continue; fi
        if ! codesign "${base[@]}" "$f" 2>"$err"; then
            printf '%s\n' "$(cat "$err" 2>/dev/null || true)" >&2
            die "failed to sign a nested Mach-O: $f"
        fi
        nested=$((nested + 1))
        dim "signed nested binary: ${f#"$APP_PATH"/}"
    done < <(list_macho "$contents")

    # Pass 2 - nested code bundles, deepest first, so an inner .app or .xpc is
    # sealed before the bundle embedding it.
    while IFS= read -r -d '' item; do
        if ! codesign "${base[@]}" "$item" 2>"$err"; then
            printf '%s\n' "$(cat "$err" 2>/dev/null || true)" >&2
            die "failed to seal a nested code bundle: ${item}"
        fi
        nested=$((nested + 1))
        dim "sealed nested bundle: ${item#"$APP_PATH"/}"
    done < <(find "$contents" -depth -mindepth 1 -type d \
                \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \
                   -o -name '*.bundle' -o -name '*.app' \) -print0 2>/dev/null)

    if [[ "$nested" -eq 0 ]]; then
        info "no nested Mach-O: the executable is the only code inside Contents/"
    else
        info "nested code signed: ${nested}"
    fi

    # Pass 3 - the bundle, with the entitlements attached and Info.plist sealed.
    if ! codesign "${base[@]}" \
            --identifier "$BUNDLE_ID" \
            --entitlements "$SIGNING_ENTITLEMENTS" \
            "$APP_PATH" 2>"$err"; then
        printf '%s\n' "$(cat "$err" 2>/dev/null || true)" >&2
        die "codesign failed to seal the bundle: ${APP_PATH}"
    fi

    verify_signature
    return 0
}

verify_signature() {
    local report="" flags="" detail="" sealed_team=""
    if ! report=$(codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1); then
        printf '%s\n' "$report" >&2
        die "codesign --verify --deep --strict did not pass"
    fi
    flags=$(signing_flags "$APP_PATH")
    if [[ -z "$flags" ]]; then
        die "codesign -dvv reports no CodeDirectory after signing: the seal did not take"
    fi
    case "$flags" in
        *runtime*) : ;;
        *) die "the hardened runtime is not active (flags=${flags}): --options runtime never reached the bundle" ;;
    esac
    case "$flags" in
        *adhoc*) die "the bundle is still ad-hoc signed (flags=${flags}); a Developer ID seal was expected" ;;
    esac
    detail=$(codesign -dvvv "$APP_PATH" 2>&1 || true)
    if ! printf '%s\n' "$detail" | grep -q 'Timestamp='; then
        die "the signature carries no secure timestamp: notarization would reject this build"
    fi
    if [[ "$(printf '%s\n' "$detail" | sed -n 's/^Identifier=\(.*\)$/\1/p' | head -n 1)" != "$BUNDLE_ID" ]]; then
        die "the sealed Identifier is not ${BUNDLE_ID}: check CFBundleIdentifier in the emitted Info.plist"
    fi
    # The authoritative Team check is made on the seal, not on the certificate
    # display name: only "Developer ID Application: <Org> (<TeamID>)" carries the
    # Team in parentheses, while an Apple Development name ends with a certificate
    # id instead. Notarization refuses a bundle sealed by another Team, so the
    # sealed TeamIdentifier is what has to agree with TEAM_ID.
    if [[ -n "$TEAM_ID" ]]; then
        sealed_team=$(printf '%s\n' "$detail" | sed -n 's/^TeamIdentifier=\(.*\)$/\1/p' | head -n 1)
        if [[ "$sealed_team" != "$TEAM_ID" ]]; then
            die "the sealed bundle reports TeamIdentifier=${sealed_team:-none}, not ${TEAM_ID}: the matched identity does not belong to that Team"
        fi
        info "sealed TeamIdentifier: ${sealed_team}"
    fi
    verify_sealed_entitlements
    info "codesign --verify --deep --strict: passed"
    dim "$(printf '%s\n' "$detail" | grep -E '^(Identifier|Format|CodeDirectory|TeamIdentifier|Signature|Timestamp)' | tr '\n' ' ')"
    return 0
}

# Every key in the plist must survive into the seal and no others may appear:
# a dropped or inherited entitlement is otherwise invisible until Gatekeeper.
verify_sealed_entitlements() {
    local want got key
    want=$(plutil -convert xml1 -o - "$ENTITLEMENTS" 2>/dev/null | entitlement_keys)
    if [[ -z "$want" ]]; then
        die "no entitlement keys found in ${ENTITLEMENTS}: refusing to seal an empty request silently"
    fi
    got=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | entitlement_keys)
    if [[ -z "$got" ]]; then
        die "the sealed bundle reports no entitlements at all"
    fi
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        if ! printf '%s\n' "$got" | grep -qxF -- "$key"; then
            die "entitlement ${key} never reached the sealed bundle"
        fi
    done <<< "$want"
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        if ! printf '%s\n' "$want" | grep -qxF -- "$key"; then
            die "entitlement ${key} is sealed but not requested by ${ENTITLEMENTS}"
        fi
    done <<< "$got"
    info "entitlements sealed exactly as requested ($(printf '%s\n' "$want" | grep -c . | tr -d ' ') keys)"
    dim "$(printf '%s\n' "$want" | tr '\n' ' ')"
    return 0
}

# ---------------------------------------------------------------------------
# Notarization primitive
# ---------------------------------------------------------------------------
# submit_wait <file> <label>: blocks until Apple answers, prints the issuer log
# on any non-Accepted outcome, and fails rather than packaging a bad artifact.
submit_wait() {
    local target="$1" label="$2" json="" id="" status="" raw=""
    json="${WORK}/notary-${label}.json"
    if ! xcrun notarytool submit "$target" \
            --keychain-profile "$NOTARY_PROFILE" \
            --output-format json >"$json" 2>"${json}.err"; then
        printf '%s\n' "$(cat "${json}.err" 2>/dev/null || true)" >&2
        die "notarytool submit failed for ${label} (credential profile: ${NOTARY_PROFILE})"
    fi
    id=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([0-9A-Fa-f-]\{36\}\)".*/\1/p' "$json" | head -n 1 || true)
    if [[ ! "$id" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
        raw=$(tr -d '\n' < "$json" 2>/dev/null | cut -c1-400 || true)
        printf 'the submission id could not be read, so its issuer log cannot be fetched\n       raw output: %s\n' "${raw:-empty}" >&2
        die "unparsable notarytool response for ${label}"
    fi
    info "${label}: submission ${id}"

    if ! xcrun notarytool wait "$id" --keychain-profile "$NOTARY_PROFILE" \
            --timeout "$NOTARY_TIMEOUT" >"${WORK}/notary-wait.log" 2>&1; then
        printf '%s\n' "$(cat "${WORK}/notary-wait.log" 2>/dev/null || true)" >&2
        warn "notarytool wait exited non-zero for ${id}; reading its final state"
    fi
    # notarytool prints its fields indented by two spaces, so a "^status:" anchor
    # matches nothing and an Accepted submission reads as "no status". JSON is the
    # stable shape; the text form is only a fallback, parsed with the indentation
    # tolerated. Both paths swallow their own exit status because a failed
    # substitution under set -e would abort before the diagnostic below.
    status=$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" \
        --output-format json 2>/dev/null \
        | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n 1 || true)
    if [[ -z "$status" ]]; then
        status=$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1 \
            | sed -n 's/^[[:space:]]*status:[[:space:]]*\(.*\)$/\1/p' \
            | head -n 1 | tr -d '\r' || true)
    fi
    if [[ -z "$status" ]]; then
        die "notarytool info reported no status for submission ${id}"
    fi
    if [[ "$status" != "Accepted" ]]; then
        {
            printf 'notarization was not accepted for %s: status=%s\n' "$label" "$status"
            printf '       issuer log for submission %s follows\n' "$id"
            xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1 || \
                printf '       (log not available yet; re-run: xcrun notarytool log %s --keychain-profile %s)\n' \
                    "$id" "$NOTARY_PROFILE"
        } >&2
        die "refusing to package an artifact Apple did not accept"
    fi
    info "${label}: Accepted by Apple"
    NOTARIZED=true
    return 0
}

# ---------------------------------------------------------------------------
# [4/6] Notarize the app, then staple what can be stapled
# ---------------------------------------------------------------------------
notarize_app_step() {
    step 4 "Notarize the app bundle, then staple and assess Gatekeeper"
    if $SKIP_NOTARY; then
        warn "--skip-notary: nothing was submitted and no ticket exists"
        info "these artifacts are Developer ID signed but NOT notarized"
        dim "Gatekeeper blocks an unnotarized download; use this mode for local signing checks only"
        # The verdict is still printed: a Developer ID build that spctl cannot
        # accept has a signing problem, and that is worth seeing before a
        # notarization round trip is spent to discover it.
        gatekeeper_assess "$APP_PATH" "staged bundle (notarization skipped)"
        return 0
    fi
    local zip="${WORK}/notarize-app.zip"
    # --keepParent stores the .app inside the archive, which is the layout the
    # notarization service expects for a bundle submission.
    dim "\$ ditto -c -k --keepParent \"${APP_BUNDLE_NAME}\" <scratch>/notarize-app.zip"
    ( cd "$STAGE_DIR" && ditto -c -k --keepParent "$APP_BUNDLE_NAME" "$zip" ) \
        || die "failed to build the notarization archive ${zip}"
    if [[ ! -s "$zip" ]]; then
        die "the notarization archive is empty: ${zip}"
    fi
    submit_wait "$zip" "app"
    staple_app
    gatekeeper_assess "$APP_PATH" "staged bundle"
    return 0
}

staple_app() {
    # A .app directory has no resource fork to hold a ticket, so on APFS this
    # usually fails. The DMG in stage 5 is the artifact that really gets stapled.
    if xcrun stapler staple "$APP_PATH" >/dev/null 2>&1; then
        if xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
            info "ticket stapled into the bundle and validated"
            STAPLED_TARGET="$APP_PATH"
        else
            warn "stapler reported success but validate failed on the bundle; relying on the DMG ticket"
        fi
    else
        info "the bundle itself cannot hold a ticket (expected for a .app directory on APFS)"
        dim "Gatekeeper checks notarization online for a ZIP download; the DMG carries the offline ticket"
    fi
    return 0
}

gatekeeper_assess() {
    local target="$1" label="$2" report=""
    report=$(spctl --assess --type execute --verbose=4 "$target" 2>&1 || true)
    if [[ -z "$report" ]]; then
        report="(spctl produced no output)"
    fi
    info "spctl --assess --type execute --verbose=4 (${label})"
    printf '%s\n' "$report" | sed 's/^/         /'
    if printf '%s\n' "$report" | grep -qi 'accepted'; then
        info "Gatekeeper accepted the ${label}"
        return 0
    fi
    if $NOTARIZED; then
        die "Gatekeeper rejected a notarized Developer ID ${label}: read the spctl output above"
    fi
    warn "rejection is expected while notarization is skipped or unavailable"
    return 0
}

# ---------------------------------------------------------------------------
# [5/6] Package the DMG and the distribution ZIP
# ---------------------------------------------------------------------------
package_step() {
    step 5 "Build the signed distribution DMG and ZIP"
    mkdir -p "$OUTPUT_DIR" || die "cannot create the output directory: $OUTPUT_DIR"

    local root="${WORK}/dmg-root"
    mkdir -p "$root" || die "cannot create the DMG staging directory"
    # ditto preserves bundle permissions, xattrs and symlink semantics.
    ditto "$APP_PATH" "${root}/${APP_BUNDLE_NAME}" || die "failed to copy the app into DMG staging"
    ln -sfh /Applications "${root}/Applications" || die "failed to create the Applications symlink"
    if [[ ! -L "${root}/Applications" ]]; then
        die "the Applications symlink did not materialize in ${root}"
    fi

    dim "\$ hdiutil create -volname \"${VOL_NAME}\" -srcfolder <staging> -ov -format UDZO -o ${ARTIFACT_BASENAME}"
    # -o appends .dmg when the name has no extension, so only the stem is passed
    # and the final path is asserted afterwards. -type and -format are mutually
    # exclusive; only -format is used. The output directory must already exist.
    hdiutil create -volname "$VOL_NAME" -srcfolder "$root" -ov -format UDZO -quiet \
        -o "${OUTPUT_DIR}/${ARTIFACT_BASENAME}" || die "hdiutil create failed"
    DMG_PATH="${OUTPUT_DIR}/${ARTIFACT_BASENAME}.dmg"
    if [[ ! -f "$DMG_PATH" ]]; then
        die "hdiutil did not produce the expected image: ${DMG_PATH}"
    fi
    if [[ -e "${OUTPUT_DIR}/${ARTIFACT_BASENAME}" && ! -d "${OUTPUT_DIR}/${ARTIFACT_BASENAME}" ]]; then
        warn "removing the extension-less leftover hdiutil left beside the image"
        rm -f -- "${OUTPUT_DIR}/${ARTIFACT_BASENAME}"
    fi
    info "DMG: ${DMG_PATH} ($(du -h "$DMG_PATH" 2>/dev/null | awk '{print $1}'))"

    if ! $SKIP_NOTARY; then
        submit_wait "$DMG_PATH" "dmg"
        if ! xcrun stapler staple "$DMG_PATH" >/dev/null 2>&1; then
            die "failed to staple the notarization ticket into ${DMG_PATH}"
        fi
        if ! xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1; then
            die "stapler validate failed on ${DMG_PATH}: the ticket is not actually embedded"
        fi
        info "ticket stapled into the DMG and validated (Gatekeeper can check it offline)"
    fi

    # The distribution zip is built after stapling, so wherever a ticket can
    # live it is inside the archive the user downloads.
    DIST_ZIP="${OUTPUT_DIR}/${ARTIFACT_BASENAME}.zip"
    dim "\$ ditto -c -k --keepParent \"${APP_BUNDLE_NAME}\" ${ARTIFACT_BASENAME}.zip"
    ( cd "$STAGE_DIR" && ditto -c -k --keepParent "$APP_BUNDLE_NAME" "$DIST_ZIP" ) \
        || die "failed to build the distribution archive ${DIST_ZIP}"
    if [[ ! -s "$DIST_ZIP" ]]; then
        die "the distribution archive is empty: ${DIST_ZIP}"
    fi
    info "ZIP: ${DIST_ZIP} ($(du -h "$DIST_ZIP" 2>/dev/null | awk '{print $1}'))"

    verify_shipped_app
    return 0
}

# Re-check what actually ships, rather than only the staged bundle it came from.
verify_shipped_app() {
    local inner="" report=""
    MOUNT_POINT="${WORK}/mnt"
    mkdir -p "$MOUNT_POINT"
    if ! hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null 2>&1; then
        die "cannot mount the finished DMG for verification: ${DMG_PATH}"
    fi
    inner="${MOUNT_POINT}/${APP_BUNDLE_NAME}"
    if [[ ! -d "$inner" ]]; then
        hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
        MOUNT_POINT=""
        die "the app is missing from the finished DMG: expected ${APP_BUNDLE_NAME} at the volume root"
    fi
    if ! codesign --verify --strict --verbose=2 "$inner" >/dev/null 2>&1; then
        hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
        MOUNT_POINT=""
        die "the app inside the DMG does not verify: the seal was broken while packaging"
    fi
    info "DMG contents: codesign --verify --strict passed"
    report=$(spctl --assess --type execute --verbose=4 "$inner" 2>&1 || true)
    if [[ -n "$report" ]]; then
        printf '%s\n' "$report" | sed 's/^/         /'
    fi
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
    MOUNT_POINT=""
    return 0
}

# ---------------------------------------------------------------------------
# [6/6] Checksums and the acceptance report
# ---------------------------------------------------------------------------
checksum_and_report_step() {
    step 6 "Checksums and acceptance report"
    local sums="${OUTPUT_DIR}/SHA256SUMS.txt"
    local dmg_name zip_name plist short build flags count
    dmg_name=$(basename -- "$DMG_PATH")
    zip_name=$(basename -- "$DIST_ZIP")

    # Relative names only: a checksum file carrying a path leaks the build
    # machine and cannot be verified with -c from the artifact directory.
    ( cd "$OUTPUT_DIR" && shasum -a 256 "$dmg_name" "$zip_name" > "SHA256SUMS.txt" ) \
        || die "shasum -a 256 failed"
    if [[ ! -s "$sums" ]]; then
        die "no checksum file was written: ${sums}"
    fi
    count=$(grep -c . "$sums" | tr -d ' ' || true)
    if [[ "${count:-0}" != "2" ]]; then
        die "SHA256SUMS.txt must list exactly the DMG and the ZIP, got ${count:-0} lines"
    fi
    if LC_ALL=C grep -a -q -F -- "/" "$sums"; then
        die "SHA256SUMS.txt must not contain any path separator"
    fi
    if ! LC_ALL=C grep -Eq "^[0-9a-f]{64}  ${dmg_name//./\\.}\$" "$sums"; then
        die "malformed checksum line for ${dmg_name}"
    fi
    if ! LC_ALL=C grep -Eq "^[0-9a-f]{64}  ${zip_name//./\\.}\$" "$sums"; then
        die "malformed checksum line for ${zip_name}"
    fi
    ( cd "$OUTPUT_DIR" && shasum -a 256 -c "SHA256SUMS.txt" >/dev/null ) \
        || die "checksum self-verification failed in ${OUTPUT_DIR}"
    info "shasum -a 256 -c self-verification passed"
    while IFS= read -r line; do dim "$line"; done < "$sums"

    plist="${APP_PATH}/Contents/Info.plist"
    short=$(plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || echo '?')
    build=$(plutil -extract CFBundleVersion raw "$plist" 2>/dev/null || echo '?')
    flags=$(signing_flags "$APP_PATH")
    printf '\n'
    printf '%sAcceptance report%s\n' "$C_BOLD" "$C_RESET"
    printf '  %-22s %s\n' "Version"          "${short} (build ${build})"
    printf '  %-22s %s\n' "Architectures"    "$(describe_archs "${APP_PATH}/Contents/MacOS/${EXEC_NAME}")"
    printf '  %-22s %s\n' "Bundle ID"        "$BUNDLE_ID"
    printf '  %-22s %s\n' "Identity"         "$RESOLVED_IDENTITY"
    printf '  %-22s %s\n' "CodeDirectory"    "${flags:-unknown}"
    printf '  %-22s %s\n' "Entitlements"     "${ENTITLEMENTS#"$PACKAGE_ROOT"/}"
    if $NOTARIZED; then
        printf '  %-22s %s\n' "Notarization" "Accepted (app and DMG submitted)"
    else
        printf '  %-22s %s\n' "Notarization" "SKIPPED - not distributable"
    fi
    if [[ -n "$STAPLED_TARGET" ]]; then
        printf '  %-22s %s\n' "Ticket" "stapled into the bundle and the DMG"
    elif ! $SKIP_NOTARY; then
        printf '  %-22s %s\n' "Ticket" "stapled into the DMG only"
    else
        printf '  %-22s %s\n' "Ticket" "none (notarization skipped)"
    fi
    printf '  %-22s %s\n' "DMG"              "$DMG_PATH"
    printf '  %-22s %s\n' "ZIP"              "$DIST_ZIP"
    printf '  %-22s %s\n' "Checksums"        "$sums"
    printf '\n  %sShip%s both containers together with SHA256SUMS.txt.\n' "${C_BOLD}" "${C_RESET}"
    printf '  On a fresh account: shasum -a 256 -c SHA256SUMS.txt, then mount the DMG and run\n'
    printf '  spctl --assess --type execute --verbose=4 "/Volumes/%s/%s"\n\n' "$VOL_NAME" "$APP_BUNDLE_NAME"
    return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    normalize_and_validate
    require_tools
    require_repo_shape
    resolve_identity
    make_scratch

    printf '%s=============================================================%s\n' "$C_BOLD" "$C_RESET"
    printf '%s  POPOPX Mac Node - Developer ID signing and notarization%s\n' "$C_BOLD" "$C_RESET"
    printf '%s=============================================================%s\n' "$C_BOLD" "$C_RESET"

    step 1 "Preflight"
    info "package root : ${PACKAGE_ROOT}"
    info "output dir   : ${OUTPUT_DIR}"
    info "artifacts    : ${ARTIFACT_BASENAME}.* (re-derived in stage 2 from the arches actually built)"
    if [[ -n "$ARCH" ]]; then
        info "target       : single-arch ${ARCH}"
    else
        info "target       : universal arm64 + x86_64"
    fi
    info "identity     : ${RESOLVED_IDENTITY}"
    info "entitlements : ${ENTITLEMENTS}"
    if $SKIP_NOTARY; then
        info "notary       : SKIPPED (--skip-notary)"
    else
        info "notary       : profile '${NOTARY_PROFILE}', submit and wait"
    fi
    dim  "swift: $(swift --version 2>&1 | head -n 1 || echo 'unavailable')"
    dim  "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown) ($(uname -m))"
    dim  "scratch: ${WORK}"

    assemble_step
    deep_sign_step
    notarize_app_step
    package_step
    checksum_and_report_step
}

main "$@"
