import AppKit
import Darwin

/// Regenerates the app icon for the selected listening theme: the walkie-talkie
/// on the theme's plate, lit in the theme's colors.
///
/// The running process gets the new image immediately, while Finder and
/// Launchpad read the bundle's AppIcon.icns. Rewriting it breaks the code seal,
/// so the bundle is re-signed with the same identity scheme as make-app.sh; a
/// marker file tracks which theme the baked icon belongs to (reinstalls reset
/// it). Avoid NSWorkspace's custom-icon API here: its Finder xattrs make strict
/// code-sign validation fail even after the bundle is re-signed.
enum ThemeIcon {
    // Serial so rapid theme changes never run two `codesign --force` passes on
    // our own bundle at once (a torn signature drops the app's TCC grants).
    private static let queue = DispatchQueue(label: "app.talix.localflow.themeicon")
    private static let pendingLock = NSLock()
    // Every access is protected by pendingLock. Swift cannot infer lock-based
    // isolation, so make that synchronization contract explicit.
    nonisolated(unsafe) private static var pendingTheme: HudTheme?

    /// Fire-and-forget: generation runs off the main thread, application on it.
    /// Jobs coalesce — only the latest requested theme is applied; stale ones skip.
    @MainActor
    static func apply(_ theme: HudTheme) {
        pendingLock.lock()
        pendingTheme = theme
        pendingLock.unlock()
        queue.async {
            pendingLock.lock()
            let latest = pendingTheme
            pendingLock.unlock()
            guard latest == theme else { return } // superseded by a newer request
            // The bundle already supplies the right icon on normal launches.
            // Rendering a 1024 px replacement is only needed after a theme
            // change (or under `swift run`, where there is no app bundle).
            if bundledThemeMatches(theme) { return }
            guard let cgImage = compose(theme) else { return }
            let icon = NSImage(cgImage: cgImage, size: NSSize(width: 512, height: 512))
            DispatchQueue.main.async {
                NSApp.applicationIconImage = icon
            }
            syncBundleIcon(theme, cgImage)
        }
    }

    // MARK: Bundle icon (what Launchpad shows)

    private static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    private static func bundledThemeMatches(_ theme: HudTheme) -> Bool {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { return false }
        return bakedTheme(in: bundlePath) == theme.rawValue
    }

    private static func bakedTheme(in bundlePath: String) -> String {
        let markerPath = bundlePath + "/Contents/Resources/ThemeIcon.marker"
        let baked = (try? String(contentsOfFile: markerPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? HudTheme.classic.rawValue
        return baked
    }

    private static func syncBundleIcon(_ theme: HudTheme, _ image: CGImage) {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { return }
        let resources = bundlePath + "/Contents/Resources"
        let markerPath = resources + "/ThemeIcon.marker"
        // A fresh install ships the classic icon and no marker.
        let baked = bakedTheme(in: bundlePath)
        guard baked != theme.rawValue else { return }
        guard FileManager.default.isWritableFile(atPath: resources) else {
            DiagLog.log("bundle not writable — Launchpad icon left as-is")
            return
        }
        // Distributed builds are left alone when quarantined or when this
        // machine lacks their signing key: re-signing invalidates the stapled
        // notarization ticket, which Gatekeeper re-checks for quarantined
        // apps. A developer's own non-quarantined copy is re-signed with the
        // same Developer ID identity, preserving its designated requirement
        // and TCC grants. The running app still shows the themed icon via
        // NSApp.applicationIconImage.
        guard canSafelyResign(bundlePath) else {
            DiagLog.log("release-signed bundle — leaving the Launchpad icon alone")
            return
        }
        // The rewrite and re-sign must be transactional: bundle contents
        // that don't match the seal make validation fail and macOS silently
        // drops the app's Microphone/Accessibility grants. Both the icns AND
        // the marker are sealed resources, so both go in before signing and
        // both roll back if the sign/verify fails (identical restored bytes
        // mean the previous seal is valid again). A failed rebake is
        // retried on the next apply because the marker was rolled back too.
        // Backups live OUTSIDE the bundle: anything left inside Resources
        // while codesign runs would itself be sealed, and deleting it
        // afterwards would tear the seal all over again.
        let fm = FileManager.default
        let icnsPath = resources + "/AppIcon.icns"
        let markerExisted = fm.fileExists(atPath: markerPath)
        let backupDir = fm.temporaryDirectory
            .appendingPathComponent("LocalFlowIconBackup-\(UUID().uuidString)").path
        try? fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let icnsBackup = backupDir + "/AppIcon.icns"
        let markerBackup = backupDir + "/ThemeIcon.marker"
        try? fm.removeItem(atPath: icnsBackup)
        try? fm.copyItem(atPath: icnsPath, toPath: icnsBackup)
        try? fm.removeItem(atPath: markerBackup)
        if markerExisted { try? fm.copyItem(atPath: markerPath, toPath: markerBackup) }
        // No verified backup, no rebake: without one, a later failure has
        // nothing to roll back to and the bundle would stay torn.
        let icnsBackedUp = !fm.fileExists(atPath: icnsPath) || fm.fileExists(atPath: icnsBackup)
        let markerBackedUp = !markerExisted || fm.fileExists(atPath: markerBackup)
        guard icnsBackedUp, markerBackedUp else {
            try? fm.removeItem(atPath: backupDir)
            DiagLog.log("could not back up current icon, leaving bundle untouched")
            return
        }
        func restorePrevious() {
            if fm.fileExists(atPath: icnsBackup) {
                try? fm.removeItem(atPath: icnsPath)
                try? fm.copyItem(atPath: icnsBackup, toPath: icnsPath)
            }
            try? fm.removeItem(atPath: markerPath)
            if markerExisted { try? fm.copyItem(atPath: markerBackup, toPath: markerPath) }
        }
        defer { try? fm.removeItem(atPath: backupDir) }

        guard writeIcns(image, to: icnsPath) else {
            restorePrevious()
            DiagLog.log("icon write failed, bundle icon left as-is")
            return
        }
        try? theme.rawValue.write(toFile: markerPath, atomically: true, encoding: .utf8)
        guard resign(bundlePath) else {
            restorePrevious()
            // Best effort: the failed attempt may have left a seal that no
            // longer matches the restored bytes; try once to reseal them.
            _ = resign(bundlePath)
            DiagLog.log("re-sign failed, previous icon restored; will retry on the next theme change")
            return
        }
        // Nudge LaunchServices/iconservices to pick the new icon up.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: bundlePath)
        _ = run(lsregister, ["-f", bundlePath])
        DiagLog.log("bundle icon rebaked for theme %@", theme.rawValue)
    }

    /// Same signing scheme as make-app.sh: the stable self-signed identity if
    /// present, else ad-hoc with the pinned identifier requirement — either
    /// way the designated requirement keeps the active app identifier,
    /// so TCC grants survive the rewrite.
    /// True when this machine can reproduce the existing seal without
    /// affecting Gatekeeper or TCC: ad-hoc, the local development identity,
    /// or a non-quarantined Developer ID bundle whose exact identity is in
    /// the keychain. Distributed builds without that key, and quarantined
    /// distributed builds, are left alone.
    private static func canSafelyResign(_ bundlePath: String) -> Bool {
        guard let authority = signingAuthority(bundlePath) else {
            // No authority line: ad-hoc. Nothing to invalidate.
            return true
        }
        let identities = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).1
        if authority == localSigningIdentity {
            return identities.contains(localSigningIdentity)
        }
        guard authority.hasPrefix("Developer ID Application:") else { return false }
        guard identities.contains(authority) else {
            DiagLog.log("Developer ID signing identity not in keychain, leaving the Launchpad icon alone")
            return false
        }
        guard !hasQuarantineAttribute(bundlePath) else {
            DiagLog.log("quarantined Developer ID bundle, leaving the Launchpad icon alone")
            return false
        }
        return true
    }

    private static let localSigningIdentity = "Talix Dev Signing"

    private static func signingAuthority(_ bundlePath: String) -> String? {
        run("/usr/bin/codesign", ["-dvv", bundlePath]).1
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
    }

    private static func hasQuarantineAttribute(_ bundlePath: String) -> Bool {
        bundlePath.withCString { path in
            "com.apple.quarantine".withCString { name in
                let result = getxattr(path, name, nil, 0, 0, 0)
                return result != -1 || errno != ENOATTR
            }
        }
    }

    private static func resign(_ bundlePath: String) -> Bool {
        let (_, identities) = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        let result: (Int32, String)
        let authority = signingAuthority(bundlePath)
        if let authority, authority.hasPrefix("Developer ID Application:"), identities.contains(authority) {
            result = run("/usr/bin/codesign", [
                "--force", "--sign", authority,
                "--identifier", AppIdentity.current.bundleIdentifier,
                "--preserve-metadata=entitlements,requirements,flags,runtime",
                "--timestamp=none", bundlePath,
            ])
        } else if identities.contains("Talix Dev Signing") {
            result = run("/usr/bin/codesign", [
                "--force", "--sign", "Talix Dev Signing",
                "--identifier", AppIdentity.current.bundleIdentifier, bundlePath,
            ])
        } else if authority == localSigningIdentity {
            // The bundle carries the certificate-backed identity but the
            // keychain can't produce it right now (locked, transient error).
            // Downgrading to ad-hoc would change the designated requirement
            // and orphan the TCC grants; fail and let the rollback run.
            DiagLog.log("signing identity unavailable, refusing to downgrade the bundle to ad-hoc")
            return false
        } else {
            result = run("/usr/bin/codesign", [
                "--force", "--sign", "-",
                "--identifier", AppIdentity.current.bundleIdentifier,
                "-r=designated => identifier \"\(AppIdentity.current.bundleIdentifier)\"", bundlePath,
            ])
        }
        if result.0 != 0 {
            DiagLog.log("re-sign after icon rebake failed: %@", result.1)
            return false
        }
        // Trust the verifier, not codesign's exit status alone: this seal
        // is what stands between the app and losing its TCC grants.
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", bundlePath])
        if verify.0 != 0 {
            DiagLog.log("re-signed bundle fails verification: %@", verify.1)
            return false
        }
        return true
    }

    private static func writeIcns(_ image: CGImage, to icnsPath: String) -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("LocalFlowIcon-\(UUID().uuidString)")
        let iconset = tmp.appendingPathComponent("AppIcon.iconset")
        do {
            try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        } catch {
            return false
        }
        defer { try? fm.removeItem(at: tmp) }

        let entries: [(Int, String)] = [
            (16, "icon_16x16"), (32, "icon_16x16@2x"),
            (32, "icon_32x32"), (64, "icon_32x32@2x"),
            (128, "icon_128x128"), (256, "icon_128x128@2x"),
            (256, "icon_256x256"), (512, "icon_256x256@2x"),
            (512, "icon_512x512"), (1024, "icon_512x512@2x"),
        ]
        for (size, name) in entries {
            let url = iconset.appendingPathComponent("\(name).png")
            guard let scaled = scale(image, to: size),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                return false
            }
            CGImageDestinationAddImage(dest, scaled, nil)
            guard CGImageDestinationFinalize(dest) else { return false }
        }
        let (status, output) = run("/usr/bin/iconutil", ["-c", "icns", "-o", icnsPath, iconset.path])
        if status != 0 {
            DiagLog.log("iconutil failed: %@", output)
            return false
        }
        return true
    }

    private static func scale(_ image: CGImage, to size: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    private static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // Drain the pipe before waiting: a chatty child can otherwise fill the
        // buffer and block on write while we block on exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Dark plate gradient per theme, matching each design's world.
    private static func backdrop(_ theme: HudTheme) -> (HudColor, HudColor) {
        switch theme {
        case .classic: return (HudColor("#1A1F40"), HudColor("#0D2B33"))
        case .typeset: return (HudColor("#241318"), HudColor("#140D0A"))
        case .aurora: return (HudColor("#0A1220"), HudColor("#060A12"))
        case .bolide: return (HudColor("#191024"), HudColor("#0B0A14"))
        case .mercury: return (HudColor("#1B1F2C"), HudColor("#101319"))
        case .liquidGlass: return (HudColor("#18232D"), HudColor("#0B1118"))
        case .ticker: return (HudColor("#1E2128"), HudColor("#101216"))
        case .constellation: return (HudColor("#0D1428"), HudColor("#05070E"))
        case .loom: return (HudColor("#221418"), HudColor("#120C0E"))
        case .vapor: return (HudColor("#131C22"), HudColor("#0A0F14"))
        case .sonar: return (HudColor("#07202E"), HudColor("#04121C"))
        case .shorthand: return (HudColor("#151936"), HudColor("#0B0D18"))
        case .prism: return (HudColor("#1B1D26"), HudColor("#0D0E13"))
        case .murmuration: return (HudColor("#241B38"), HudColor("#5A3038")) // dusk
        case .filament: return (HudColor("#0E1322"), HudColor("#07080F"))
        case .bloom: return (HudColor("#1A2414"), HudColor("#0C1108"))
        case .pianola: return (HudColor("#241610"), HudColor("#120B07"))
        }
    }

    /// Screen-glow and radio-wave colors per theme, from each theme's palette.
    private static func waveColors(_ theme: HudTheme) -> (HudColor, HudColor) {
        switch theme {
        case .classic: return (HudColor("#40DED1"), HudColor("#C285F2"))
        case .typeset: return (HudColor("#FFD68C"), HudColor("#FFC46B"))
        case .aurora: return (HudColor("#3AF0A0"), HudColor("#D96BFF"))
        case .bolide: return (HudColor("#FFC46B"), HudColor("#FF8FB8"))
        case .mercury: return (HudColor("#FF8FB8"), HudColor("#C77BFF"))
        case .liquidGlass: return (HudColor("#EDE7DA"), HudColor("#9ADCE8"))
        case .ticker: return (HudColor("#FF4D3D"), HudColor("#FF8A7A"))
        case .constellation: return (HudColor("#FFE9B8"), HudColor("#FFF4D6"))
        case .loom: return (HudColor("#E8DFC8"), HudColor("#E8BC66"))
        case .vapor: return (HudColor("#45E8D0"), HudColor("#9ADCE8"))
        case .sonar: return (HudColor("#45E8D0"), HudColor("#DCFFF6"))
        case .shorthand: return (HudColor("#6BE8F0"), HudColor("#DCFAFC"))
        case .prism: return (HudColor("#FF6B6B"), HudColor("#B57BFF"))
        case .murmuration: return (HudColor("#FFB98A"), HudColor("#6BB8FF"))
        case .filament: return (HudColor("#6BB8FF"), HudColor("#E8A25E"))
        case .bloom: return (HudColor("#7ADB8F"), HudColor("#FFD37A"))
        case .pianola: return (HudColor("#E8BC66"), HudColor("#F2E8CF"))
        }
    }

    /// Writes the 1024 px icon for `theme` as a PNG. scripts/make-icon.sh
    /// uses it (through `--render-app-icon`) to build Resources/AppIcon.icns.
    static func writePNG(_ theme: HudTheme, to path: String) -> Bool {
        guard let image = compose(theme),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Every theme's icon is the Walkie walkie-talkie on that theme's plate,
    /// with its screen glow and radio waves in the theme's colors.
    private static func compose(_ theme: HudTheme, canvas S: CGFloat = 1024) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: Int(S), height: Int(S),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Apple margin: ~10% inset, ~22.5% corner radius.
        let inset = S * 0.098
        let plate = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
        let radius = plate.width * 0.225
        let squircle = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

        let (top, bottom) = backdrop(theme)
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: S), to: CGPoint(x: S * 0.25, y: 0),
                          stops: [(0, top.cg(1)), (1, bottom.cg(1))], clippedTo: squircle)

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        hudRadialGlow(ctx, center: CGPoint(x: plate.midX, y: plate.midY),
                      radius: plate.width * 0.62, stops: [
                          (0, CGColor(gray: 1, alpha: 0.07)),
                          (1, CGColor(gray: 1, alpha: 0)),
                      ])
        // The walkie is laid out y-down; flip once.
        ctx.translateBy(x: 0, y: S)
        ctx.scaleBy(x: 1, y: -1)
        drawWalkie(theme, ctx, S)
        ctx.restoreGState()

        // Hairline inner edge to lift the plate off light backgrounds.
        ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 3, dy: 3),
                           cornerWidth: radius - 3, cornerHeight: radius - 3, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
        ctx.setLineWidth(6 * S / 1024)
        ctx.strokePath()

        return ctx.makeImage()
    }

    // MARK: Walkie-talkie (drawn y-down)

    private static func drawWalkie(_ theme: HudTheme, _ ctx: CGContext, _ S: CGFloat) {
        // Same layout as the menubar icon: antenna top left, push-to-talk
        // button on the left edge, waves leaving the right side. Drawn at
        // 90% about the center so it clears the plate edges.
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: S / 2, y: S / 2 + S * 0.01)
        ctx.scaleBy(x: 0.9, y: 0.9)
        ctx.translateBy(x: -S / 2, y: -S / 2)
        let dx = -0.035 * S
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * S + dx, y: y * S, width: w * S, height: h * S)
        }
        let body = r(0.27, 0.30, 0.34, 0.56)
        let bodyPath = CGPath(roundedRect: body, cornerWidth: S * 0.075, cornerHeight: S * 0.075, transform: nil)
        let antenna = roundedRect(0.33 * S + dx, 0.12 * S, 0.056 * S, 0.22 * S, 0.028 * S)
        let button = roundedRect(0.235 * S + dx, 0.43 * S, 0.06 * S, 0.13 * S, 0.016 * S)
        let screen = r(0.31, 0.36, 0.26, 0.20)
        let screenPath = CGPath(roundedRect: screen, cornerWidth: S * 0.032, cornerHeight: S * 0.032, transform: nil)

        // Radio waves first, so their glow sits behind the body.
        let (inner, outer) = waveColors(theme)
        let center = CGPoint(x: body.maxX + S * 0.01, y: S * 0.40)
        for (radius, alpha) in [(0.12, 1.0), (0.21, 0.8)] as [(CGFloat, CGFloat)] {
            let arc = CGMutablePath()
            arc.addArc(center: center, radius: radius * S, startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: S * 0.04, color: inner.cg(0.55 * alpha))
            ctx.addPath(arc)
            ctx.setLineWidth(S * 0.046)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(inner.cg(alpha))
            ctx.strokePath()
            ctx.restoreGState()
            strokeGradient(ctx, arc, width: S * 0.046,
                           from: CGPoint(x: center.x, y: center.y - radius * S),
                           to: CGPoint(x: center.x, y: center.y + radius * S),
                           stops: [(0, inner.cg(alpha)), (1, outer.cg(alpha))])
        }

        // Cream shell with a soft drop shadow.
        let shell = CGMutablePath()
        shell.addPath(bodyPath)
        shell.addPath(antenna)
        shell.addPath(button)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: S * 0.018), blur: S * 0.05, color: CGColor(gray: 0, alpha: 0.5))
        ctx.addPath(shell)
        ctx.setFillColor(HudColor("#E9E3D8").cg(1))
        ctx.fillPath()
        ctx.restoreGState()
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: S * 0.12), to: CGPoint(x: 0, y: body.maxY), stops: [
            (0, HudColor("#FBF8F2").cg(1)), (1, HudColor("#D6CEC0").cg(1)),
        ], clippedTo: shell)

        // Screen: a dark inset panel lit faintly in the theme's color.
        ctx.saveGState()
        ctx.addPath(screenPath)
        ctx.clip()
        ctx.setFillColor(HudColor("#0E0E12").cg(1))
        ctx.fill(screen)
        hudRadialGlow(ctx, center: CGPoint(x: screen.midX, y: screen.midY), radius: screen.width * 0.6, stops: [
            (0, inner.cg(0.28)), (1, inner.cg(0)),
        ])
        ctx.restoreGState()
        // Glass sheen and a recessed edge.
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: screen.minY), to: CGPoint(x: 0, y: screen.midY), stops: [
            (0, CGColor(gray: 1, alpha: 0.10)), (1, CGColor(gray: 1, alpha: 0)),
        ], clippedTo: screenPath)
        ctx.addPath(screenPath)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
        ctx.setLineWidth(S * 0.008)
        ctx.strokePath()

        // Speaker grille.
        ctx.setFillColor(HudColor("#7D7466").cg(0.55))
        for y in [0.635, 0.695, 0.755] as [CGFloat] {
            ctx.addPath(roundedRect(0.335 * S + dx, y * S, 0.21 * S, 0.026 * S, 0.013 * S))
            ctx.fillPath()
        }
    }

    // MARK: Drawing helpers

    private static func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
               cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil)
    }

    /// Stroke a path with a linear gradient (stroke → clip → gradient).
    private static func strokeGradient(_ ctx: CGContext, _ path: CGPath, width: CGFloat,
                                       from: CGPoint, to: CGPoint, stops: [(CGFloat, CGColor)]) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        hudLinearGradient(ctx, from: from, to: to, stops: stops)
        ctx.restoreGState()
    }

}
