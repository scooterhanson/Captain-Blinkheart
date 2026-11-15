// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
import SceneBridgeCore

final class SceneSelectionTests: XCTestCase {
    func testSceneActionDisplayNamesMatchPedalActions() {
        XCTAssertEqual(
            SceneAction.allCases.map(\.title),
            ["Reset", "Random Low", "Random Medium", "Random High", "Random Frenzy", "Intro"]
        )
        XCTAssertEqual(
            SceneAction.allCases.map(\.energy),
            ["Reset", "Low", "Medium", "High", "Frenzy", "Intro"]
        )
    }

    func testDefaultCueNamesUseIntroAndFrenzy() {
        XCTAssertEqual(AppConfiguration.default.cues(for: .baseline).map(\.name), ["Intro"])
        XCTAssertEqual(
            AppConfiguration.default.scenes["critical"]?.map(\.name),
            ["Frenzy 1", "Frenzy 2", "Frenzy 3"]
        )
    }

    func testRandomSelectionAvoidsRepeatingPreviousCueWhenAlternativesExist() {
        let cues = [
            MIDICue(id: "one", name: "One", note: 48, velocity: 100),
            MIDICue(id: "two", name: "Two", note: 50, velocity: 100)
        ]

        let selected = SceneSelector.select(from: cues, avoiding: "one") { $0.lowerBound }

        XCTAssertEqual(selected?.id, "two")
    }

    func testEveryRandomDrawSelectsAValidNonrepeatingCue() {
        let cues = [
            MIDICue(id: "one", name: "One", note: 48, velocity: 100),
            MIDICue(id: "two", name: "Two", note: 50, velocity: 100),
            MIDICue(id: "three", name: "Three", note: 52, velocity: 100)
        ]

        for draw in 0..<2 {
            let selected = SceneSelector.select(from: cues, avoiding: "one") { range in
                XCTAssertEqual(range, 0..<2)
                return draw
            }
            XCTAssertNotEqual(selected?.id, "one")
        }
    }

    func testSelectionCanRepeatWhenOnlyOneCueExists() {
        let cue = MIDICue(id: "only", name: "Only", note: 48, velocity: 100)

        XCTAssertEqual(SceneSelector.select(from: [cue], avoiding: cue.id) { $0.lowerBound }, cue)
    }

    func testSelectionReturnsNilForEmptyGroup() {
        XCTAssertNil(SceneSelector.select(from: [], avoiding: nil) { $0.lowerBound })
    }

    func testBundledMIDIConfigurationDecodesToSixButtonProfile() throws {
        let configuration = try ConfigurationStore.bundledProfile()

        XCTAssertEqual(configuration.rules.count, 6)
        XCTAssertEqual(configuration.rules.map(\.button), Array(0...5))
        XCTAssertEqual(
            configuration.rules.map(\.action),
            [.reset, .baseline, .low, .medium, .high, .critical]
        )
        XCTAssertEqual(configuration.rules[0].messages.count, 3)
        XCTAssertEqual(configuration.rules[3].messages.count, 2)
    }

    func testMIDISequenceMatcherFiresOnlyAfterAllMessagesArriveInOrder() throws {
        let configuration = try ConfigurationStore.bundledProfile()
        var matcher = MIDIRuleMatcher()
        let resetMessages = configuration.rules[0].messages

        XCTAssertNil(matcher.receive(resetMessages[0], rules: configuration.rules, at: 1))
        XCTAssertNil(matcher.receive(resetMessages[1], rules: configuration.rules, at: 1.1))
        XCTAssertEqual(
            matcher.receive(resetMessages[2], rules: configuration.rules, at: 1.2)?.action,
            .reset
        )
    }

    func testMIDISequenceMatcherRequiresConfiguredChannelAndValue() throws {
        let configuration = try ConfigurationStore.bundledProfile()
        var matcher = MIDIRuleMatcher()
        let expected = configuration.rules[3].messages
        let wrongChannel = MIDIInputMessage(
            kind: .controlChange,
            channel: 3,
            number: expected[0].number,
            value: expected[0].value
        )

        XCTAssertNil(matcher.receive(wrongChannel, rules: configuration.rules, at: 1))
        XCTAssertNil(matcher.receive(expected[1], rules: configuration.rules, at: 1.1))
        XCTAssertEqual(matcher.receive(expected[0], rules: configuration.rules, at: 1.2), nil)
        XCTAssertEqual(
            matcher.receive(expected[1], rules: configuration.rules, at: 1.3)?.action,
            .medium
        )
    }

    func testMIDISequenceMatcherSurvivesRuleEditsDuringPartialSequence() {
        var matcher = MIDIRuleMatcher()
        let first = MIDIInputMessage(kind: .controlChange, channel: 2, number: 18, value: 127)
        let second = MIDIInputMessage(kind: .controlChange, channel: 2, number: 20, value: 127)
        let original = PedalRule(button: 3, label: "Key 3", messages: [first, second], action: .high)
        let shortened = PedalRule(button: 3, label: "Key 3", messages: [first], action: .high)

        XCTAssertNil(matcher.receive(first, rules: [original], at: 1))
        XCTAssertEqual(matcher.receive(first, rules: [shortened], at: 1.1)?.action, .high)
    }

    func testLegacyCCConfigurationStillDecodes() throws {
        let json = """
        {"button":1,"ccNumber":20,"triggerValue":127,"action":"reset"}
        """

        let rule = try JSONDecoder().decode(PedalRule.self, from: Data(json.utf8))

        XCTAssertEqual(
            rule.messages,
            [MIDIInputMessage(kind: .controlChange, channel: 1, number: 20, value: 127)]
        )
    }

    func testImportedTextProfileHasMixedChannelsAndMessageTypes() throws {
        let rules = try MIDICaptainProfileParser.parse("""
        [key0]
        short_dw1 = [16][NT][00][127] [15][CC][35][127] [15][CC][30][3]
        [key1]
        short_dw1 = [2][CC][18][127] [2][CC][20][127]
        """)

        XCTAssertEqual(rules.map(\.action), [.reset, .baseline])
        XCTAssertEqual(rules[0].messages.map(\.channel), [16, 15, 15])
        XCTAssertEqual(rules[0].messages.map(\.kind), [.noteOn, .controlChange, .controlChange])
        XCTAssertEqual(rules[1].messages.count, 2)
    }

    func testEveryActionHasAConfigurableCueList() {
        for action in SceneAction.allCases {
            XCTAssertFalse(AppConfiguration.default.cues(for: action).isEmpty, action.rawValue)
        }
        XCTAssertEqual(Set(SceneAction.displayOrder), Set(SceneAction.allCases))
    }

    func testLegacySingleResetAndIntroCuesMigrateToLists() throws {
        let json = """
        {
          "inputChannel": 1, "outputChannel": 1, "rules": [],
          "resetCue": {"id": "reset", "name": "Reset / All Off", "note": 36, "velocity": 127},
          "baselineCue": {"id": "baseline", "name": "Intro", "note": 37, "velocity": 100},
          "scenes": {"low": [{"id": "low-1", "name": "Low 1", "note": 48, "velocity": 100}]}
        }
        """

        let configuration = try ConfigurationStore.decode(Data(json.utf8))

        XCTAssertEqual(configuration.cues(for: .reset).map(\.note), [36])
        XCTAssertEqual(configuration.cues(for: .baseline).map(\.note), [37])
        XCTAssertEqual(configuration.cues(for: .low).map(\.note), [48])
        XCTAssertEqual(configuration.outputTarget, .midiPort)
        XCTAssertNil(configuration.pluginState)
    }

    func testConfigurationRoundTripsCueListsAndPluginSettings() throws {
        var configuration = AppConfiguration.default
        configuration.scenes["reset"]?.append(MIDICue(id: "reset-2", name: "Reset 2", note: 40, velocity: 127))
        configuration.outputTarget = .hostedPlugin
        configuration.pluginComponent = .showBuddyActive
        configuration.pluginState = Data([1, 2, 3])

        let decoded = try ConfigurationStore.decode(ConfigurationStore.encode(configuration))

        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.cues(for: .reset).count, 2)
    }

    func testFourCharCodesRoundTrip() {
        let id = PluginComponentID.showBuddyActive
        XCTAssertEqual(FourCharCode.value("aumf"), 0x61756D66)
        XCTAssertEqual(FourCharCode.string(id.subtypeCode), "DmpP")
        XCTAssertTrue(id.matches(
            type: FourCharCode.value("aumf"),
            subtype: FourCharCode.value("DmpP"),
            manufacturer: FourCharCode.value("dBau")
        ))
    }

    func testSettingsExportOmitsPluginAndImportKeepsCurrentPlugin() throws {
        var current = AppConfiguration.default
        current.pluginComponent = .showBuddyActive
        current.pluginState = Data([1, 2, 3])
        current.inputUniqueID = 111

        let exported = try ConfigurationStore.exportSettings(current)
        XCTAssertNil(try ConfigurationStore.decode(exported).pluginState)

        var incoming = AppConfiguration.default
        incoming.rules[0].label = "Imported Key"
        incoming.outputChannel = 9
        let merged = try ConfigurationStore.importSettings(
            ConfigurationStore.exportSettings(incoming),
            into: current
        )

        XCTAssertEqual(merged.rules[0].label, "Imported Key")
        XCTAssertEqual(merged.outputChannel, 9)
        XCTAssertEqual(merged.pluginState, Data([1, 2, 3]))
        XCTAssertEqual(merged.inputUniqueID, 111)
    }
}
