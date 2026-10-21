#!/usr/bin/env bash
#
# Nekogram Build & Install Script
# Automates environment setup, compilation, and device deployment.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Defaults
BUILD_TYPE="release"
TARGET_ABI="arm64-v8a"
DO_INSTALL=false
DO_RUN=false
DO_CLEAN=false

# Styling
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

show_help() {
    cat <<EOF
Nekogram Build & Deployment Helper
===================================
Automates Android SDK detection, submodule verification, local configuration,
compilation with custom-signing compatibility, and direct ADB deployment.

Patches & Fixes Included:
  * Native Anti-Tamper Neutralized (colorado.cpp):
    Bypasses the upstream certificate CRC32/size check that previously sent
    SIGKILL (signal 9) ~80ms after launch on custom/locally-signed builds,
    freezing the app at the Nekogram logo.
  * Cronet Exception Handling (CronetHelper.java):
    Wraps Play Services Cronet provider installation in defensive try-catch
    blocks to prevent unhandled runtime exceptions on startup.
  * ProGuard / R8 Keep Rules (proguard-rules.pro):
    Preserves org.chromium.net and com.google.android.gms.net classes from
    aggressive R8 shrinking to avoid reflection errors (Field flags_ not found).

Usage:
  ./build.sh [OPTIONS]

Options:
  -i, --install         Install built APK to connected ADB device via adb install -r
  -r, --run             Launch Nekogram on device after installation (implies -i)
  -a, --abi <abi>       Target ABI: arm64-v8a (default), armeabi-v7a, x86_64, x86, or all
  -d, --debug           Build Debug APK instead of Release APK
  -c, --clean           Clean build artifacts before building (gradle clean)
  -h, --help            Show this guide and help message

Usage Examples:
  ./build.sh                     # 1. Build release APK (arm64-v8a by default)
  ./build.sh -i                  # 2. Build and directly install to connected device
  ./build.sh -r                  # 3. Build, install, and immediately launch the app
  ./build.sh --abi all           # 4. Target another ABI or build all ABIs
  ./build.sh -d                  # 5. Build Debug variant instead of Release

Output Locations:
  Release APK: TMessagesProj_App/build/outputs/apk/release/
  Debug APK:   TMessagesProj_App/build/outputs/apk/debug/
EOF
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--install)
            DO_INSTALL=true
            shift
            ;;
        -r|--run)
            DO_INSTALL=true
            DO_RUN=true
            shift
            ;;
        -a|--abi)
            TARGET_ABI="$2"
            shift 2
            ;;
        -d|--debug)
            BUILD_TYPE="debug"
            shift
            ;;
        -c|--clean)
            DO_CLEAN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_err "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# 1. Resolve Android SDK
if [[ -z "${ANDROID_HOME:-}" ]]; then
    if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT" ]]; then
        export ANDROID_HOME="$ANDROID_SDK_ROOT"
    elif [[ -d "$HOME/Android/Sdk" ]]; then
        export ANDROID_HOME="$HOME/Android/Sdk"
    elif [[ -d "/home/aryan/Android/Sdk" ]]; then
        export ANDROID_HOME="/home/aryan/Android/Sdk"
    else
        log_err "ANDROID_HOME or ANDROID_SDK_ROOT is not set and SDK not found in default locations."
        exit 1
    fi
fi
export ANDROID_SDK_ROOT="$ANDROID_HOME"
log_info "Using Android SDK: $ANDROID_HOME"

# 2. Check Git Submodules
if [[ ! -f "TMessagesProj/jni/td/CMakeLists.txt" || ! -f "TMessagesProj_Modules/media/build.gradle.kts" ]]; then
    log_info "Initializing missing git submodules..."
    git submodule update --init --recursive --depth 1
fi

# 3. Setup local.properties if missing
ensure_local_properties() {
    local target_file="$1"
    local default_api_id="${API_ID:-4}"
    local default_api_hash="${API_HASH:-014b35b6184100b085b0d0572f9b5103}"

    if [[ ! -f "$target_file" ]]; then
        log_info "Creating $(basename "$target_file")..."
        cat <<EOF > "$target_file"
sdk.dir=$ANDROID_HOME
apiId=$default_api_id
apiHash=$default_api_hash
EOF
    else
        if [[ -n "${API_ID:-}" ]]; then
            sed -i "s|^apiId=.*|apiId=$API_ID|" "$target_file"
        fi
        if [[ -n "${API_HASH:-}" ]]; then
            sed -i "s|^apiHash=.*|apiHash=$API_HASH|" "$target_file"
        fi
    fi
}
ensure_local_properties "$SCRIPT_DIR/local.properties"
ensure_local_properties "$SCRIPT_DIR/TMessagesProj_Modules/media/local.properties"

# 4. Setup dummy google-services.json if missing
ensure_google_services() {
    local target_file="$1"
    if [[ ! -f "$target_file" ]]; then
        log_info "Creating dummy $(basename "$target_file")..."
        mkdir -p "$(dirname "$target_file")"
        cat <<'EOF' > "$target_file"
{
  "project_info": {
    "project_number": "000000000000",
    "project_id": "nekogram-dummy",
    "storage_bucket": "nekogram-dummy.appspot.com"
  },
  "client": [
    {
      "client_info": {
        "mobilesdk_app_id": "1:000000000000:android:0000000000000000000000",
        "android_client_info": {
          "package_name": "tw.nekomimi.nekogram"
        }
      },
      "oauth_client": [],
      "api_key": [
        {
          "current_key": "dummy_api_key"
        }
      ],
      "services": {
        "appinvite_service": {
          "other_platform_oauth_client": []
        }
      }
    }
  ],
  "configuration_version": "1"
}
EOF
    fi
}
ensure_google_services "$SCRIPT_DIR/TMessagesProj_App/google-services.json"
ensure_google_services "$SCRIPT_DIR/TMessagesProj/google-services.json"

# 5. Clean if requested
if [[ "$DO_CLEAN" = true ]]; then
    log_info "Cleaning project..."
    ./gradlew clean
fi

# 6. Build APK
TASK_NAME="assembleRelease"
if [[ "$BUILD_TYPE" == "debug" ]]; then
    TASK_NAME="assembleDebug"
fi

GRADLE_ARGS=(
    ":TMessagesProj_App:$TASK_NAME"
    "-Pandroid.injected.testOnly=false"
    "-x" ":TMessagesProj_App:uploadSentryNativeSymbolsForRelease"
    "-x" ":TMessagesProj_App:uploadSentryProguardMappingsRelease"
    "-x" ":TMessagesProj_App:sentryUploadSourceBundleRelease"
)

if [[ "$TARGET_ABI" != "all" ]]; then
    GRADLE_ARGS+=("-Pandroid.injected.build.abi=$TARGET_ABI")
fi

log_info "Building $BUILD_TYPE APK (ABI: $TARGET_ABI)..."
./gradlew "${GRADLE_ARGS[@]}"

# 7. Locate APK
APK_PATH=""
CANDIDATE_PATHS=(
    "TMessagesProj_App/build/outputs/apk/$BUILD_TYPE"
    "TMessagesProj_App/build/intermediates/apk/$BUILD_TYPE"
)

for search_dir in "${CANDIDATE_PATHS[@]}"; do
    if [[ -d "$search_dir" ]]; then
        if [[ "$TARGET_ABI" != "all" ]]; then
            FOUND=$(find "$search_dir" -maxdepth 1 -name "*$TARGET_ABI*.apk" | head -n 1 || true)
        else
            FOUND=$(find "$search_dir" -maxdepth 1 -name "*.apk" | head -n 1 || true)
        fi
        if [[ -n "$FOUND" && -f "$FOUND" ]]; then
            APK_PATH="$FOUND"
            break
        fi
    fi
done

if [[ -z "$APK_PATH" || ! -f "$APK_PATH" ]]; then
    log_err "Build finished, but could not locate output APK file!"
    exit 1
fi

# Ensure standard output location has the latest APK
DEST_DIR="$SCRIPT_DIR/TMessagesProj_App/build/outputs/apk/$BUILD_TYPE"
mkdir -p "$DEST_DIR"
DEST_FILE="$DEST_DIR/$(basename "$APK_PATH")"
if [[ "$(realpath "$APK_PATH")" != "$(realpath "$DEST_FILE" 2>/dev/null || echo "$DEST_FILE")" ]]; then
    cp -f "$APK_PATH" "$DEST_FILE"
fi
APK_PATH="$(realpath "$DEST_FILE")"

log_ok "Build successful!"
log_ok "APK: $APK_PATH ($(du -h "$APK_PATH" | cut -f1))"

# 8. Install to device if requested
if [[ "$DO_INSTALL" = true ]]; then
    log_info "Checking for connected adb devices..."
    if ! command -v adb &>/dev/null; then
        export PATH="$ANDROID_HOME/platform-tools:$PATH"
    fi

    DEVICE_COUNT=$(adb devices | grep -v "List" | grep "device$" | wc -l || true)
    if [[ "$DEVICE_COUNT" -eq 0 ]]; then
        log_err "No authorized adb device found. Please connect your device and enable USB debugging."
        exit 1
    fi

    log_info "Installing APK to connected device..."
    adb install -r "$APK_PATH"
    log_ok "Installation complete!"

    if [[ "$DO_RUN" = true ]]; then
        log_info "Launching Nekogram..."
        adb shell am start -n tw.nekomimi.nekogram/org.telegram.ui.LaunchActivity
        log_ok "App launched!"
    fi
fi
