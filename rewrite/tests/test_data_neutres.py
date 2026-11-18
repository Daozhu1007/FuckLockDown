"""Static validation of the pinned dataNeutres section against the original payload.

The production plan ships an EMPTY neutre set by measurement (2026-11-18/19,
lab/reports/neutre-matrix*.json): the beta/gamma/ptc4 needle regions are
covered by a region-level integrity self-check, and the alpha entries are
state-dependently lethal once the browser enters its auto-launch flow. The
empty-set test pins that decision; the byte-level checks below re-apply
automatically when entries are reintroduced.
"""

import json
from pathlib import Path
import unittest

import pefile

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = (ROOT.parent / "analysis/lockdown-2.1.6.03/payload/ProgramFiles64Folder/"
           "Respondus/LockDown Browser/LockDownBrowser.exe")
PLAN = ROOT / "plans/lockdown-2.1.6.03-core.json"


def unhex(value):
    return bytes.fromhex(value.replace(" ", ""))


class DataNeutrePlan(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not PAYLOAD.is_file():
            raise unittest.SkipTest("original payload not present; static neutre checks need the pinned build")
        cls.plan = json.loads(PLAN.read_text(encoding="utf-8"))
        cls.payload = pefile.PE(str(PAYLOAD), fast_load=True)

    def section_of(self, rva):
        for section in self.payload.sections:
            if section.VirtualAddress <= rva < section.VirtualAddress + max(section.Misc_VirtualSize, section.SizeOfRawData):
                return section
        return None

    def test_plan_ships_an_empty_neutre_set_by_measurement(self):
        """Zero neutres in production, with the measured rationale recorded.

        Every candidate group was tried in the lab: the beta/gamma/ptc4
        needle regions trip a region-level integrity self-check (any single
        byte, any early timing, exit 1 within ~10 s), and the alpha names
        plus the process.list key spec are state-dependently lethal once the
        browser enters its auto-launch flow. Shipping them would put user
        exam sessions at risk, so the set is empty and the machinery stays.
        """
        self.assertEqual(self.plan["dataNeutres"], [])
        self.assertIn("Empty by measurement", self.plan["dataNeutresNote"])
        self.assertFalse(self.plan.get("dataNeutresAllowExecutableSection", False))

    def test_every_neutre_matches_payload_bytes_in_data_sections(self):
        neutres = self.plan["dataNeutres"]
        if not neutres:
            self.skipTest("empty production set; byte checks apply when entries return")
        ranges = []
        patch_ids = [p["id"] for p in self.plan["patches"]]
        ids = [n["id"] for n in neutres]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertFalse(set(ids) & set(patch_ids))
        for neutre in neutres:
            expected, replacement = unhex(neutre["expected"]), unhex(neutre["replacement"])
            self.assertEqual(len(expected), len(replacement), neutre["id"])
            self.assertNotEqual(expected, replacement, neutre["id"])
            rva = int(neutre["rva"], 16)
            section = self.section_of(rva)
            self.assertIsNotNone(section, neutre["id"])
            self.assertFalse(section.Characteristics & 0x20000000,
                             neutre["id"] + " must not be in an executable section")
            offset = self.payload.get_offset_from_rva(rva)
            raw = self.payload.__data__[offset:offset + len(expected)]
            self.assertEqual(raw, expected, neutre["id"] + ": pinned bytes drifted")
            for start, end in ranges:
                self.assertTrue(rva + len(expected) <= start or rva >= end,
                                neutre["id"] + " overlaps another neutre")
            ranges.append((rva, rva + len(expected)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
