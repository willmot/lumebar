#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-app.sh [--skip-build] [--output-dir <dir>] [--no-zip]

Builds and packages LumeBar as a macOS .app bundle.

Options:
  --skip-build        Reuse existing release build artifacts.
  --output-dir <dir>  Output directory (default: dist).
  --no-zip            Do not create a .zip archive.

Environment:
  LUMEBAR_SIGN_IDENTITY  Optional codesign identity (e.g. a self-signed "LumeBar Dev"
                         certificate). A stable identity keeps macOS privacy decisions
                         such as Local Network across rebuilds. Unset = ad-hoc signature.
EOF
}

output_dir="dist"
skip_build=0
create_zip=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      skip_build=1
      shift
      ;;
    --output-dir)
      output_dir="${2:-}"
      if [[ -z "$output_dir" ]]; then
        echo "error: --output-dir requires a value"
        exit 1
      fi
      shift 2
      ;;
    --no-zip)
      create_zip=0
      shift
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

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

app_name="LumeBar"
binary_path=".build/release/${app_name}"
plist_path="Sources/LumeBar/Resources/Info.plist"
app_path="${output_dir}/${app_name}.app"
zip_path="${output_dir}/${app_name}.zip"

if [[ "$skip_build" -eq 0 ]]; then
  echo "[package] building release binary"
  swift build -c release
fi

if [[ ! -x "$binary_path" ]]; then
  echo "error: release binary not found at ${binary_path}"
  echo "hint: run with build enabled or run 'swift build -c release' first."
  exit 1
fi

if [[ ! -f "$plist_path" ]]; then
  echo "error: missing Info.plist at ${plist_path}"
  exit 1
fi

resource_bundle_path="$(
  find -L .build -type d -path '*/release/*_LumeBar.bundle' -print -quit
)"
if [[ -z "$resource_bundle_path" ]]; then
  echo "error: SwiftPM resource bundle not found in .build/release."
  exit 1
fi

echo "[package] creating app bundle at ${app_path}"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

cp "$binary_path" "$app_path/Contents/MacOS/${app_name}"
cp "$plist_path" "$app_path/Contents/Info.plist"
cp -R "$resource_bundle_path" "$app_path/Contents/Resources/"
chmod +x "$app_path/Contents/MacOS/${app_name}"

# Compile asset catalog to generate AppIcon metadata and icon files for the app bundle.
actool_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumebar.actool.XXXXXX")"
xcrun actool "Sources/LumeBar/Resources/Assets.xcassets" \
  --compile "$actool_tmp_dir" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$actool_tmp_dir/partial.plist" >/dev/null
cp "$actool_tmp_dir/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp "$actool_tmp_dir/Assets.car" "$app_path/Contents/Resources/Assets.car"
rm -rf "$actool_tmp_dir"

# Ensure app bundle points to icon metadata in both legacy and modern forms.
plutil -replace CFBundleIconFile -string AppIcon "$app_path/Contents/Info.plist"
plutil -replace CFBundleIconName -string AppIcon "$app_path/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "$app_name" "$app_path/Contents/Info.plist"
plutil -replace CFBundlePackageType -string APPL "$app_path/Contents/Info.plist"

# Copy SwiftPM dynamic libraries used by the executable.
# The binary is linked with @rpath lookups that resolve next to the executable.
while IFS= read -r dylib_path; do
  cp "$dylib_path" "$app_path/Contents/MacOS/"
done < <(find -L .build -type f -path '*/release/*.dylib' -not -path '*.dSYM/*' -print)

if [[ -n "${LUMEBAR_SIGN_IDENTITY:-}" ]]; then
  echo "[package] signing with identity: ${LUMEBAR_SIGN_IDENTITY}"
  codesign --force --deep --sign "$LUMEBAR_SIGN_IDENTITY" "$app_path"
fi

if [[ "$create_zip" -eq 1 ]]; then
  echo "[package] creating zip archive at ${zip_path}"
  rm -f "$zip_path"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
fi

echo "[package] done"
echo "  app: $(cd "$output_dir" && pwd)/${app_name}.app"
if [[ "$create_zip" -eq 1 ]]; then
  echo "  zip: $(cd "$output_dir" && pwd)/${app_name}.zip"
fi
