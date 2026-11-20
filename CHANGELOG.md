# Changelog

## [Unreleased]
### Added
- New app icon and menu bar symbol ("Stacked Instances"), rendered from SVG sources in `design/icon` via `scripts/render-icons.swift`.
- Popover header with service status, VM counts and a refresh button.
- Empty state with a copyable `lume create` command, and an error banner with Try Again / Open Settings.
- Row context menu: start headless or with display, open Screen Sharing, copy name or IP.
- Screen Sharing source per VM (Automatic, Lume VNC, macOS Screen Sharing). Without Lume VNC (e.g. `--vnc disabled`) LumeBar falls back to the guest's own Screen Sharing for opening and, with a Keychain-stored login, for live previews.
- `NSLocalNetworkUsageDescription` so macOS can prompt for Local Network access to guests.
- Optional `LUMEBAR_SIGN_IDENTITY` for `scripts/package-app.sh` to sign with a stable identity.
- Settings: grouped layout, connection status with Test Connection and Reset to Default, detected `lume` CLI location, app version.

### Changed
- VM rows show OS, CPU, memory and IP at a glance, with icon buttons for start, stop and Screen Sharing.
- "Start headless" toggle is available directly in the popover footer.
- Running VMs are listed first, then provisioning VMs, then the rest.
- Compact thumbnail placeholder until the first VNC frame arrives; the "Double-click to open" hint only shows on hover.
- README showcases the new design with screenshots.

### Fixed
- Start is no longer offered while a VM is provisioning; the row shows the provisioning step instead.
- `lume` installed in `~/.local/bin` (the Lume installer's default) is now found when the app is launched from Finder.
- Menu bar icon now loads from the compiled asset catalog instead of falling back to an SF Symbol.
- Changing the service URL in Settings applies immediately and clears the previous connection status.
- `scripts/package-app.sh` works with newer SwiftPM, where `.build/release` is a symlink.

## [1.0.0-beta3] - 2026-02-06
### Added
- Added repeatable app packaging scripts for `.app` and `.zip` outputs.
- Added optional signing/notarization script for Developer ID distribution.

### Changed
- Reworked icon pipeline with a new full app icon design and a dedicated monochrome menu bar glyph.
- Updated menu bar icon rendering to use fixed status-item sizing for consistent appearance.
- Updated app bundle packaging to compile assets with `actool` and emit `AppIcon.icns`.

### Fixed
- Fixed packaged app startup crash caused by missing bundled `libRoyalVNCKit.dylib`.
- Fixed app icon metadata/packaging so Finder and LaunchServices resolve the icon reliably.

## [1.0.0-beta2] - 2026-02-06
### Fixed
- Added explicit CLI-not-installed error handling so Start/Stop shows a clear message when `lume` is unavailable.
- Stabilized initial menu layout before thumbnail arrival.
- Updated thumbnail viewport to `4:3` with fit mode to avoid top/bottom cropping.

## [1.0.0-beta] - 2026-02-06
### Added
- Menu bar UI for listing Lume VMs and viewing running state.
- VM controls from the menu bar, including Start/Stop and Screen Sharing launch.
- Snapshot thumbnail preview for running VMs when opening the menu.
- Settings for Lume base URL and headless start mode.

### Changed
- VM start/stop now uses direct `lume` CLI commands instead of API mutation endpoints.
- Start command is detached so VMs continue running after the menu bar app exits.
- Details panel uses full-row click target and dynamic menu sizing.
- App and menu bar icons refreshed.

### Fixed
- Menu bar icon rendering and template handling.
- Thumbnail rendering stability and layout sizing issues during boot.
- CLI executable path resolution in app runtime context.

### Compatibility
- Platform target is macOS 26+.
- Lume CLI (`lume`) must be installed locally.

### Known Issues
- Very early VM boot frames can still appear black in snapshot mode until guest display is initialized.
