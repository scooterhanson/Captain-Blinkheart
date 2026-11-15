// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// A custom About window that shows the app icon much larger than the
/// standard About panel's fixed-size icon.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(rootView: AboutView())
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Captain Blinkheart"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

private struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where build != short: return "Version \(short) (\(build))"
        case let (short?, _): return "Version \(short)"
        default: return "Development build"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 256, height: 256)
            Text("Captain Blinkheart")
                .font(.title.bold())
            Text(version)
                .foregroundStyle(.secondary)
            Text("MIDI pedal control for ShowBuddy Active")
                .font(.callout)
        }
        .padding(.horizontal, 48)
        .padding(.top, 12)
        .padding(.bottom, 32)
    }
}
