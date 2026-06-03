#!/bin/bash
set -euo pipefail

# === DEBUG RELAY: Report failures back to Supabase ===
report_status() {
    local status="$1"
    local error_msg="${2:-}"

    if [ -z "${SUPABASE_EDGE_URL:-}" ]; then
        SUPABASE_EDGE_URL="https://evqbtkowesjdbndksmpt.supabase.co/functions/v1/github-app-token"
    fi

    echo "📡 Reporting build status: $status"
    curl -s -X POST "$SUPABASE_EDGE_URL" \
      -H "Content-Type: application/json" \
      -d "{\"action\":\"build_status\",\"repo_owner\":\"${REPO_OWNER:-unknown}\",\"repo_name\":\"${REPO_NAME:-unknown}\",\"run_id\":\"${RUN_ID:-0}\",\"status\":\"$status\",\"error\":\"$error_msg\",\"app_name\":\"${APP_NAME:-unknown}\",\"platform\":\"ios\"}" \
      || echo "⚠️ Status report failed (non-critical)"
}

on_error() {
    local exit_code=$?
    local line_number=${BASH_LINENO[0]}
    BUILD_ERROR="iOS build failed at line $line_number with exit code $exit_code"
    echo "❌ $BUILD_ERROR"
    report_status "failed" "$BUILD_ERROR"
}

trap 'on_error' ERR
# === END DEBUG RELAY ===

# Inputs (Passed via Environment Variables from the Workflow Launcher)
# APP_NAME
# BUNDLE_ID            (optional — derived from APP_NAME if empty)
# UPLOAD_URL           (Supabase signed URL for the IPA — optional; skipped if empty)
# PAYLOAD_KEY          (Secret — used by launcher to decrypt this file)
# RUN_ID / REPO_OWNER / REPO_NAME / GITHUB_TOKEN
#
# App Store Connect API key (used by xcodebuild for cloud-managed signing + by altool)
# APP_STORE_CONNECT_KEY_P8     (base64 of the .p8 private key)
# APP_STORE_CONNECT_KEY_ID
# APP_STORE_CONNECT_ISSUER_ID
# APPLE_TEAM_ID
#
# Signing model: App Store Connect API key + -allowProvisioningUpdates enables
# Apple "cloud-managed" distribution signing. No keychain, no .p12, no cert
# persistence is required — Apple holds the private key, so any runner can sign.

echo "🍏 Starting Encrypted iOS Payload Execution..."

REPO_ROOT="$(pwd)"

# 0. Pin Xcode 16.2 (proven). Fall back to newest installed if 16.2 is absent.
if [ -d "/Applications/Xcode_16.2.app" ]; then
  sudo xcode-select -s "/Applications/Xcode_16.2.app"
else
  echo "⚠️ Xcode_16.2 not found; selecting newest installed Xcode."
  sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)" || true
fi
echo "Using Xcode: $(xcodebuild -version | head -1)"

# 0b. Install the iOS platform/simulator runtime on demand.
# macos-15 runners ship Xcode 16.x headers but the iOS runtime is not always
# pre-installed, so ibtool fails compiling Capacitor's LaunchScreen.storyboard
# with "iOS X.Y Platform Not Installed". The CoreSimulator service is sometimes
# not ready on a fresh VM (exit 70), so bootstrap + retry.
echo "📲 Ensuring iOS platform runtime is installed..."
sudo xcodebuild -runFirstLaunch || true
for attempt in 1 2 3 4 5; do
  if xcodebuild -downloadPlatform iOS; then
    echo "✅ iOS platform installed."
    break
  fi
  echo "Attempt $attempt to download iOS platform failed, retrying in 30s..."
  sleep 30
done

# 1. Install Dependencies
echo "📦 Installing Dependencies..."
rm -f bun.lock
npm install --legacy-peer-deps

# 2. Build Web Assets
echo "🏗️  Building Web Assets..."
npm run build

# Some templates output to 'build' instead of 'dist'
if [ ! -d "dist" ] && [ -d "build" ]; then
  echo "Renaming 'build' to 'dist' for Capacitor..."
  mv build dist
fi
if [ ! -d "dist" ]; then
  echo "ERROR: 'dist' folder missing. Build failed."
  exit 1
fi

# 3. NUKE OLD CONFIG & FORCE LOCAL
echo "💣 Nuke Old Config & Force Local..."
rm -f capacitor.config.ts capacitor.config.json
# Pin Capacitor to a single consistent major so the generated Podfile's iOS
# deployment target always matches what the Capacitor pod requires.
npm install @capacitor/core@6 @capacitor/cli@6 @capacitor/ios@6 --legacy-peer-deps

# Bundle ID Handling
if [ -n "${BUNDLE_ID:-}" ]; then
  PACKAGE_ID="$BUNDLE_ID"
  echo "Using provided Bundle ID: $PACKAGE_ID"
else
  echo "WARNING: BUNDLE_ID not provided. Generating from App Name..."
  SANITIZED_NAME=$(echo "${APP_NAME:-vibeship_app}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//' | sed 's/_$//')
  if [[ "$SANITIZED_NAME" =~ ^[0-9] ]]; then
    SANITIZED_NAME="app_${SANITIZED_NAME}"
  fi
  PACKAGE_ID="com.vibeship.${SANITIZED_NAME}"
  echo "Generated Bundle ID: $PACKAGE_ID"
fi

FINAL_APP_NAME="${APP_NAME:-Vibe Ship App}"

# Initialize Capacitor safely
export CI=true
npx cap init "$FINAL_APP_NAME" "$PACKAGE_ID" --web-dir dist

# 4. Create iOS Project
# `cap add ios` generates the Xcode project + Podfile and then runs `pod install`
# internally. That internal pod install can fail on Capacitor version skew, so
# tolerate it (|| true) — we force the Podfile deployment target and run our own
# pod install (with the UTF-8 locale) below.
echo "🍎 Creating iOS Project..."
rm -rf ios
npx cap add ios || true

# Force a modern iOS deployment target so the Podfile matches what the Capacitor
# pod requires. Without this, pod install fails with "could not find compatible
# versions for pod Capacitor ... required a higher minimum deployment target".
if [ -f "$REPO_ROOT/ios/App/Podfile" ]; then
  sed -i '' -e "s/platform :ios, '[0-9.]*'/platform :ios, '14.0'/" "$REPO_ROOT/ios/App/Podfile"
  echo "📱 Podfile deployment target pinned to iOS 14.0"
fi

npx cap sync ios || true

# --- AUTO-INCREMENT BUILD NUMBER (TestFlight requires a unique value) ---
BUILD_NUMBER=$(date +"%s")
echo "Build Number: $BUILD_NUMBER"

# 5. Install CocoaPods dependencies (UTF-8 locale avoids pod install crashes)
echo "📦 Installing CocoaPods..."
cd "$REPO_ROOT/ios/App"
# Re-assert the deployment target in case `cap sync` regenerated the Podfile.
sed -i '' -e "s/platform :ios, '[0-9.]*'/platform :ios, '14.0'/" Podfile || true
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
pod install || pod install --repo-update

# 6. App Store Connect API Key (cloud-managed signing + altool upload)
if [ -z "${APP_STORE_CONNECT_KEY_P8:-}" ] || [ -z "${APP_STORE_CONNECT_KEY_ID:-}" ] || [ -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; then
  echo "❌ Error: App Store Connect credentials are missing!"
  echo "Required: APP_STORE_CONNECT_KEY_P8, APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, APPLE_TEAM_ID"
  exit 1
fi

KEY_ID="$APP_STORE_CONNECT_KEY_ID"
ISSUER_ID="$APP_STORE_CONNECT_ISSUER_ID"

# altool/xcodebuild auto-discover keys in these dirs; write to both.
mkdir -p "$HOME/.appstoreconnect/private_keys" "$HOME/private_keys"
echo "$APP_STORE_CONNECT_KEY_P8" | base64 -d > "$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
cp "$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8" "$HOME/private_keys/AuthKey_${KEY_ID}.p8"
chmod 600 "$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8" "$HOME/private_keys/AuthKey_${KEY_ID}.p8"
AUTH_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"

# 7. Archive WITHOUT code signing.
# Archiving with automatic signing makes Xcode provision a *Development*
# certificate, which fails on accounts at the cert cap ("maximum number of
# certificates"). We archive unsigned and apply distribution (cloud-managed)
# signing at export time instead — the standard App Store CI pattern.
echo "📦 Archiving iOS App (unsigned)..."
ARCHIVE_PATH="$REPO_ROOT/ios/App/build/App.xcarchive"

xcodebuild archive \
  -workspace App.xcworkspace \
  -scheme App \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$PACKAGE_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

# 8. Export IPA (App Store Connect signed)
echo "📤 Exporting IPA..."
cat > "$REPO_ROOT/ios/App/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>${APPLE_TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>uploadSymbols</key>
    <true/>
    <key>generateAppStoreInformation</key>
    <true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$REPO_ROOT/ios/App/ExportOptions.plist" \
  -exportPath "$REPO_ROOT/ios/App/build/ExportedIPA" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$AUTH_KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID"

IPA_PATH=$(find "$REPO_ROOT/ios/App/build/ExportedIPA" -name "*.ipa" | head -n 1)
if [ -z "$IPA_PATH" ]; then
  echo "ERROR: Exported IPA not found."
  exit 1
fi
echo "✅ IPA built: $IPA_PATH"

# 9. Upload IPA to Supabase Storage (optional — skipped when no signed URL given)
if [ -n "${UPLOAD_URL:-}" ]; then
  echo "👻 Uploading IPA to Storage..."
  if curl -fsS -X PUT -H "Content-Type: application/octet-stream" --upload-file "$IPA_PATH" "$UPLOAD_URL"; then
    echo "✅ IPA uploaded."
  else
    echo "ERROR: IPA upload failed."
    exit 1
  fi
else
  echo "ℹ️ UPLOAD_URL not set — skipping Supabase storage upload."
fi

# 10. Upload to App Store Connect (TestFlight) via the ASC API key.
# Succeeds only if an App Store Connect app record exists for this bundle id.
echo "🚀 Uploading to App Store Connect (TestFlight)..."
xcrun altool --upload-app \
  --type ios \
  --file "$IPA_PATH" \
  --apiKey "$KEY_ID" \
  --apiIssuer "$ISSUER_ID" \
  && echo "✅ Uploaded to App Store Connect." \
  || echo "ℹ️ App Store Connect upload skipped/failed (app record may not exist yet) — IPA is available for download."

echo "✅ Build & Upload Completed."
report_status "success" ""

# 11. CLEANUP (Ghost Vanish)
cd "$REPO_ROOT"
if [ -z "${SUPABASE_EDGE_URL:-}" ]; then
    SUPABASE_EDGE_URL="https://evqbtkowesjdbndksmpt.supabase.co/functions/v1/github-app-token"
fi

REPO_FULL="${REPO_OWNER:-}/${REPO_NAME:-}"
BRANCH="main"

echo "Calling Edge Function to delete this run for $REPO_FULL run=${RUN_ID:-0}"
curl -s -X POST "$SUPABASE_EDGE_URL" \
  -H "Content-Type: application/json" \
  -d "{\"action\":\"cleanup\",\"repo_owner\":\"${REPO_OWNER:-}\",\"repo_name\":\"${REPO_NAME:-}\",\"branch\":\"$BRANCH\",\"run_id\":\"${RUN_ID:-0}\"}" \
  || echo "Cleanup Callback Failed"

# Wipe sensitive signing material
rm -f "$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8" "$HOME/private_keys/AuthKey_${KEY_ID}.p8" 2>/dev/null || true

echo "👋 iOS Payload Execution Finished."
