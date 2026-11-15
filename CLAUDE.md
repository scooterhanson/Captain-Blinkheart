# Captain Blinkheart

## Intent

Captain Blinkheart is a macOS bridge between a MIDI Captain MINI6 pedal and
ShowBuddy Active. It translates configured pedal messages into MIDI note
commands for lighting scenes. Every action (Reset, Intro, Low, Medium, High,
Frenzy) picks randomly from its own list of output notes. Cues go either to a
CoreMIDI destination or to a Show Buddy Active Audio Unit hosted in the app. The application also provides a live visual
action indicator, an in/out command log, editable MIDI mappings, and
configuration file loading and saving.

The bundled MIDI Captain text profile documents the six-button layout and LED
feedback. Its key actions are parsed into the app's initial rules, keeping the
physical controller setup and software behavior aligned.

## Architectural approach

- **SwiftUI application layer:** `SceneBridgeApp` and `ContentView` provide the
  macOS window, persistent MIDI routing controls, the Main, MIDI Captain, MIDI Out, and
  Show Buddy tabs, and configuration-file dialogs.
- **Application model:** `AppModel` owns the active configuration and display
  state. It coordinates MIDI input, matches incoming messages to configured
  rules, selects cues, sends output notes, records log entries, and persists
  configuration.
- **Plugin host:** `PluginHost` instantiates an Audio Unit (Show Buddy
  Active, `aumf DmpP dBau`, by default) in an `AVAudioEngine`, feeds a music
  effect silence so it renders, delivers cue notes through its MIDI event
  block, shows its Cocoa/AUv3 editor in the Show Buddy tab, and saves/restores
  `fullState` into the configuration's `pluginState`.
- **CoreMIDI service:** `MIDIService` discovers and connects MIDI endpoints,
  decodes incoming MIDI 1.0 event-list packets, and sends note-on/note-off
  messages to the selected destination.
- **Reusable core logic:** `SceneBridgeCore` contains platform-independent
  configuration and cue models, MIDI Captain text parsing, ordered
  multi-message rule matching, and random scene selection. This keeps the
  behavior independently testable and separate from the SwiftUI presentation.
- **Configuration sources:** The bundled plain-text pedal profile supplies
  the initial button mappings. JSON configuration files store the editable
  rules, MIDI endpoints, output channel, and scene notes. The app remembers the
  last loaded or saved JSON file and also maintains an automatic recovery copy.
- **Distribution:** `scripts/build-app.sh` builds arm64 and x86_64 versions
  targeting macOS 12.0, combines them into a universal application, and
  verifies both architectures. The resulting app can be packaged as a macOS
  installer.

## Design philosophy

- **Keep controller input explicit.** Rules match MIDI message kind, channel,
  number, and value; multi-message buttons must arrive in order within a short
  timeout. This makes the pedal's behavior inspectable and editable rather
  than embedding assumptions in the input handler.
- **Separate physical controls from scene mappings.** The pedal selects an
  action, while the app maps that action to one or more ShowBuddy notes. Scene
  lists can therefore change without changing the pedal profile.
- **Make state visible.** The Main tab emphasizes the last matched action with
  its color, while the command log shows incoming messages, rule matches, and
  outgoing MIDI activity.
- **Make configuration recoverable.** Users can load, save, and save as JSON
  files; automatic persistence provides a fallback if the last-used file is
  unavailable.
- **Favor a small, native, portable implementation.** SwiftUI and CoreMIDI
  avoid external runtime dependencies. The universal build preserves support
  for both Intel and Apple silicon Macs, including macOS 12.0 and later.


# AU TYPE
aumf