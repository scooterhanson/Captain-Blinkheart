// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

@main
struct SceneBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Captain Blinkheart") {
            ContentView(model: model)
                .frame(minWidth: 880, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .importExport) {
                Button("Import Pedal & MIDI Settings…") {
                    model.presentImportSettings()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export Pedal & MIDI Settings…") {
                    model.presentExportSettings()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Captain Blinkheart") {
                    AboutWindow.show()
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Show Configuration File") {
                    model.revealConfiguration()
                }
            }
        }
    }
}
