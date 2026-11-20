#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/sign-and-notarize.sh --identity "<Developer ID Application: ...>" --keychain-profile <profile> [--app <path>] [--output-zip <path>]

Signs, notarizes, and staples an existing LumeBar .app bundle.

Options:
  --identity <name>          Developer ID Application signing identity.
  --keychain-profile <name>  notarytool keychain profile name.
  --app <path>               App bundle path (default: dist/LumeBar.app).
  --output-zip <path>        Zip path for notarization/upload (default: dist/LumeBar.zip).
EOF
}

identity=""
keychain_profile=""
app_path="dist/LumeBar.app"
zip_path="dist/LumeBar.zip"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      identity="${2:-}"
      shift 2
      ;;
    --keychain-profile)
      keychain_profile="${2:-}"
      shift 2
      ;;
    --app)
      app_path="${2:-}"
      shift 2
      ;;
    --output-zip)
      zip_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$identity" || -z "$keychain_profile" ]]; then
  echo "error: --identity and --keychain-profile are required."
  usage
  exit 1
fi

if [[ ! -d "$app_path" ]]; then
  echo "error: app not found at ${app_path}"
  echo "hint: run scripts/package-app.sh first."
  exit 1
fi

echo "[sign] signing ${app_path}"
for dylib in "$app_path"/Contents/MacOS/*.dylib; do
  [[ -f "$dylib" ]] || continue
  codesign --force --options runtime --timestamp --sign "$identity" "$dylib"
done
codesign --force --options runtime --timestamp --sign "$identity" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

echo "[notarize] creating upload zip at ${zip_path}"
mkdir -p "$(dirname "$zip_path")"
rm -f "$zip_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

echo "[notarize] submitting to Apple notarization service"
xcrun notarytool submit "$zip_path" --keychain-profile "$keychain_profile" --wait

echo "[notarize] stapling ticket"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose "$app_path"

echo "[notarize] rebuilding zip with stapled app"
rm -f "$zip_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

echo "[notarize] done"
echo "  app: $(cd "$(dirname "$app_path")" && pwd)/$(basename "$app_path")"
echo "  zip: $(cd "$(dirname "$zip_path")" && pwd)/$(basename "$zip_path")"
