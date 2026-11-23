# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later

import json
import random
import shutil
import tempfile
import unittest
from pathlib import Path

from blinkheart_pi import fseq, show, usb_import
from blinkheart_pi.dmx import NullOutput, pro_packet
from blinkheart_pi.engine import Engine, blend
from blinkheart_pi.rules import MIDIMessage, Rule, RuleMatcher, decode

FIXTURES = Path(__file__).parent / "fixtures"


def make_show(root: Path, scenes_per_switch=3) -> Path:
    """A show folder from the Mac-made show.json, with simple scenes."""
    folder = root / "blinkheart"
    folder.mkdir(parents=True)
    shutil.copy(FIXTURES / "show.json", folder / "show.json")
    manifest = json.loads((folder / "show.json").read_text())
    for item in manifest["switches"]:
        sub = folder / item["folder"]
        sub.mkdir()
        count = 1 if item["action"] == "reset" else scenes_per_switch
        for n in range(count):
            level = 40 * (n + 1)
            frames = [bytes([level, i * 10] + [0] * 510) for i in range(4)]
            (sub / f"{item['action']} {n + 1}.fseq").write_bytes(fseq.encode(frames, 40))
    return folder


class FSEQTests(unittest.TestCase):
    def test_reads_file_written_by_mac_app(self):
        sequence = fseq.read(FIXTURES / "swift-made.fseq")
        self.assertEqual(sequence.step_ms, 41)
        self.assertEqual(len(sequence.frames), 3)
        self.assertEqual(sequence.channel_count, 512)
        self.assertEqual(sequence.frames[1][:3], bytes([7, 8, 9]))

    def test_round_trip(self):
        frames = [bytes([i] * 512) for i in range(5)]
        sequence = fseq.parse(fseq.encode(frames, 25))
        self.assertEqual(sequence.frames, frames)
        self.assertEqual(sequence.step_ms, 25)

    def test_rejects_other_files(self):
        with self.assertRaises(fseq.FSEQError):
            fseq.parse(b"not a sequence" * 4)


class RuleTests(unittest.TestCase):
    def test_decode(self):
        self.assertEqual(decode([0x9F, 23, 127]), MIDIMessage("noteOn", 16, 23, 127))
        self.assertEqual(decode([0x9F, 23, 0]), MIDIMessage("noteOff", 16, 23, 0))
        self.assertEqual(decode([0xB1, 18, 127]), MIDIMessage("controlChange", 2, 18, 127))
        self.assertIsNone(decode([0xF8]))

    def test_multi_message_rule_in_order_within_timeout(self):
        cc = lambda n, v: MIDIMessage("controlChange", 2, n, v)
        rules = [Rule(4, [cc(18, 127), cc(20, 127)]), Rule(5, [cc(18, 0), cc(20, 127)])]
        matcher = RuleMatcher(timeout=1.5)
        self.assertIsNone(matcher.receive(cc(18, 0), rules, 0.0))
        self.assertEqual(matcher.receive(cc(20, 127), rules, 0.1).switch, 5)
        self.assertIsNone(matcher.receive(cc(18, 127), rules, 1.0))
        self.assertIsNone(matcher.receive(cc(20, 127), rules, 3.0), "timed out")

    def test_mac_rules_round_trip(self):
        manifest = json.loads((FIXTURES / "show.json").read_text())
        first = manifest["switches"][1]["midi"][0]
        self.assertEqual(MIDIMessage.from_json(first), MIDIMessage("noteOn", 16, 23, 127))


class ShowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_load_uses_folder_contents_and_fades(self):
        loaded = show.load(make_show(self.tmp))
        self.assertEqual([s.folder for s in loaded.switches], [f"switch-{n}" for n in range(1, 7)])
        self.assertEqual([s.fade for s in loaded.switches], [0, 2.5, 2.5, 1.5, 0.6, 0.2])
        self.assertEqual(len(loaded.switch(1).scenes), 1)
        self.assertEqual(len(loaded.switch(3).scenes), 3)
        self.assertEqual(loaded.switch(1).mode, "single")

    def test_rejects_non_show(self):
        (self.tmp / "show.json").write_text('{"format": "other"}')
        with self.assertRaises(show.ShowError):
            show.load(self.tmp)

    def test_install_swaps_in_new_show(self):
        source = make_show(self.tmp / "stick")
        home = self.tmp / "home"
        home.mkdir()
        candidate = usb_import.inspect(source)
        self.assertEqual((candidate.switches, candidate.scenes), (6, 16))
        usb_import.install(candidate, home)
        self.assertTrue((home / "show" / "show.json").exists())
        self.assertFalse((home / "show.incoming").exists())
        usb_import.install(candidate, home)  # replacing works too
        self.assertEqual(show.load(home / "show").scene_count, 16)


class AppImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_first_show_loads_without_asking(self):
        import time
        from blinkheart_pi.app import App

        app = App(self.tmp / "home", dmx="null", midi=False, usb=False)
        candidate = usb_import.inspect(make_show(self.tmp / "stick"))
        app._found_show(candidate)
        for _ in range(50):
            if app.engine.show:
                break
            time.sleep(0.05)
        self.assertIsNotNone(app.engine.show)
        self.assertIsNone(app.pending_import)
        # With a show installed, a different one asks first.
        other = usb_import.inspect(candidate.path)
        other.exported = "2030-01-01T00:00:00Z"
        app._found_show(other)
        self.assertIs(app.pending_import, other)


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.now = 100.0
        self.engine = Engine(clock=lambda: self.now, rng=random.Random(4))
        self.engine.load(show.load(make_show(self.tmp)))

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_starts_dark(self):
        self.assertEqual(self.engine.render(), bytes(512))

    def test_random_never_repeats_twice_in_a_row(self):
        picks = [self.engine.press(3).name for _ in range(40)]
        self.assertTrue(all(a != b for a, b in zip(picks, picks[1:])))
        self.assertEqual(len(set(picks)), 3)

    def test_crossfade_uses_switch_fade(self):
        self.engine.press(6)  # Frenzy, 0.2 s
        self.now += 1
        before = self.engine.render()[0]
        self.engine.press(3)  # Low, 2.5 s
        target = self.engine.active_scene.frames[0][0]
        self.now += 1.25
        middle = self.engine.render()[0]
        self.assertAlmostEqual(middle, round((before + target) / 2), delta=1)
        self.now += 1.3
        self.assertEqual(self.engine.render()[0], target)
        self.assertGreaterEqual(self.engine.state().fade_progress, 1)

    def test_scene_loops_at_its_frame_rate(self):
        self.engine.press(4)
        scene = self.engine.active_scene
        self.now += 1.5  # fade done
        frames = []
        for _ in range(6):
            frames.append(self.engine.render()[1])
            self.now += 0.04
        values = [frame[1] for frame in scene.frames]  # 0, 10, 20, 30
        start = values.index(frames[0])
        self.assertEqual(frames, [values[(start + i) % 4] for i in range(6)], "steps through every frame, then repeats")

    def test_reset_is_instant(self):
        self.engine.press(5)
        self.now += 2
        self.engine.press(1)
        self.assertEqual(self.engine.render(), self.engine.active_scene.frames[0])

    def test_pressing_mid_fade_starts_from_current_mix(self):
        self.engine.press(3)
        self.now += 0.5
        mixed = self.engine.render()
        self.engine.press(4)
        self.assertEqual(self.engine.render(), mixed, "no jump when interrupting a fade")

    def test_blend(self):
        self.assertEqual(blend(bytes([0, 200]), bytes([100, 0]), 0.5), bytes([50, 100]))


class DMXTests(unittest.TestCase):
    def test_pro_packet(self):
        packet = pro_packet(bytes(512))
        self.assertEqual(packet[:4], bytes([0x7E, 6, 0x01, 0x02]))
        self.assertEqual(len(packet), 4 + 513 + 1)
        self.assertEqual(packet[-1], 0xE7)

    def test_null_output(self):
        out = NullOutput()
        out.send(b"\x01")
        self.assertEqual(out.last, b"\x01")


if __name__ == "__main__":
    unittest.main()
