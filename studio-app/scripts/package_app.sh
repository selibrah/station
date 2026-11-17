#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUDIO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_DIR="$(cd "${STUDIO_DIR}/.." && pwd)"
DAEMON_DIR="${WORKSPACE_DIR}/daemon"
RELEASES_DIR="${WORKSPACE_DIR}/releases"

VERSION="0.4.0"
APP_NAME="Station Studio"
APP_DIR="${STUDIO_DIR}/dist/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "=== 1. Building Rust station daemon & MCP binary (v${VERSION}) ==="
(cd "${DAEMON_DIR}" && cargo build --release)

echo "=== 2. Building Swift 6 StationStudio binary ==="
(cd "${STUDIO_DIR}" && swift build -c release)

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${RELEASES_DIR}"

cp "${STUDIO_DIR}/.build/arm64-apple-macosx/release/StationStudio" "${MACOS_DIR}/StationStudio"
cp "${DAEMON_DIR}/target/release/station" "${MACOS_DIR}/station"
chmod +x "${MACOS_DIR}/StationStudio" "${MACOS_DIR}/station"

echo "=== 3. Generating macOS AppIcon.icns ==="
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"
swift - "${ICONSET_DIR}" <<'SWIFT_ICON'
import AppKit
import Foundation

let outDir = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (px, name) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.26, alpha: 1.0),
        NSColor(calibratedRed: 0.09, green: 0.36, blue: 0.82, alpha: 1.0)
    ])!
    grad.draw(in: path, angle: -55)

    // Precision signal wave + node
    NSColor.white.setStroke()
    NSColor(calibratedRed: 0.35, green: 0.94, blue: 0.72, alpha: 1.0).setFill()

    let center = NSPoint(x: s * 0.5, y: s * 0.5)
    let dotR = s * 0.075
    NSBezierPath(ovalIn: NSRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2)).fill()

    for mult in [0.19, 0.30] {
        let r = s * CGFloat(mult)
        let leftArc = NSBezierPath()
        leftArc.lineWidth = max(1.5, s * 0.045)
        leftArc.lineCapStyle = .round
        leftArc.appendArc(withCenter: center, radius: r, startAngle: 135, endAngle: 225)
        leftArc.stroke()

        let rightArc = NSBezierPath()
        rightArc.lineWidth = max(1.5, s * 0.045)
        rightArc.lineCapStyle = .round
        rightArc.appendArc(withCenter: center, radius: r, startAngle: -45, endAngle: 45)
        rightArc.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try png.write(to: URL(fileURLWithPath: (outDir as NSString).appendingPathComponent(name)))
    }
}
SWIFT_ICON
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
rm -rf "$(dirname "${ICONSET_DIR}")"

cat <<EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>StationStudio</string>
    <key>CFBundleIdentifier</key>
    <string>dev.station.studio</string>
    <key>CFBundleName</key>
    <string>Station Studio</string>
    <key>CFBundleDisplayName</key>
    <string>Station Studio</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>4</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
EOF

echo "=== 4. Ad-hoc signing self-contained app bundle ==="
codesign --force --deep --sign - "${APP_DIR}"

echo "=== 5. Building downloadable DMG, ZIP & CLI TAR.GZ in ${RELEASES_DIR} ==="
DMG_NAME="Station-Studio-v${VERSION}-macOS-arm64.dmg"
ZIP_NAME="Station-Studio-v${VERSION}-macOS-arm64.zip"
CLI_TAR="station-cli-v${VERSION}-macos-arm64.tar.gz"

rm -f "${RELEASES_DIR}/${DMG_NAME}" "${RELEASES_DIR}/${ZIP_NAME}" "${RELEASES_DIR}/${CLI_TAR}"

# ZIP archive preserving macOS resource forks & executable permissions
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${RELEASES_DIR}/${ZIP_NAME}"

# Drag-and-drop DMG with /Applications shortcut
STAGE_DMG="$(mktemp -d)"
cp -R "${APP_DIR}" "${STAGE_DMG}/"
ln -s /Applications "${STAGE_DMG}/Applications"
hdiutil create -volname "Station Studio" -srcfolder "${STAGE_DMG}" -ov -format UDZO "${RELEASES_DIR}/${DMG_NAME}" >/dev/null
rm -rf "${STAGE_DMG}"

# Standalone Rust CLI + MCP tarball
tar -C "${DAEMON_DIR}/target/release" -czf "${RELEASES_DIR}/${CLI_TAR}" station

(cd "${RELEASES_DIR}" && shasum -a 256 "${DMG_NAME}" "${ZIP_NAME}" "${CLI_TAR}" > SHA256SUMS.txt)

echo "✔ Packaged self-contained app & release artifacts:"
ls -lh "${RELEASES_DIR}"
cat "${RELEASES_DIR}/SHA256SUMS.txt"
