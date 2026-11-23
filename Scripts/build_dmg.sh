#!/usr/bin/env bash
#
# build_dmg.sh — POPOPX Mac Node 一键通用（Universal）.dmg 打包脚本
# POPOPX Mac Node — one-shot universal .dmg packager
#
# 本脚本在没有任何 Xcode 工程文件的前提下，手工组装一个标准 macOS `.app`
# Bundle（Info.plist / PkgInfo / MacOS 可执行文件 / AppIcon.icns），执行 Ad-hoc
# 代码签名，并用 hdiutil 打成可直接双击拖拽安装的
# `POPOPX-Mac-Node-Universal.dmg`，同时生成 `.sha256` 校验文件，最后执行开源
# 安全红线审计：发布产物内严禁出现开发机绝对路径。
#
# This script assembles a conventional macOS .app bundle by hand (there is
# deliberately no Xcode project), ad-hoc signs it, packs a drag-install DMG
# with a sha256 sidecar, and audits the finished artifacts for leaked
# developer machine paths.
#
# Copyright (C) 2026 POPOPX Chat
# SPDX-License-Identifier: AGPL-3.0-only
#
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# 常量 / Constants
# ---------------------------------------------------------------------------
SCRIPT_NAME=$(basename -- "$0")
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PACKAGE_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)

EXEC_NAME="PopopxMacNodeApp"                 # SPM 可执行产物名 = 磁盘上的二进制文件名（无空格）
APP_NAME="POPOPX Mac Node"                   # Bundle 展示名（含空格）
APP_BUNDLE_NAME="${APP_NAME}.app"
BUNDLE_ID="chat.popopx.node"
VOL_NAME="POPOPX Mac Node"
UNIVERSAL_DMG_BASENAME="POPOPX-Mac-Node-Universal"
MIN_MACOS="14.0"
DEFAULT_VERSION="1.0.2"
DEFAULT_BUILD="3"                            # CFBundleVersion 的仓库默认值；发新版本时与 DEFAULT_VERSION 一起递增
CONSOLE_URL="http://127.0.0.1:18920"

# ---------------------------------------------------------------------------
# 命令行状态 / CLI state
# ---------------------------------------------------------------------------
OUTPUT_DIR=""                                # 解析后强制为绝对路径
VERSION="${DEFAULT_VERSION}"
VERSION_SHORT="${DEFAULT_VERSION}"           # 数字核心，写入 CFBundleShortVersionString
VERSION_BUILD="${DEFAULT_VERSION}"           # 完整串（含 -rc1/-dev 后缀），写入 CFBundleVersion
BUILD_NUMBER="${DEFAULT_BUILD}"              # CFBundleVersion 的构建号；--build 覆盖，只在纯正式版本时生效
BUILD_EXPLICIT=false                         # 只有显式传 --build 时，构建号才压过版本的 -rc/-dev 后缀
SKIP_BUILD=false
SKIP_STRIP=false
NO_SIGN=false
SINGLE_ARCH=""                               # 空 = Universal 双架构
DMG_BASENAME="${UNIVERSAL_DMG_BASENAME}"     # 单架构时被改写
EMIT_APP_DIR=""                              # --emit-app: 只组装并导出未签名 bundle
EMIT_ONLY=false                              # 由 EMIT_APP_DIR 推导，见 normalize_and_validate

BUILD_PATH_TAKEN="n/a"
SIGN_STATE="n/a"
ICON_READY=false
APP_DIR=""
BINARY_IN_BUNDLE=""
DMG_PATH=""
MOUNT_POINT=""
WORK=""

# ---------------------------------------------------------------------------
# 输出 helpers
# ---------------------------------------------------------------------------
C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RESET=$(tput sgr0); C_BOLD=$(tput bold); C_DIM=$(tput dim)
    C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3); C_BLUE=$(tput setaf 4)
fi

TOTAL_STEPS=8
step()  { printf '%s[%s%d/%d%s]%s %s%s%s\n' "$C_BOLD" "$C_GREEN" "$1" "$TOTAL_STEPS" "$C_RESET" "$C_BOLD" "$C_BLUE" "$2" "$C_RESET"; }
info()  { printf '       %s\n' "$1"; }
dim()   { printf '       %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }
warn()  { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
die()   { printf '%sFATAL:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

usage() {
    cat <<USAGE
${SCRIPT_NAME} — 构建 POPOPX Mac Node 通用拖拽安装包 / build the Universal drag-install DMG

用法 / Usage:
    bash Scripts/build_dmg.sh [options]

选项 / Options:
    --output <dir>             产物输出目录（默认: <repo>/dist）
    --version <x.y.z>          写入 Info.plist 的版本号；接受 1.0.0 / v1.0.0 / v1.2.0-rc1
                               （默认: ${DEFAULT_VERSION}；数字核心进 CFBundleShortVersionString，
                                完整串进 CFBundleVersion）
    --build <n>                覆盖 CFBundleVersion 为独立的构建号（默认: ${DEFAULT_BUILD}）
                               不带 --version 后缀时生效；--version 带 -rc1/-dev 后缀则仍写完整串，
                               除非显式传入 --build。校验：只接受 [0-9A-Za-z.+-]+
    --single-arch <arch>       只构建单架构：arm64 | x86_64（默认: Universal 双架构）
    --skip-build               不编译，直接复用已有 .build/release 产物重新打包
    --no-sign                  跳过 codesign Ad-hoc 签名（仅供本地调试）
    --no-strip                 保留调试符号（DWARF 会带出编译机绝对路径，慎用）
    --emit-app <dir>           Assemble, strip and audit the bundle, then export the
                               UNSIGNED .app into <dir> and stop: no ad-hoc signature,
                               no DMG. Handover seam for build-release.sh, which needs
                               an unsigned bundle to apply Developer ID + hardened
                               runtime. Keeps Info.plist generation single-sourced.
    -h, --help                 显示本帮助

示例 / Examples:
    bash Scripts/build_dmg.sh
    bash Scripts/build_dmg.sh --output dist --version 1.2.0
    bash Scripts/build_dmg.sh --single-arch arm64 --version v1.2.0
    bash Scripts/build_dmg.sh --skip-build

输出 / Outputs (written into --output):
    ${UNIVERSAL_DMG_BASENAME}.dmg            Universal 镜像（单架构构建时命名为 POPOPX-Mac-Node-<arch>.dmg）
    ${UNIVERSAL_DMG_BASENAME}.dmg.sha256     '<64hex>  <相对文件名>' 格式校验文件

实现要点 / Implementation notes:
    * 全程在 \$(mktemp -d) 临时目录内组装，退出时由 trap 清理，只留下 --output 中的产物。
    * Ad-hoc 签名刻意不传 --options runtime：hardened runtime 与 Ad-hoc 签名
      组合会让部分 macOS 直接拒绝启动。
    * 本机 hdiutil 已实测的坑，脚本按以下方式规避：
        - '-o' 在目标名缺少扩展名时会自动追加 '.dmg' —— 因此只传基础名，
          随后断言最终路径恰好是 <name>.dmg；
        - '-type' 与 '-format' 互斥，绝不同时传；
        - '-stdinpass' 会把 stdin 末尾换行算进口令的一部分，本脚本不使用加密镜像；
        - 输出目录必须已存在，否则报 "No such file or directory"。
USAGE
}

# ---------------------------------------------------------------------------
# 参数解析与校验 / Argument parsing
# ---------------------------------------------------------------------------
need_value() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        die "选项 --${1} 需要一个参数值 (option --${1} requires a value)"
    fi
    return 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)      usage; exit 0 ;;
            --output)       need_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
            --version)      need_value "$@"; VERSION="$2"; shift 2 ;;
            --build)        need_value "$@"; BUILD_NUMBER="$2"; BUILD_EXPLICIT=true; shift 2 ;;
            --single-arch)  need_value "$@"; SINGLE_ARCH="$2"; shift 2 ;;
            --skip-build)   SKIP_BUILD=true; shift ;;
            --no-sign)      NO_SIGN=true; shift ;;
            --no-strip)     SKIP_STRIP=true; shift ;;
            --emit-app)     need_value "$@"; EMIT_APP_DIR="$2"; shift 2 ;;
            --)             shift; break ;;
            *)              usage >&2; die "未知参数 (unknown option): $1" ;;
        esac
    done
    if [[ $# -gt 0 ]]; then
        die "不接受位置参数 (unexpected positional arguments): $*"
    fi
    return 0
}

normalize_and_validate() {
    # 版本号规则（Apple 惯例）：
    #   CFBundleShortVersionString 只能是 1–3 段纯数字，因此预发布/构建后缀要剥掉；
    #   CFBundleVersion 可以是任意构建标识串，保留完整字符串。
    # 接受形态：1.2 / 1.2.3 / v1.2.3 / v1.2.3-rc1 / 0.0.0-dev-abcdef1
    local raw="${VERSION#v}"
    # 注意字符类写法：`-` 必须放在类首或类尾。写成 [.-+] 会被 POSIX ERE 解析成
    # “从 . (0x2E) 到 + (0x2B)”的非法区间，在 grep/[[ =~ ]] 下静默失配。
    if [[ ! "$raw" =~ ^([0-9]+(\.[0-9]+){1,2})([.+-][0-9A-Za-z.+-]*)?$ ]]; then
        die "--version 格式非法 (invalid version): '${VERSION}'，应形如 1.0.0 / v1.0.0 / v1.2.0-rc1"
    fi
    VERSION_SHORT="${BASH_REMATCH[1]}"
    VERSION_BUILD="$raw"
    local suffix="${BASH_REMATCH[3]}"

    # CFBundleVersion 允许任意标识串，所以构建号可以独立于版本号推进。
    # 但 -rc1/-dev 这类后缀只有 CFBundleVersion 能表达（CFBundleShortVersionString
    # 只收纯数字），所以默认构建号不覆盖带后缀的版本；显式 --build 仍然照办。
    if [[ -n "$BUILD_NUMBER" ]] && { $BUILD_EXPLICIT || [[ -z "$suffix" ]]; }; then
        if [[ ! "$BUILD_NUMBER" =~ ^[0-9A-Za-z.+-]+$ ]]; then
            die "--build 格式非法 (invalid build number): '${BUILD_NUMBER}'，应形如 2 / 17 / 2-rc1"
        fi
        VERSION_BUILD="$BUILD_NUMBER"
    fi

    if [[ -n "$SINGLE_ARCH" ]]; then
        case "$SINGLE_ARCH" in
            arm64|x86_64) DMG_BASENAME="POPOPX-Mac-Node-${SINGLE_ARCH}" ;;
            *) die "--single-arch 只支持 arm64 或 x86_64 (got: ${SINGLE_ARCH})" ;;
        esac
    fi

    # --emit-app: handover mode for Developer ID signing (used by build-release.sh).
    # Assembly, strip and the privacy audit still run; ad-hoc signing and the DMG
    # do not, because the caller has to seal the bundle with its own identity.
    if [[ -n "$EMIT_APP_DIR" ]]; then
        if [[ -n "$OUTPUT_DIR" ]]; then
            warn "--emit-app 忽略 --output（本模式只导出 bundle，不产出镜像）"
        fi
        case "$EMIT_APP_DIR" in
            /*) : ;;
            *)  EMIT_APP_DIR="$(pwd)/${EMIT_APP_DIR}" ;;
        esac
        EMIT_APP_DIR="${EMIT_APP_DIR%/}"
        if [[ -z "$EMIT_APP_DIR" || "$EMIT_APP_DIR" == "/" ]]; then
            die "--emit-app 需要一个非根目录 (refusing --emit-app /)"
        fi
        if [[ "$EMIT_APP_DIR" == "$PACKAGE_ROOT" ]]; then
            die "--emit-app 不能是仓库根目录 (refusing --emit-app ${PACKAGE_ROOT})"
        fi
        case "$EMIT_APP_DIR" in
            */"${APP_BUNDLE_NAME}")
                die "--emit-app 应指向容纳 bundle 的目录，而非 bundle 自身 (pass the parent directory, not ${APP_BUNDLE_NAME})" ;;
        esac
        if [[ -e "$EMIT_APP_DIR" && ! -d "$EMIT_APP_DIR" ]]; then
            die "--emit-app 路径不是目录 (not a directory): ${EMIT_APP_DIR}"
        fi
        EMIT_ONLY=true
        TOTAL_STEPS=7
    fi

    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="${PACKAGE_ROOT}/dist"
    fi
    case "$OUTPUT_DIR" in
        /*) : ;;
        *)  OUTPUT_DIR="$(pwd)/${OUTPUT_DIR}" ;;
    esac
    if [[ "${OUTPUT_DIR%/}" == "/" ]]; then
        die "--output 不能是文件系统根目录 (refusing --output /)"
    fi

    if [[ ! -f "${PACKAGE_ROOT}/Package.swift" ]]; then
        die "未找到 SwiftPM 清单 (Package.swift missing): ${PACKAGE_ROOT}/Package.swift"
    fi
    return 0
}

require_tools() {
    local t missing=""
    for t in swift lipo plutil codesign hdiutil shasum ditto find grep; do
        if ! command -v "$t" >/dev/null 2>&1; then missing="${missing} ${t}"; fi
    done
    if [[ -n "$missing" ]]; then
        die "缺少必需命令行工具 (missing required tools):${missing}"
    fi
    if [[ "$(uname -s)" != "Darwin" ]]; then
        die "本脚本只能在 macOS 上运行 (hdiutil/codesign require a macOS host)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 临时目录与清理 / Scratch dir + trap
# ---------------------------------------------------------------------------
make_scratch() {
    local base="${TMPDIR:-/tmp}"
    base="${base%/}"
    WORK=$(mktemp -d "${base}/popopx-node-dmg.XXXXXX") || die "mktemp -d 失败"
    chmod 700 "$WORK"
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
                if [[ -n "${TMPDIR:-}" && "$WORK" == "${TMPDIR%/}/popopx-node-dmg."* ]]; then
                    rm -rf -- "$WORK" || true
                else
                    warn "拒绝清理意外的临时目录 (refusing to remove): ${WORK}"
                fi ;;
        esac
    fi
    if [[ $rc -ne 0 ]]; then
        printf '%sFAILED:%s build_dmg.sh aborted (exit=%d)\n' "$C_RED" "$C_RESET" "$rc" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 二进制定位 / Locate the SwiftPM-built executable
# 不同工具链在多架构下可能把二进制放在 .build/release、.build/apple/Products/Release
# 或 .build/<triple>/release，所以先问 --show-bin-path，再做兜底搜索。
# ---------------------------------------------------------------------------
show_bin_path() {  # $@ = 与真实构建完全一致的附加 flags
    local p=""
    p=$(swift build -c release --show-bin-path "$@" 2>/dev/null | tail -n 1 | tr -d '\r' || true)
    case "$p" in
        /*) printf '%s\n' "$p"; return 0 ;;
        *)  return 1 ;;
    esac
}

locate_binary() {  # $1 = search root, $2 = 首选提示目录（可空）
    local root="$1" hint="${2:-}" cand f
    if [[ -n "$hint" && -x "${hint}/${EXEC_NAME}" ]]; then
        printf '%s\n' "${hint}/${EXEC_NAME}"
        return 0
    fi
    for cand in \
        "${root}/release/${EXEC_NAME}" \
        "${root}/debug/${EXEC_NAME}" \
        "${root}/apple/Products/Release/${EXEC_NAME}" \
        "${root}/apple/Products/Debug/${EXEC_NAME}"
    do
        if [[ -x "$cand" ]]; then printf '%s\n' "$cand"; return 0; fi
    done
    while IFS= read -r f; do
        if [[ -n "$f" && -x "$f" ]]; then printf '%s\n' "$f"; return 0; fi
    done < <(find "$root" -type f -name "$EXEC_NAME" -perm +111 2>/dev/null | LC_ALL=C sort)
    return 1
}

describe_archs() {  # $1 = mach-o
    local a=""
    a=$(lipo -archs "$1" 2>/dev/null | tr -d '\r' || true)
    if [[ -z "$a" ]]; then printf 'unknown\n'; else printf '%s\n' "$a"; fi
    return 0
}

file_size_human() {
    local s=""
    s=$(du -h "$1" 2>/dev/null | awk '{print $1}' | head -n 1 || true)
    if [[ -z "$s" ]]; then s="?"; fi
    printf '%s\n' "$s"
    return 0
}

# ---------------------------------------------------------------------------
# [2/8] 编译 / Build
# ---------------------------------------------------------------------------
build_step() {
    step 2 "编译 Release 二进制 (swift build -c release)"
    local final="${WORK}/${EXEC_NAME}.final"
    local bin hint archs

    if $SKIP_BUILD; then
        bin=$(locate_binary "${PACKAGE_ROOT}/.build" "${PACKAGE_ROOT}/.build/release") \
            || die "--skip-build 失败：${PACKAGE_ROOT}/.build 下找不到 ${EXEC_NAME}，请先执行一次不带 --skip-build 的构建"
        cp -f "$bin" "$final"
        chmod +x "$final"
        BUILD_PATH_TAKEN="repackaged existing .build output (--skip-build)"
        info "复用产物 (reused): $bin"
        info "架构 (lipo -archs): $(describe_archs "$final")"
        return 0
    fi

    if [[ -n "$SINGLE_ARCH" ]]; then
        info "单架构模式: swift build -c release --arch ${SINGLE_ARCH}"
        if ! ( cd "$PACKAGE_ROOT" && swift build -c release --arch "$SINGLE_ARCH" ); then
            die "单架构 ${SINGLE_ARCH} 编译失败 (single-arch build failed)"
        fi
        hint=$(show_bin_path --arch "$SINGLE_ARCH" || true)
        bin=$(locate_binary "${PACKAGE_ROOT}/.build" "${hint:-}") \
            || die "编译成功但找不到 ${EXEC_NAME} 二进制 (built, but binary not found)"
        cp -f "$bin" "$final"
        chmod +x "$final"
        BUILD_PATH_TAKEN="single-arch ${SINGLE_ARCH} (swift build -c release --arch ${SINGLE_ARCH})"
        info "来源: $bin"
        info "架构 (lipo -archs): $(describe_archs "$final")"
        return 0
    fi

    # --- Universal 路径 A：单次调用带两个 --arch -----------------------------
    info "路径 A：单次 Universal 调用"
    dim  '$ swift build -c release --arch arm64 --arch x86_64'
    archs=""
    if ( cd "$PACKAGE_ROOT" && swift build -c release --arch arm64 --arch x86_64 ); then
        hint=$(show_bin_path --arch arm64 --arch x86_64 || true)
        if bin=$(locate_binary "${PACKAGE_ROOT}/.build" "${hint:-}"); then
            archs=$(describe_archs "$bin")
            case "$archs" in
                *arm64*x86_64*|*x86_64*arm64*)
                    cp -f "$bin" "$final"
                    chmod +x "$final"
                    BUILD_PATH_TAKEN="path A: one universal invocation (swift build -c release --arch arm64 --arch x86_64)"
                    info "已采用路径 A（单次 Universal 编译）"
                    info "架构 (lipo -archs): ${archs}"
                    return 0 ;;
                *)
                    info "路径 A 产物仅含架构 [${archs}]，不足以构成 Universal，转入路径 B" ;;
            esac
        else
            info "路径 A 编译成功但未能定位产物，转入路径 B"
        fi
    else
        info "路径 A 调用失败（旧工具链 / SDK 对多个 --arch 的支持差异），转入路径 B"
    fi

    # --- Universal 路径 B：两次单架构编译 + lipo -create ---------------------
    info "路径 B：两次单架构编译 + lipo -create"
    dim  '$ swift build -c release --arch arm64  --scratch-path $WORK/scratch-arm64'
    dim  '$ swift build -c release --arch x86_64 --scratch-path $WORK/scratch-x86_64'
    dim  "\$ lipo -create bin-arm64 bin-x86_64 -output ${EXEC_NAME}.final"
    local fat="${WORK}/fat-slots.txt"
    : > "$fat"
    for arch in arm64 x86_64; do
        if ! ( cd "$PACKAGE_ROOT" && swift build -c release --arch "$arch" --scratch-path "${WORK}/scratch-${arch}" ); then
            die "架构 ${arch} 编译失败 (per-arch build failed for ${arch})"
        fi
        bin=$(locate_binary "${WORK}/scratch-${arch}" "${WORK}/scratch-${arch}/release") \
            || die "架构 ${arch} 编译成功但找不到二进制"
        cp -f "$bin" "${WORK}/bin-${arch}"
        chmod +x "${WORK}/bin-${arch}"
        printf '%s\n' "${WORK}/bin-${arch}" >> "$fat"
        info "${arch}: ${bin}  [$(describe_archs "${WORK}/bin-${arch}")]"
    done

    local slot_a slot_b
    slot_a=$(sed -n '1p' "$fat")
    slot_b=$(sed -n '2p' "$fat")
    if [[ ! -x "$slot_a" || ! -x "$slot_b" ]]; then
        die "lipo 输入不完整 (missing per-arch binaries)"
    fi
    lipo -create "$slot_a" "$slot_b" -output "$final" || die "lipo -create 失败 (fat binary creation failed)"
    chmod +x "$final"
    BUILD_PATH_TAKEN="path B: two per-arch builds + lipo -create"
    archs=$(describe_archs "$final")
    case "$archs" in
        *arm64*x86_64*|*x86_64*arm64*) : ;;
        *) die "lipo 产物架构异常 (unexpected fat arches): ${archs}" ;;
    esac
    info "已采用路径 B（两次单架构编译 + lipo）"
    info "架构 (lipo -archs): ${archs}"
    return 0
}

# ---------------------------------------------------------------------------
# [3/8] 图标 / Render the brand icon into AppIcon.icns
# 直接调用刚构建出来的二进制自身渲染 CoreImage 紫色盾牌图标。
# 这一步任何失败都只 warn 并继续，绝不阻断整个发布。
# ---------------------------------------------------------------------------
icon_step() {
    step 3 "渲染品牌图标并生成 AppIcon.icns (--render-icon / iconutil)"
    local bin="${WORK}/${EXEC_NAME}.final"
    local iconset="${WORK}/AppIcon.iconset"

    if ! command -v iconutil >/dev/null 2>&1; then
        warn "iconutil 不可用，跳过图标生成（app 仍可安装运行）"
        return 0
    fi
    mkdir -p "$iconset" || { warn "无法创建 .iconset 目录，跳过图标"; return 0; }

    # 从小到大渲染：若 CLI 模式缺失会在最小尺寸上立即失败，不浪费时间。
    local sizes=(32 64 128 256 512 1024)
    local sizes_label="" px png rc
    for px in "${sizes[@]}"; do
        sizes_label="${sizes_label}${sizes_label:+/}${px}"
    done
    for px in "${sizes[@]}"; do
        png="${WORK}/icon-${px}.png"
        rc=0
        "$bin" --render-icon "$png" --size "$px" >/dev/null 2>&1 || rc=$?
        if [[ $rc -ne 0 || ! -s "$png" ]]; then
            warn "--render-icon ${px}px 失败 (exit=${rc})：${EXEC_NAME} 可能未实现该 CLI 模式。继续打包，产物无图标。"
            return 0
        fi
    done

    # 铺成 iconutil 认得的 .iconset 命名规范
    cp -f "${WORK}/icon-32.png"   "${iconset}/icon_32x32.png"
    cp -f "${WORK}/icon-64.png"   "${iconset}/icon_32x32@2x.png"
    cp -f "${WORK}/icon-128.png"  "${iconset}/icon_128x128.png"
    cp -f "${WORK}/icon-256.png"  "${iconset}/icon_256x256.png"
    cp -f "${WORK}/icon-256.png"  "${iconset}/icon_128x128@2x.png"
    cp -f "${WORK}/icon-512.png"  "${iconset}/icon_512x512.png"
    cp -f "${WORK}/icon-1024.png" "${iconset}/icon_512x512@2x.png"

    if iconutil -c icns "$iconset" -o "${WORK}/AppIcon.icns" >/dev/null 2>&1 && [[ -s "${WORK}/AppIcon.icns" ]]; then
        ICON_READY=true
        info "AppIcon.icns 生成完成 ($(file_size_human "${WORK}/AppIcon.icns"))，来源尺寸: ${sizes_label} px"
    else
        ICON_READY=false
        warn "iconutil 转换失败，继续无图标发布 (release proceeds without an app icon)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# [4/8] 组装 Bundle / Assemble the .app by hand
# ---------------------------------------------------------------------------
bundle_step() {
    step 4 "手工组装 ${APP_BUNDLE_NAME}"
    local app="${WORK}/${APP_BUNDLE_NAME}"
    local contents="${app}/Contents"
    mkdir -p "${contents}/MacOS" "${contents}/Resources" || die "创建 Bundle 目录失败"

    local icon_plist_key=""
    if $ICON_READY; then
        cp -f "${WORK}/AppIcon.icns" "${contents}/Resources/AppIcon.icns"
        chmod 644 "${contents}/Resources/AppIcon.icns"
        icon_plist_key="	<key>CFBundleIconFile</key>
	<string>AppIcon</string>"
    else
        warn "Bundle 内不含 AppIcon.icns"
    fi

    cp -f "${WORK}/${EXEC_NAME}.final" "${contents}/MacOS/${EXEC_NAME}"
    chmod 755 "${contents}/MacOS/${EXEC_NAME}"

    # PkgInfo：'APPL????' —— 经典四字符类型 + 四字符 creator 占位
    printf 'APPL????' > "${contents}/PkgInfo"

    cat > "${contents}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${EXEC_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION_SHORT}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION_BUILD}</string>
${icon_plist_key}
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_MACOS}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 POPOPX Chat. 源码以 GNU AGPL-3.0-only 开源发布，与 popopxmq、popopx-chat 共用同一份许可原文；官方托管中继网络、官方发行通道与 POPOPX 品牌条款见 LICENSE-COMMERCIAL.md。 / Source released under GNU AGPL-3.0-only on the same licence text as popopxmq and popopx-chat; the hosted relay network, the official release channel and the POPOPX brand are covered by LICENSE-COMMERCIAL.md.</string>
</dict>
</plist>
PLIST

    plutil -lint "${contents}/Info.plist" >/dev/null || die "Info.plist 未通过 plutil -lint"
    info "plutil -lint: $(plutil -lint "${contents}/Info.plist" | sed "s#.*: ##")"
    dim "CFBundleIdentifier         = ${BUNDLE_ID}"
    dim "CFBundleExecutable         = ${EXEC_NAME}"
    dim "CFBundleShortVersionString = ${VERSION_SHORT}"
    dim "CFBundleVersion            = ${VERSION_BUILD}"
    dim "LSUIElement                = true（菜单栏 Agent，不占 Dock）"
    dim "最低系统 LSMinimumSystemVersion = ${MIN_MACOS}"

    APP_DIR="$app"
    BINARY_IN_BUNDLE="${contents}/MacOS/${EXEC_NAME}"
    info "Bundle 结构:"
    dim "  ${APP_BUNDLE_NAME}/Contents/Info.plist"
    dim "  ${APP_BUNDLE_NAME}/Contents/PkgInfo"
    dim "  ${APP_BUNDLE_NAME}/Contents/MacOS/${EXEC_NAME}"
    if $ICON_READY; then
        dim "  ${APP_BUNDLE_NAME}/Contents/Resources/AppIcon.icns"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# [5/8] 剥离调试符号 + Ad-hoc 签名
# 剥离独立成函数：--emit-app 模式只剥离、不签名，签名交给上层发布脚本。
# ---------------------------------------------------------------------------
strip_binary() {
    if $SKIP_STRIP; then
        warn "--no-strip：保留 DWARF 调试符号，产物极可能包含编译机绝对路径，下一步审计会硬失败"
    elif command -v strip >/dev/null 2>&1; then
        # -S 删除调试符号表（DWARF 中的源文件绝对路径就住在这里），-x 删除非全局符号。
        # 必须在 codesign 之前完成：签名之后再改二进制会让签名立即失效。
        strip -S -x "$BINARY_IN_BUNDLE" || warn "strip 执行失败，继续（第 6 步审计会给出最终结论）"
        info "strip -S -x 完成"
    else
        warn "未找到 strip 工具，跳过剥离"
    fi
    return 0
}

sign_step() {
    step 5 "剥离调试符号并执行 Ad-hoc 代码签名"
    strip_binary

    if $EMIT_ONLY; then
        SIGN_STATE="unsigned (--emit-app: sealing deferred to the caller)"
        info "跳过 Ad-hoc 签名：上层脚本会用 Developer ID 封装这个 bundle"
        return 0
    fi

    if $NO_SIGN; then
        warn "--no-sign：跳过 codesign。未签名 app 在其他机器上会被 Gatekeeper 拦下。"
        SIGN_STATE="skipped (--no-sign)"
        return 0
    fi

    # 刻意不传 --options runtime：Ad-hoc 签名 + hardened runtime 组合会导致
    # 部分 macOS 版本启动即被系统杀掉。--deep 在此只是兜底（Bundle 内无嵌套代码）。
    codesign --force --deep --sign - --timestamp=none "$APP_DIR" \
        || die "codesign Ad-hoc 签名失败 (ad-hoc signing failed)"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null 2>&1 \
        || die "codesign --verify --deep --strict 未通过 (signature verification failed)"
    SIGN_STATE="ad-hoc (--sign - --timestamp=none, no hardened runtime)"
    dim "codesign -dv: $(codesign -dvv "$APP_DIR" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory)' | tr '\n' ' ' || true)"
    info "签名校验通过 (codesign --verify --deep --strict)"
    return 0
}

# ---------------------------------------------------------------------------
# 安全红线审计 / Privacy gate
# grep -c 在 0 命中时返回退出码 1，配合 set -e 会直接杀死脚本，
# 因此计数统一走 `grep -a -o … | wc -l`，探测统一走 `grep -a -q`。
# ---------------------------------------------------------------------------
count_occurrences() {  # $1 = 固定字符串, $2 = 文件
    local n=""
    n=$(LC_ALL=C grep -a -o -F -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' ' || true)
    if [[ -z "$n" ]]; then n=0; fi
    printf '%s\n' "$n"
    return 0
}

# audit_artifact <标签> <文件> <home 命中是否硬失败: true|false>
audit_artifact() {
    local label="$1" target="$2" fatal="$3"
    local home_count users_count

    if [[ -z "${HOME:-}" || "${HOME:0:1}" != "/" ]]; then
        warn "\$HOME 不是绝对路径，跳过 ${label} 的绝对路径审计"
        return 0
    fi

    home_count=$(count_occurrences "$HOME" "$target")
    users_count=$(count_occurrences "/Users/" "$target")
    info "${label}: '${HOME}' 命中 ${home_count} 次 · '/Users/' 命中 ${users_count} 次"

    if [[ "$home_count" -gt 0 ]]; then
        if [[ "$fatal" == "true" ]]; then
            {
                printf 'FATAL: absolute developer path leaked into artifact\n'
                printf '       文件 (file)  : %s\n' "$target"
                printf '       泄漏前缀     : %s（%s 次）\n' "$HOME" "$home_count"
                printf '       疑似来源     : Swift #filePath / #file / #function 调试字符串，或未剥离的 DWARF 调试符号。\n'
                printf '       处置建议     : 用 -c release 构建并让脚本执行默认的 strip -S -x；确认引擎侧没有把 #filePath 打进用户可见字符串。\n'
            } >&2
            return 1
        fi
        warn "${label} 出现 ${home_count} 次开发机路径（按当前配置不硬失败）"
    fi
    return 0
}

binary_audit_step() {
    step 6 "安全红线审计 I：Mach-O 二进制绝对路径扫描"
    if [[ ! -f "$BINARY_IN_BUNDLE" ]]; then
        die "找不到待审计的二进制: ${BINARY_IN_BUNDLE}"
    fi
    if ! audit_artifact "二进制 ${EXEC_NAME}" "$BINARY_IN_BUNDLE" true; then
        die "absolute developer path leaked into artifact — 发布已阻断 (release blocked by privacy gate)"
    fi
    info "未发现 \$HOME 前缀，红线通过 (no developer home path in the Mach-O)"
    return 0
}

# ---------------------------------------------------------------------------
# [7/8] 打包 DMG
# ---------------------------------------------------------------------------
dmg_step() {
    step 7 "打包拖拽安装镜像 ${DMG_BASENAME}.dmg"
    local staging="${WORK}/dmg-root"
    mkdir -p "$staging" || die "创建 staging 目录失败"
    # ditto 比 cp -R 更忠实地保留 bundle 的扩展属性、权限与符号链接语义
    ditto "$APP_DIR" "${staging}/${APP_BUNDLE_NAME}" || die "拷贝 app 到 staging 失败"
    ln -sfh /Applications "${staging}/Applications" || die "Applications 符号链接创建失败"
    if [[ ! -L "${staging}/Applications" ]]; then
        die "Applications 符号链接校验失败"
    fi

    mkdir -p "$OUTPUT_DIR" || die "无法创建输出目录: $OUTPUT_DIR"

    dim "\$ hdiutil create -volname \"${VOL_NAME}\" -srcfolder <staging> -ov -format UDZO -o ${OUTPUT_DIR}/${DMG_BASENAME}"
    # 只传基础名：本机 hdiutil 的 -o 会自动追加 .dmg。绝不与 -type 同时传。
    hdiutil create \
        -volname "$VOL_NAME" \
        -srcfolder "$staging" \
        -ov \
        -format UDZO \
        -quiet \
        -o "${OUTPUT_DIR}/${DMG_BASENAME}" \
        || die "hdiutil create 失败 (DMG creation failed)"

    DMG_PATH="${OUTPUT_DIR}/${DMG_BASENAME}.dmg"
    if [[ ! -f "$DMG_PATH" ]]; then
        die "hdiutil 未产出预期路径 (expected exactly ${DMG_PATH}) —— 本机 -o 扩展名行为与实测不符，请检查"
    fi
    if [[ "$(basename -- "$DMG_PATH")" != "${DMG_BASENAME}.dmg" ]]; then
        die "镜像文件名断言失败: $(basename -- "$DMG_PATH") != ${DMG_BASENAME}.dmg"
    fi
    # 若 -o 还额外留下了不带扩展名的同名文件，视为异常产物清掉
    if [[ -e "${OUTPUT_DIR}/${DMG_BASENAME}" && ! -d "${OUTPUT_DIR}/${DMG_BASENAME}" ]]; then
        warn "清理 hdiutil 残留文件 ${OUTPUT_DIR}/${DMG_BASENAME}"
        rm -f -- "${OUTPUT_DIR}/${DMG_BASENAME}"
    fi

    info "镜像: ${DMG_PATH} ($(file_size_human "$DMG_PATH"))"
    info "卷标: ${VOL_NAME} · 拖拽目标: Applications -> /Applications"
    return 0
}

# ---------------------------------------------------------------------------
# [8/8] sha256 + DMG 审计 + 验收报告
# ---------------------------------------------------------------------------
checksum_and_report_step() {
    step 8 "生成 sha256 校验文件并执行安全红线审计 II（DMG）"
    local dmg_name sha_file
    dmg_name=$(basename -- "$DMG_PATH")
    sha_file="${DMG_PATH}.sha256"

    # 挂载后再扫描真实内容：UDZO 是压缩镜像，直接 grep 裸文件几乎没有意义。
    local audit_target="$DMG_PATH" audit_label="DMG 原始字节（压缩，命中数可能偏低）"
    MOUNT_POINT="${WORK}/mnt"
    mkdir -p "$MOUNT_POINT"
    if hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null 2>&1; then
        local inner="${MOUNT_POINT}/${APP_BUNDLE_NAME}/Contents/MacOS/${EXEC_NAME}"
        if [[ -f "$inner" ]]; then
            audit_target="$inner"
            audit_label="DMG 内部二进制（已挂载）"
        else
            warn "挂载卷内未找到 ${EXEC_NAME}，退回扫描 DMG 原始字节"
        fi
    else
        warn "hdiutil attach 失败，退回扫描 DMG 原始字节"
        MOUNT_POINT=""
    fi

    if ! audit_artifact "$audit_label" "$audit_target" true; then
        rm -f -- "$DMG_PATH"
        die "DMG 内出现开发机绝对路径，已删除不可信镜像 (untrusted DMG removed)"
    fi
    if [[ -n "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
        MOUNT_POINT=""
    fi

    # 校验文件格式：'<64hex>␣␣<相对文件名>'，绝不写入绝对路径。
    ( cd "$OUTPUT_DIR" && shasum -a 256 "$dmg_name" > "${dmg_name}.sha256" ) \
        || die "shasum -a 256 失败"
    if [[ ! -s "$sha_file" ]]; then
        die "未生成校验文件: $sha_file"
    fi
    local fmt_ok
    fmt_ok=$(LC_ALL=C grep -c -E "^[0-9a-f]{64}  ${dmg_name//./\\.}\$" "$sha_file" || true)
    if [[ "${fmt_ok:-0}" != "1" ]]; then
        die "校验文件格式异常，应为 '<64hex>  ${dmg_name}'（两个空格 + 纯相对文件名）"
    fi
    if LC_ALL=C grep -a -q -F -- "/" "$sha_file"; then
        die "校验文件不应包含任何路径分隔符"
    fi
    ( cd "$OUTPUT_DIR" && shasum -a 256 -c "${dmg_name}.sha256" >/dev/null ) \
        || die "shasum -a 256 -c 自校验未通过 (checksum self-verification failed)"
    info "shasum -a 256 -c 自校验通过 (CI 的 verify-checksum job 依赖它)"
    dim "$(cat "$sha_file")"

    if ! $NO_SIGN; then
        local spctl_state="rejected（Ad-hoc 签名属预期：对外分发前请用 Developer ID 重签并公证）"
        if spctl -a -t exec -vv "$APP_DIR" >/dev/null 2>&1; then
            spctl_state="accepted"
        fi
        info "Gatekeeper spctl 评估: ${spctl_state}"
    fi

    printf '\n'
    printf '%s验收报告 / Acceptance report%s\n' "$C_BOLD" "$C_RESET"
    printf '  %-22s %s\n' "Version"             "${VERSION_SHORT} (build ${VERSION_BUILD})"
    printf '  %-22s %s\n' "Build path"          "${BUILD_PATH_TAKEN}"
    printf '  %-22s %s\n' "Architectures"       "$(describe_archs "${WORK}/${EXEC_NAME}.final")"
    printf '  %-22s %s\n' "Bundle ID"           "${BUNDLE_ID}"
    if $ICON_READY; then
        printf '  %-22s %s\n' "App icon" "AppIcon.icns (32/64/128/256/512/1024 px)"
    else
        printf '  %-22s %s\n' "App icon" "none (skipped, install unaffected)"
    fi
    printf '  %-22s %s\n' "Signature"           "${SIGN_STATE}"
    printf '  %-22s %s\n' "DMG"                 "${DMG_PATH}"
    printf '  %-22s %s\n' "Checksum"            "${sha_file}"
    printf '  %-22s %s\n' "Privacy gate"        "PASS - no developer home path inside artifacts"
    printf '\n  %s安装 / Install%s  打开 DMG，把 "%s" 拖进 Applications，启动后驻留菜单栏，\n' "${C_BOLD}" "${C_RESET}" "${APP_NAME}"
    printf '  浏览器会自动打开本地控制台 %s（仅回环 + 动态 Token，外网不可见）。\n\n' "${CONSOLE_URL}"
    return 0
}

# ---------------------------------------------------------------------------
# [7/7] --emit-app: 导出未签名 bundle / export the unsigned bundle
# ---------------------------------------------------------------------------
emit_app_step() {
    step 7 "导出未签名 Bundle 到 ${EMIT_APP_DIR}"
    mkdir -p "$EMIT_APP_DIR" || die "无法创建 --emit-app 目录: $EMIT_APP_DIR"
    local target="${EMIT_APP_DIR}/${APP_BUNDLE_NAME}"
    # 有界删除：只允许替换本脚本自己命名的 <APP_BUNDLE_NAME> 目录，其余一律拒绝。
    if [[ -e "$target" ]]; then
        case "$target" in
            *.app) if [[ ! -d "$target" ]]; then
                       die "拒绝覆盖非 bundle 路径 (not a directory): ${target}"
                   fi ;;
            *)     die "拒绝覆盖意外路径 (refusing to overwrite): ${target}" ;;
        esac
        rm -rf -- "$target" || die "无法替换已有 bundle: ${target}"
    fi
    # ditto 保留权限与符号链接语义；bundle 在此仍是未签名状态。
    ditto "$APP_DIR" "$target" || die "拷贝 bundle 失败: ${target}"
    if [[ ! -x "${target}/Contents/MacOS/${EXEC_NAME}" ]]; then
        die "导出的 bundle 缺少可执行文件: ${target}/Contents/MacOS/${EXEC_NAME}"
    fi
    if [[ ! -f "${target}/Contents/Info.plist" ]] \
        || ! plutil -lint "${target}/Contents/Info.plist" >/dev/null; then
        die "导出的 bundle Info.plist 缺失或未通过 plutil -lint: ${target}"
    fi
    info "bundle: ${target}"
    dim "CFBundleShortVersionString = $(plutil -extract CFBundleShortVersionString raw "${target}/Contents/Info.plist" 2>/dev/null || echo '?')"
    dim "CFBundleVersion            = $(plutil -extract CFBundleVersion raw "${target}/Contents/Info.plist" 2>/dev/null || echo '?')"
    dim "lipo -archs                = $(describe_archs "${target}/Contents/MacOS/${EXEC_NAME}")"
    dim "signature                  = none (verify with: codesign -dvv '${target}')"
    return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    normalize_and_validate
    make_scratch

    printf '%s=============================================================%s\n' "$C_BOLD" "$C_RESET"
    printf '%s  POPOPX Mac Node — Universal DMG packer%s\n' "$C_BOLD" "$C_RESET"
    printf '%s=============================================================%s\n' "$C_BOLD" "$C_RESET"

    step 1 "环境自检 (preflight)"
    require_tools
    local target_label="universal arm64 + x86_64"
    if [[ -n "$SINGLE_ARCH" ]]; then target_label="single-arch ${SINGLE_ARCH}"; fi
    if $SKIP_BUILD; then target_label="reuse existing .build output (--skip-build)"; fi
    info "package root : ${PACKAGE_ROOT}"
    info "output dir   : ${OUTPUT_DIR}"
    info "version      : ${VERSION_BUILD}  (CFBundleShortVersionString ${VERSION_SHORT})"
    info "target       : ${target_label}"
    info "scratch      : ${WORK}"
    if $EMIT_ONLY; then
        info "mode         : emit UNSIGNED bundle for Developer ID signing -> ${EMIT_APP_DIR}"
        dim  "no ad-hoc signature and no DMG in this mode; the caller notarizes and packages"
    fi
    dim  "swift: $(swift --version 2>&1 | head -n 1 || echo 'unavailable')"
    dim  "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown) ($(uname -m))"

    build_step
    icon_step
    bundle_step
    sign_step
    binary_audit_step
    if $EMIT_ONLY; then
        # 未签名 bundle 交给上层：dmg_step / checksum_and_report_step 都不执行，
        # 因为镜像必须从 Developer ID 签名并装订票据后的 bundle 重新制作。
        emit_app_step
        return 0
    fi
    dmg_step
    checksum_and_report_step
}

main "$@"
