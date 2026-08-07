#!/bin/bash
# dev.sh — singbird 常用命令封装
#
# 命令:
#   help               显示本帮助
#   backend            构建 sing-box-netbird exe (release) 并复制为 sing-box.exe
#   windows            完整 Windows 发布构建 (backend + flutter, 自动注入 hash/时间)
#   installer          用当前 Release 产物打 EXE 安装包 (Inno Setup; 需先跑 windows)
#   android            完整 Android 发布 APK (libbox.aar + flutter build apk, arm64)
#   libbox             仅重建 libbox.aar (rebuild-libbox.sh)
#   run [args...]      flutter run -d windows (透传额外参数)
#   analyze [args...]  flutter analyze
#   test [args...]     flutter test
#   clean              flutter clean + 删除 build/
#   kill               杀掉运行中的 singbird.exe / sing-box.exe (Windows 构建前置)
#   version            显示将要注入的版本信息
#
# 选项:
#   windows --no-backend   跳过后端重建, 只构建 flutter
#   android --no-libbox    跳过 libbox.aar 重建, 只构建 flutter
#   android --no-backend   同上 (等价别名)
# 其余命令不接受额外参数; 未知选项在解析阶段立即报错, 不会触发任何编译。
#
# 环境变量:
#   FLUTTER      flutter 命令 (默认: puro flutter, 无 puro 时用 flutter)
#   SINGBOX_DIR  sing-box 仓库路径 (默认: 项目上一层目录, 不写死 ~/works)
#   NETBIRD_DIR  netbird 仓库路径 (同上; 仅 libbox 构建需要)

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# 后端仓库路径延迟解析: 仅在需要编译后端时由 require_repo 查找/校验
SINGBOX_DIR="${SINGBOX_DIR:-}"
NETBIRD_DIR="${NETBIRD_DIR:-}"

if command -v puro >/dev/null 2>&1; then
    FLUTTER="${FLUTTER:-puro flutter}"
else
    FLUTTER="${FLUTTER:-flutter}"
fi

# ── helpers ─────────────────────────────────────────────────────────

# 解析后端仓库路径: 环境变量优先; 否则只在项目上一层目录查找
# (仓库约定平级放在同一父目录下, 如 ~/works/{singbird,sing-box,netbird})。
# 上一层找不到时报错: 明确提示用户把目录放到上一层或拉取到上一层。
require_repo() {
    local var="$1" dir="$2"
    if [ -n "${!var:-}" ]; then
        if [ ! -d "${!var}" ]; then
            echo "ERROR: ${var}=${!var} 目录不存在" >&2
            exit 1
        fi
        return 0
    fi
    local parent
    parent="$(dirname "$PROJ_DIR")"
    if [ -d "$parent/$dir" ]; then
        eval "$var=\"$parent/$dir\""
        echo "  找到 $dir: $parent/$dir"
        return 0
    fi
    echo "ERROR: 在上一层 ($parent) 未找到 $dir 目录" >&2
    echo "  请将 $dir 仓库放到该目录, 或手动拉取到上一层:" >&2
    if [ "$dir" = "sing-box" ]; then
        echo "    git clone -b sing-netbird https://github.com/SagerNet/sing-box.git \"$parent/sing-box\"" >&2
    else
        echo "    git clone https://github.com/netbirdio/netbird.git \"$parent/netbird\"" >&2
        echo "    # 然后 checkout 所需上游 tag (如 v0.76.0)" >&2
    fi
    echo "  或设置环境变量 ${var}=<绝对路径> 指定位置" >&2
    exit 1
}

# 前端构建注入: FLUTTER_BUILD_HASH / FLUTTER_BUILD_TIME
dart_defines() {
    local hash time
    hash="$(cd "$PROJ_DIR" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    time="$(date +%Y-%m-%dT%H:%M:%S)"
    echo "--dart-define=FLUTTER_BUILD_HASH=$hash --dart-define=FLUTTER_BUILD_TIME=$time"
}

# 杀掉占用 Release 目录的进程 (否则 CMake POST_BUILD 复制 sing-box.exe 失败)
kill_app() {
    echo "=== kill running app ==="
    taskkill //F //IM singbird.exe //IM sing-box.exe 2>/dev/null && \
        echo "  killed ✓" || echo "  (no running process)"
}

# 参数白名单校验: 在任何重活 (编译后端/aar 等) 之前执行, 未知选项立即报错。
# 用法: check_args <子命令名> <允许选项, | 分隔; 空=不接受任何选项> "$@"
check_args() {
    local cmd="$1" allowed="$2"; shift 2
    for arg in "$@"; do
        case "$arg" in
            --*)
                if [[ "$allowed" == *"|$arg|"* ]]; then continue; fi
                echo "ERROR: $cmd 不支持的选项: $arg" >&2
                echo "  可用选项: ${allowed//|/ }" >&2
                exit 1 ;;
            *)
                echo "ERROR: $cmd 不接受位置参数: $arg" >&2
                exit 1 ;;
        esac
    done
}

# 构建后端 exe 并复制为项目根的 sing-box.exe
build_backend() {
    echo "=== backend build (sing-box + netbird, release) ==="
    require_repo SINGBOX_DIR sing-box
    (cd "$SINGBOX_DIR" && ./dev.sh netbird release)
    local exe
    exe="$(ls -t "$SINGBOX_DIR"/sing-box-netbird-*.exe 2>/dev/null | head -1 || true)"
    if [ -z "$exe" ] || [ ! -f "$exe" ]; then
        echo "ERROR: backend build produced no exe in $SINGBOX_DIR" >&2
        exit 1
    fi
    cp "$exe" "$PROJ_DIR/sing-box.exe"
    echo "  copied: $(basename "$exe") → sing-box.exe"
}

# ── commands ────────────────────────────────────────────────────────

cmd_backend() { check_args backend "" "$@"; build_backend; }

cmd_windows() {
    check_args windows "|--no-backend|" "$@"
    if [ "${1:-}" = "--no-backend" ]; then shift; else build_backend; fi
    kill_app
    cd "$PROJ_DIR"
    echo "=== flutter build windows (release) ==="
    # shellcheck disable=SC2046
    $FLUTTER build windows --release $(dart_defines) "$@"
    echo "=== DONE: build/windows/x64/runner/Release/singbird.exe ==="
}

# 打 EXE 安装包: 依赖 build/windows/x64/runner/Release (dev.sh windows 的产物)
cmd_installer() {
    check_args installer "" "$@"
    local release="$PROJ_DIR/build/windows/x64/runner/Release"
    if [ ! -f "$release/singbird.exe" ]; then
        echo "ERROR: $release 不存在 — 先执行 ./scripts/dev.sh windows" >&2
        exit 1
    fi
    local iscc ver
    for cand in "$LOCALAPPDATA/Programs/Inno Setup 6/ISCC.exe" \
        "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" \
        "/c/Program Files/Inno Setup 6/ISCC.exe"; do
        if [ -f "$cand" ]; then iscc="$cand"; break; fi
    done
    if [ -z "$iscc" ]; then
        echo "ERROR: 未找到 ISCC.exe — 安装: winget install JRSoftware.InnoSetup" >&2
        exit 1
    fi
    ver="$(grep '^version:' "$PROJ_DIR/pubspec.yaml" | head -1 | cut -d' ' -f2 | cut -d'+' -f1)"
    mkdir -p "$PROJ_DIR/build/installer"
    echo "=== ISCC build (v$ver) ==="
    # MSYS 会把 /DAppVer=... 当 POSIX 路径转换, ISCC 报 "more than one script
    # filename" — 显式豁免转换 (脚本路径已 cygpath -w, 不受影响)。
    MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 \
        "$iscc" "$(cygpath -w "$PROJ_DIR/installer/singbird.iss")" "/DAppVer=$ver" "/DOutName=singbird-setup-$ver-x64"
    echo "=== 安装包 ==="
    ls -lh "$PROJ_DIR"/build/installer/*.exe
}

cmd_libbox() {
    check_args libbox "" "$@"
    echo "=== 解析后端仓库 (libbox 需要 sing-box + netbird) ==="
    require_repo SINGBOX_DIR sing-box
    require_repo NETBIRD_DIR netbird
    export SINGBOX_DIR NETBIRD_DIR
    echo "=== rebuild libbox.aar (arm64, with_netbird) ==="
    bash "$PROJ_DIR/scripts/rebuild-libbox.sh"
}

cmd_android() {
    # --no-libbox 与 --no-backend 等价 (语义都是: 跳过 libbox.aar 重建)
    check_args android "|--no-libbox|--no-backend|" "$@"
    if [ "${1:-}" = "--no-libbox" ] || [ "${1:-}" = "--no-backend" ]; then
        shift
    else
        cmd_libbox
    fi
    cd "$PROJ_DIR"
    echo "=== flutter build apk (release, arm64) ==="
    # shellcheck disable=SC2046
    $FLUTTER build apk --release --split-per-abi --target-platform android-arm64 $(dart_defines) "$@"
    echo "=== APK ==="
    ls -lh "$PROJ_DIR"/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
}

cmd_run() {
    cd "$PROJ_DIR"
    $FLUTTER run -d windows "$@"
}

cmd_analyze() {
    cd "$PROJ_DIR"
    $FLUTTER analyze "$@"
}

cmd_test() {
    cd "$PROJ_DIR"
    $FLUTTER test "$@"
}

cmd_clean() {
    check_args clean "" "$@"
    cd "$PROJ_DIR"
    $FLUTTER clean
    rm -rf build/
    echo "cleaned ✓"
}

cmd_kill() { check_args kill "" "$@"; kill_app; }

cmd_version() {
    check_args version "" "$@"
    echo "project      : $PROJ_DIR"
    echo "pubspec ver  : $(grep '^version:' "$PROJ_DIR/pubspec.yaml" | head -1 | cut -d' ' -f2)"
    echo "git hash     : $(cd "$PROJ_DIR" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "build time   : $(date +%Y-%m-%dT%H:%M:%S)"
    echo "flutter cmd  : $FLUTTER"
    if [ -n "$SINGBOX_DIR" ] && [ -d "$SINGBOX_DIR" ]; then
        echo "backend exe  : $(ls -t "$SINGBOX_DIR"/sing-box-netbird-*.exe 2>/dev/null | head -1 || echo none)"
    else
        echo "backend exe  : (未解析 — backend/windows/android 命令会向上查找)"
    fi
    echo "sing-box.exe : $([ -f "$PROJ_DIR/sing-box.exe" ] && echo present || echo missing)"
}

usage() {
    # 打印 # 开头的头部注释 (跳过 shebang), 遇到第一个非注释行停止
    # 注意: sub() 会修改 $0, 不能再用 !/^#/ 做第二个 pattern (sub 后误判), 用 if 分支
    awk 'NR > 1 { if (/^#/) { line=$0; sub(/^# ?/, "", line); print line } else exit }' "$0"
}

# ── dispatch ────────────────────────────────────────────────────────

case "${1:-}" in
    ""|help|-h|--help) usage ;;
    backend)  shift; cmd_backend "$@" ;;
    windows)  shift; cmd_windows "$@" ;;
    installer) shift; cmd_installer "$@" ;;
    android)  shift; cmd_android "$@" ;;
    libbox)   shift; cmd_libbox "$@" ;;
    run)      shift; cmd_run "$@" ;;
    analyze)  shift; cmd_analyze "$@" ;;
    test)     shift; cmd_test "$@" ;;
    clean)    shift; cmd_clean "$@" ;;
    kill)     shift; cmd_kill "$@" ;;
    version)  shift; cmd_version "$@" ;;
    *) echo "unknown command: $1" >&2; echo; usage; exit 1 ;;
esac
