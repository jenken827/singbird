#!/bin/bash
# Quick rebuild of libbox.aar for Android arm64 (sing-box + netbird)
# Prerequisites: ANDROID_HOME, ANDROID_NDK_HOME, gomobile (SagerNet fork)
#
# NOTE: netbird integration requires go.work (sing-box go.mod has no
# netbird require — it's referenced via ../netbird in go.work).
# Do NOT set GOWORK=off for netbird-enabled builds.

set -e

export ANDROID_HOME="${ANDROID_HOME:-$HOME/AppData/Local/Android/Sdk}"
NDK_VERSION="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/29.0.14033849}"
# 仓库位置不写死: 环境变量优先; 否则从项目上一层目录查找
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # scripts/ 上一级 = 项目根
SINGBOX_DIR="${SINGBOX_DIR:-$PROJ_DIR/../sing-box}"
FLUTTER_DIR="${FLUTTER_DIR:-$PROJ_DIR}"
NETBIRD_DIR="${NETBIRD_DIR:-$PROJ_DIR/../netbird}"

export ANDROID_NDK_HOME="$NDK_VERSION"
unset http_proxy https_proxy

# 后端仓库必须存在 (找不到时给出提示)
for _v in SINGBOX_DIR NETBIRD_DIR; do
    if [ ! -d "${!_v}" ]; then
        echo "ERROR: $_v=${!_v} 目录不存在" >&2
        echo "  请把对应仓库放到项目上一层 ($PROJ_DIR/..) 或设置环境变量 $_v" >&2
        exit 1
    fi
done

echo "ANDROID_HOME=$ANDROID_HOME"
echo "ANDROID_NDK_HOME=$ANDROID_NDK_HOME"

echo "=== Cleaning ==="
cd "$SINGBOX_DIR"
rm -rf build/ libbox.aar

echo "=== Building libbox.aar (arm64, with_netbird) ==="
# Inject upstream versions via ldflags so `About` shows REAL versions:
#
# sing-box: we modify the source, so the version must be our declared
#   UPSTREAM baseline (the tag we forked/merged from), NOT git describe
#   (which would be misleading). Kept in repo root as UPSTREAM_TAG —
#   bump it whenever we merge a new upstream tag.
UPSTREAM_TAG_FILE="$SINGBOX_DIR/UPSTREAM_TAG"
SINGBOX_VERSION="unknown"
if [ -f "$UPSTREAM_TAG_FILE" ]; then
    SINGBOX_VERSION=$(tr -d ' 
\n' < "$UPSTREAM_TAG_FILE")
fi
#
# netbird: report the version we ACTUALLY compiled. git describe --exact-match
# only succeeds when HEAD is exactly on a tag; otherwise we report
# "development" rather than lying about which tag's code we used.
NETBIRD_VERSION=$(cd "$NETBIRD_DIR" && git describe --tags --exact-match 2>/dev/null || echo "development")
NETBIRD_COMMIT=$(cd "$NETBIRD_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "sing-box version: $SINGBOX_VERSION (from UPSTREAM_TAG)"
echo "netbird version: $NETBIRD_VERSION (exact-match, commit $NETBIRD_COMMIT)"

# gomobile 对 cmd.exe 隐藏环境变量敏感: 名字以 "=" 开头的变量
# (如 "=C:=C:\..."、UNC 路径标记 "=::=::\") 会混进 os.Environ(),
# 其 environ() 二次校验直接 panic: malformed env var "=::=::\"
# (bootstrap 经 cmd.exe 启动的终端最易携带; bash 无法 unset 这类
# 非法标识符变量, env -u 也会拒绝, 只能重建环境)。
# 解法: env -i 用过滤后的变量列表重建环境再执行 (剔除 ^= 开头的行)。
run_gomobile() {
    local -a envargs=() line
    while IFS= read -r line; do
        envargs+=("$line")
    done < <(env | grep -v '^=')
    env -i "${envargs[@]}" "$@"
}

if env | grep -q '^='; then
    echo "  (检测到 cmd.exe 隐藏环境变量, 已过滤后运行 gomobile)"
fi

run_gomobile ~/go/bin/gomobile bind \
  -target android/arm64 -androidapi 23 \
  -o libbox.aar -javapkg io.nekohasekai -libname box \
  -trimpath \
  -tags "with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_usbip,with_openvpn,with_openconnect,with_netbird,badlinkname,tfogo_checklinkname0" \
  -ldflags "-s -w -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=$SINGBOX_VERSION -X github.com/netbirdio/netbird/version.version=$NETBIRD_VERSION -X github.com/sagernet/sing-box/experimental/libbox.netbirdBuildCommit=$NETBIRD_COMMIT" \
  ./experimental/libbox

echo "=== Copying to Flutter project ==="
mkdir -p "$FLUTTER_DIR/android/app/libs"
cp libbox.aar "$FLUTTER_DIR/android/app/libs/"
ls -lh libbox.aar "$FLUTTER_DIR/android/app/libs/libbox.aar"

echo "=== Done ==="
