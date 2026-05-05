#!/bin/sh
set -eu

CEF_ROOT="${SRCROOT}/.cef-cache/current"
if [ ! -d "$CEF_ROOT" ]; then
  "${SRCROOT}/scripts/download-cef-runtime.sh"
fi

FRAMEWORK_SRC="${CEF_ROOT}/Release/Chromium Embedded Framework.framework"
FRAMEWORK_DEST="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Chromium Embedded Framework.framework"
HELPER_BUNDLE_BASE="cmux Chromium Helper"

if [ ! -d "$FRAMEWORK_SRC" ]; then
  echo "error: CEF framework not found at $FRAMEWORK_SRC" >&2
  exit 1
fi

mkdir -p "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
rsync -a --delete "$FRAMEWORK_SRC/" "$FRAMEWORK_DEST/"
if [ ! -d "$FRAMEWORK_DEST/Versions" ]; then
  mkdir -p "$FRAMEWORK_DEST/Versions/A"
  mv "$FRAMEWORK_DEST/Chromium Embedded Framework" "$FRAMEWORK_DEST/Versions/A/"
  mv "$FRAMEWORK_DEST/Resources" "$FRAMEWORK_DEST/Versions/A/"
  mv "$FRAMEWORK_DEST/Libraries" "$FRAMEWORK_DEST/Versions/A/"
  ln -s A "$FRAMEWORK_DEST/Versions/Current"
  ln -s "Versions/Current/Chromium Embedded Framework" "$FRAMEWORK_DEST/Chromium Embedded Framework"
  ln -s "Versions/Current/Resources" "$FRAMEWORK_DEST/Resources"
  ln -s "Versions/Current/Libraries" "$FRAMEWORK_DEST/Libraries"
fi
xattr -cr "$FRAMEWORK_DEST" || true

build_helper() {
  helper_name="$1"
  helper_bundle_identifier_suffix="$2"
  helper_app="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/${helper_name}.app"
  helper_exe="${helper_app}/Contents/MacOS/${helper_name}"
  helper_plist="${helper_app}/Contents/Info.plist"

  rm -rf "$helper_app"
  mkdir -p "${helper_app}/Contents/MacOS"
  clang++ -std=c++20 -ObjC++ -fobjc-arc -DOS_MAC=1 \
    -I "$CEF_ROOT" \
    "${SRCROOT}/Sources/Chromium/CmuxChromiumHelper.mm" \
    -framework Cocoa -ldl \
    -o "$helper_exe"
  cat > "$helper_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${helper_name}</string>
  <key>CFBundleIdentifier</key>
  <string>${PRODUCT_BUNDLE_IDENTIFIER}.chromium-helper${helper_bundle_identifier_suffix}</string>
  <key>CFBundleName</key>
  <string>${helper_name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSBackgroundOnly</key>
  <true/>
</dict>
</plist>
PLIST
  xattr -cr "$helper_app" || true
}

build_helper "$HELPER_BUNDLE_BASE" ""
build_helper "$HELPER_BUNDLE_BASE (GPU)" ".gpu"
build_helper "$HELPER_BUNDLE_BASE (Plugin)" ".plugin"
build_helper "$HELPER_BUNDLE_BASE (Renderer)" ".renderer"

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$FRAMEWORK_DEST"
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/${HELPER_BUNDLE_BASE}.app" \
    "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/${HELPER_BUNDLE_BASE} (GPU).app" \
    "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/${HELPER_BUNDLE_BASE} (Plugin).app" \
    "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/${HELPER_BUNDLE_BASE} (Renderer).app"
fi
