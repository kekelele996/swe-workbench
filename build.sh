#!/bin/bash
# 构建 SWE 工作台.app
#
#   ./build.sh              生成 dist/SWE 工作台.app、.zip 和 .dmg
#   ./build.sh --no-dmg     只生成 .app 和 .zip
#   SWE_FLOW_BIN=... ./build.sh   使用预编译的 swe-flow
#   SWE_TOOLS_DIR=... ./build.sh  覆盖运行期 tools 目录
#
# 默认从仓库内的 backend/ 构建 swe-flow，并使用仓库内的 tools/；
# 只有缺少这些目录时才回退到 ~/.codex/skills/swe-task。
# 版本号只读根目录 VERSION。

set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="${SWE_SKILL_DIR:-$HOME/.codex/skills/swe-task}"

APP_NAME="SWE 工作台"
EXEC_NAME="SWEWorkbench"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-3}"
BUILD_DIR="build"
DIST_DIR="dist"
APP="$DIST_DIR/$APP_NAME.app"
MAKE_DMG=1

if [[ -z "$VERSION" ]]; then
  echo "VERSION 文件为空" >&2
  exit 1
fi

# Prefer the checked-in backend/tools so a fresh clone builds without the
# ~/.codex skill directory. SWE_FLOW_BIN can still point at a prebuilt binary.
# Only reuse .build when SWE_FLOW_BIN is not explicitly provided. Reusing the
# previous build by default silently ships stale backend code after source edits.
BIN_SRC="${SWE_FLOW_BIN:-}"
if [[ -z "$BIN_SRC" && -f "$ROOT/backend/go.mod" ]]; then
  command -v go >/dev/null 2>&1 || { echo "需要 Go 1.22+ 来构建 backend" >&2; exit 1; }
  mkdir -p "$ROOT/.build"
  BIN_SRC="$ROOT/.build/swe-flow"
  echo "==> 构建 swe-flow（backend）"
  (cd "$ROOT/backend" && go build -trimpath -o "$BIN_SRC" ./cmd/swe-flow)
elif [[ -z "$BIN_SRC" ]]; then
  BIN_SRC="$SKILL_DIR/runtime/bin/swe-flow"
fi
TOOLS_SRC="${SWE_TOOLS_DIR:-$ROOT/tools}"
if [[ ! -d "$TOOLS_SRC" ]]; then
  TOOLS_SRC="$SKILL_DIR/runtime/tools"
fi

if [[ ! -x "$BIN_SRC" ]]; then
  echo "找不到 swe-flow：$BIN_SRC" >&2
  echo "请安装 Go 1.22+，或用 SWE_FLOW_BIN 指定已编译的二进制。" >&2
  exit 1
fi
if [[ ! -d "$TOOLS_SRC" ]]; then
  echo "找不到运行期工具目录：$TOOLS_SRC" >&2
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --no-dmg) MAKE_DMG=0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> 编译宿主程序"
swiftc -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework Cocoa -framework WebKit \
  Sources/*.swift \
  -o "$BUILD_DIR/$EXEC_NAME"

echo "==> 生成图标"
mkdir -p "$BUILD_DIR/AppIcon.iconset"
swift Assets/make_icon.swift "$BUILD_DIR/AppIcon.iconset" >/dev/null
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"

echo "==> 组装 $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/tools"
cp "$BUILD_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
cp Assets/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# swe-flow：放到 Resources/bin，服务按 <exe>/../tools 找工具，正好是 Resources/tools。
cp "$BIN_SRC" "$APP/Contents/Resources/bin/swe-flow"
chmod 755 "$APP/Contents/Resources/bin/swe-flow"

# 预检/会话工具：只带运行期需要的，跳过测试与缓存。
rsync -a \
  --exclude '__pycache__' \
  --exclude 'test_*.py' \
  --exclude '.pytest_cache' \
  "$TOOLS_SRC/" "$APP/Contents/Resources/tools/"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist" >/dev/null

echo "==> 校验 Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> ad-hoc 签名"
xattr -cr "$APP" || true
codesign --force --sign - "$APP/Contents/Resources/bin/swe-flow" >/dev/null
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "    签名校验通过"

echo "==> 打包"
ditto -c -k --keepParent "$APP" "$DIST_DIR/$APP_NAME-$VERSION.zip"
# GitHub release assets are safer with an ASCII filename; keep the localized
# zip for local use as well.
cp "$DIST_DIR/$APP_NAME-$VERSION.zip" "$DIST_DIR/SWE-Workbench-$VERSION.zip"

if [[ $MAKE_DMG -eq 1 ]]; then
  STAGE="$BUILD_DIR/dmg"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
    "$DIST_DIR/$APP_NAME-$VERSION.dmg"
fi

echo
echo "构建完成："
du -sh "$APP" "$DIST_DIR"/* | sed 's/^/    /'
