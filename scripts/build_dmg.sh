#!/bin/bash
# build_dmg.sh — Build SwiftFTP.app and package as .dmg
# Usage: ./scripts/build_dmg.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="${PROJECT_DIR}/build"
BUILD_DIR="/tmp/swiftftp-build"
APP_NAME="SwiftFTP"
DMG_NAME="${APP_NAME}_v2.0.0"
SCHEME="SwiftFTP"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"

echo "==> Cleaning build directory..."
rm -rf "${BUILD_DIR}"
rm -rf "${ARTIFACT_DIR}"
mkdir -p "${BUILD_DIR}" "${ARTIFACT_DIR}"

if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "WARNING: ${APP_NAME} is currently running. Quit it before installing the new DMG."
fi

echo "==> Building ${CONFIGURATION} configuration..."
xcodebuild \
  -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${BUILD_DIR}/DerivedData" \
  -clonedSourcePackagesDirPath "${BUILD_DIR}/SourcePackages" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tail -5

APP_PATH="${BUILD_DIR}/DerivedData/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

if [ ! -d "${APP_PATH}" ]; then
  echo "ERROR: ${APP_PATH} not found. Build may have failed."
  exit 1
fi

echo "==> App built at: ${APP_PATH}"
echo "==> Bundle version: $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${APP_PATH}/Contents/Info.plist")"

echo "==> Ad-hoc signing app..."
/usr/bin/codesign --force --deep --sign - \
  --entitlements "${PROJECT_DIR}/Sources/Resources/${APP_NAME}.entitlements" \
  "${APP_PATH}"

# --- Create DMG ---
DMG_DIR="${BUILD_DIR}/dmg_staging"
DMG_OUTPUT="${ARTIFACT_DIR}/${DMG_NAME}.dmg"

echo "==> Preparing DMG staging area..."
rm -rf "${DMG_DIR}"
mkdir -p "${DMG_DIR}"

# Copy app
cp -R "${APP_PATH}" "${DMG_DIR}/"

# Create symlink to /Applications for drag-install
ln -s /Applications "${DMG_DIR}/Applications"

echo "==> Creating DMG..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_OUTPUT}"

hdiutil verify "${DMG_OUTPUT}"

echo ""
echo "================================================"
echo "  DMG created: ${DMG_OUTPUT}"
echo "  Size: $(du -h "${DMG_OUTPUT}" | cut -f1)"
echo "================================================"
echo ""
echo "To install: Open the .dmg and drag SwiftFTP to Applications."
