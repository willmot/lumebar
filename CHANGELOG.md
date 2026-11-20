# Changelog

## [Unreleased]

## [1.0.0-beta4]

### Added
- A refreshed app icon and menu with service status, VM counts, a scrollable VM list, and per-VM actions.
- A start-mode picker in the menu and Settings, with headless starts without Lume VNC as the default.
- Per-VM Screen Sharing sources and read-only inline previews from Lume VNC or an authenticated macOS guest.

### Changed
- Start and stop use the selected Lume service and VM storage location. The local CLI can start the default service when needed.
- Settings validates the service URL and applies it when you select **Save and Test**.
- Screen Sharing logins are scoped to the service, VM identity, storage location, and guest address. Logins from older preview builds need to be re-entered.
- Packaging verifies the app signature before archiving. CI builds the bundle and runs Swift regression tests.

### Fixed
- VM starts without Lume VNC are always headless and require Lume 0.6.0 or later.
- A VM that's still provisioning cannot be started from the menu.
- Automatic Screen Sharing uses a Lume VNC endpoint when advertised and no guest login is saved.
- Previews wait for a visible frame during boot and report guest authentication failures.
- Running VM rows keep the IP address and storage visible, and Settings shows connection errors on their own line.

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
