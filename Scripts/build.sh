#!/bin/bash
# TabType build helper.
#   ./Scripts/build.sh gencli   — build the inference validation CLI
#   ./Scripts/build.sh app      — build TabType and bundle TabType.app into dist/
#
# Requires full Xcode (MLX compiles Metal shaders; `swift build` cannot).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${CONFIG:-Debug}"
DERIVED="$ROOT/.build-xcode"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"

build_scheme() {
    xcrun xcodebuild -scheme TabType -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" \
        -skipPackagePluginValidation build
}

cmd="${1:-app}"
case "$cmd" in
gencli)
    build_scheme
    echo "Built: $PRODUCTS/tabtype-gencli"
    ;;
app)
    build_scheme

    APP="$ROOT/dist/TabType.app"
    echo "Bundling $APP …"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

    # Executable
    cp "$PRODUCTS/TabType" "$APP/Contents/MacOS/TabType"

    # SwiftPM resource bundles (emoji.json, tokenizer configs, …). These are found at
    # runtime via `Bundle.module`, whose accessor searches Bundle.main.resourceURL
    # (Contents/Resources) and the .app root — NOT Contents/MacOS. So they go in
    # Contents/Resources. (MLX finds its Metal kernels via the colocated mlx.metallib
    # below, independent of where its bundle lives.)
    find "$PRODUCTS" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

    # MLX finds its Metal kernels by first looking for a *colocated* `mlx.metallib`
    # next to the binary. The SwiftPM bundle's own lookup expects the bundle at the
    # .app root, which breaks a normal Contents/MacOS layout — so copy the metallib
    # to Contents/MacOS/mlx.metallib, which the colocated lookup resolves first.
    METALLIB="$(find "$PRODUCTS" -name "default.metallib" | head -1)"
    if [ -n "$METALLIB" ]; then
        cp "$METALLIB" "$APP/Contents/MacOS/mlx.metallib"
    else
        echo "WARNING: default.metallib not found — GPU inference will fail." >&2
    fi

    # Info.plist
    cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

    # Code signature. Prefer the stable self-signed "TabType Dev" identity (set up via
    # Scripts/setup-signing.sh) so macOS keeps Accessibility/Screen Recording grants
    # across rebuilds; fall back to ad-hoc if it isn't installed.
    IDENTITY="${SIGN_IDENTITY:-TabType Dev}"
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
        echo "Signing with \"$IDENTITY\" (stable — permissions persist)."
        codesign --force --deep --sign "$IDENTITY" \
            --identifier app.tabtype.TabType \
            --entitlements "$ROOT/Resources/TabType.entitlements" \
            "$APP"
    else
        echo "Signing ad-hoc (run Scripts/setup-signing.sh to persist permissions)."
        codesign --force --deep --sign - \
            --identifier app.tabtype.TabType \
            --entitlements "$ROOT/Resources/TabType.entitlements" \
            "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP"
    fi

    echo "Done: $APP"
    echo "Run:  open \"$APP\"   (or: \"$APP/Contents/MacOS/TabType\" to see logs)"
    ;;
*)
    echo "usage: $0 {gencli|app}" >&2
    exit 1
    ;;
esac
