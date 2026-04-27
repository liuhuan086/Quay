#!/bin/bash
# build_dmg.sh — Build SwiftFTP.app (Release) and package as .dmg
# Usage: ./scripts/build_dmg.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_NAME="SwiftFTP"
DMG_NAME="${APP_NAME}_v2.0.0"
SCHEME="SwiftFTP"

echo "==> Cleaning build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Building Release configuration..."
xcodebuild \
  -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -derivedDataPath "${BUILD_DIR}/DerivedData" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build 2>&1 | tail -5

APP_PATH="${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "${APP_PATH}" ]; then
  echo "ERROR: ${APP_PATH} not found. Build may have failed."
  exit 1
fi

echo "==> App built at: ${APP_PATH}"

# --- Create DMG ---
DMG_DIR="${BUILD_DIR}/dmg_staging"
DMG_OUTPUT="${BUILD_DIR}/${DMG_NAME}.dmg"

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

echo ""
echo "================================================"
echo "  DMG created: ${DMG_OUTPUT}"
echo "  Size: $(du -h "${DMG_OUTPUT}" | cut -f1)"
echo "================================================"
echo ""
echo "To install: Open the .dmg and drag SwiftFTP to Applications."
