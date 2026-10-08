#!/bin/bash
# 编译并组装 TokenDeck.app(菜单栏 App:无 Dock 图标 + 开机自启 + 固定身份签名)。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="TokenDeck"
BUNDLE_ID="${BUNDLE_ID:-app.tokenusagedashboard.menu}"
VERSION="1.0.0"
APP="${APP_NAME}.app"
BUILD_PATH="${SWIFT_BUILD_PATH:-.build}"
SIGNING_DIR="${TOKENDECK_SIGNING_DIR:-$HOME/.config/tokendeck/signing}"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
SIGN_ARGS=()
if [[ -z "$SIGNING_IDENTITY" ]]; then
    if [[ ! -f "$SIGNING_DIR/identity" || ! -f "$SIGNING_DIR/password" ]]; then
        echo "Run bash scripts/setup-local-signing.sh once, or set CODE_SIGN_IDENTITY." >&2
        exit 1
    fi
    SIGNING_IDENTITY=$(cat "$SIGNING_DIR/identity")
    security unlock-keychain -p "$(cat "$SIGNING_DIR/password")" "$SIGNING_DIR/signing.keychain-db"
    SIGN_ARGS=(--keychain "$SIGNING_DIR/signing.keychain-db")
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Ad-hoc signing changes keychain identity between builds; use a persistent certificate." >&2
    exit 1
fi

echo "==> swift build -c release"
swift build --scratch-path "$BUILD_PATH" -c release

echo "==> 组装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
mkdir -p "${APP}/Contents/Helpers"

cp "$BUILD_PATH/release/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"

# App 图标(若存在 AppIcon.icns 则嵌入)
ICON_LINE=""
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
    ICON_LINE='    <key>CFBundleIconFile</key>        <string>AppIcon</string>'
fi

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>TokenDeck</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
${ICON_LINE}
    <key>NSHumanReadableCopyright</key><string>TokenDeck</string>
</dict>
</plist>
PLIST

echo "==> 固定钥匙串助手"
# Re-signing self-signed code can change its partition identity. Reuse the exact
# helper bytes unless its source, architecture, bundle identity or signer changes.
HELPER_SOURCE="Sources/KeychainHelper/main.swift"
HELPER_HASH=$(shasum -a 256 "$HELPER_SOURCE" | awk '{print $1}')
HELPER_KEY=$(printf '%s\n' "$HELPER_HASH" "$SIGNING_IDENTITY" "$BUNDLE_ID" "$(uname -m)" | shasum -a 256 | awk '{print $1}')
HELPER_CACHE="$SIGNING_DIR/helpers/$HELPER_KEY"
mkdir -p "$HELPER_CACHE"
if [[ ! -f "$HELPER_CACHE/TokenDeckKeychain" ]]; then
    HELPER_TEMP=$(mktemp -d "$HELPER_CACHE/build.XXXXXX")
    trap 'rm -rf "$HELPER_TEMP"' EXIT
    swiftc -O "$HELPER_SOURCE" -o "$HELPER_TEMP/TokenDeckKeychain"
    codesign --force --identifier "$BUNDLE_ID" --sign "$SIGNING_IDENTITY" "${SIGN_ARGS[@]}" "$HELPER_TEMP/TokenDeckKeychain"
    codesign --verify --strict "$HELPER_TEMP/TokenDeckKeychain"
    mv "$HELPER_TEMP/TokenDeckKeychain" "$HELPER_CACHE/TokenDeckKeychain"
fi
codesign --verify --strict "$HELPER_CACHE/TokenDeckKeychain"
cp "$HELPER_CACHE/TokenDeckKeychain" "$APP/Contents/Helpers/TokenDeckKeychain"

echo "==> 固定身份签名"
codesign --force --sign "$SIGNING_IDENTITY" "${SIGN_ARGS[@]}" "${APP}"
codesign --verify --deep --strict "${APP}"

echo "==> 完成: $(pwd)/${APP}"
echo "    运行:  open ${APP}"
echo "    安装:  cp -r ${APP} /Applications/  (开机自启需 App 在稳定路径)"
