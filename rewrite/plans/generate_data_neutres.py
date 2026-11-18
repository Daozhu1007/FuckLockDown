"""Generate and validate the dataNeutres section of the core plan.

HISTORY / OUTCOME (2026-11-18..19, lab/reports/neutre-matrix.json through
neutre-matrix4.json): the v3 research attempted to extend the v2 pure-data
approach to the third kill path by corrupting, in the child's mapped .rdata,
the match strings that the extended blacklist (alpha = 0x14022b1b0), the
window-class timer kill (beta = 0x140245530), the WMI wireless-display sweep
(gamma = 0x140262690) and the remote-tool service check (ptc4 = 0x140261340)
compare against. The measured outcome, in five ablation matrices run in the
QEMU lab:

* beta/gamma/ptc4 needles (23 strings): corrupting ANY single byte in their
  .rdata regions (0x140b40b48..0x140b44060 and 0x140b451c8..0x140b45488)
  makes the original exit 1 within ~10 s under BOTH pre-resume and +3.5 s
  write timings - a region-level integrity self-check protects exactly those
  needle clusters (the alpha block on the same page is exempt from it).
* alpha names (7 strings: MiraCast, Spyrix x2, SelfService.exe, Citrix
  Workspace, ReadAndWrite.exe, WUDFHost.exe): survived a full 40 s matrix
  phase in one guest state, but the identical writes killed the browser
  minutes later once the browser's own state matured (auto-launch session
  flow; the lethality persisted across a VM reboot). State-dependent
  reliability is disqualifying for a launcher that must never cost the user
  an exam session.
* alpha process.list key spec (0x140b45700): lethal on the auto-launch boot
  path (the startup config read consumes the spec); only survivable in the
  first-run state.

Therefore the production plan ships an EMPTY neutre set. The launcher keeps
the fully unit-tested neutering machinery (preflight validation, executable-
section refusal, idempotent remote writes, lab ablation flags) so that a
future safe mechanism - or a different build of the original - can use it
without new plumbing.

When entries are (re)introduced, every one is verified against two
independent artifacts before the plan is written:

* ``strings/LockDownBrowser.exe.json`` - the extracted string table must
  contain the expected text at the pinned VA;
* the original ``LockDownBrowser.exe`` payload - the bytes at the computed
  RVA must equal the expected bytes, and the section must be file-backed,
  readable, and NOT executable (a neutre that lands in code would be a code
  patch in disguise and is rejected).

Re-run after editing the table:

    python rewrite/plans/generate_data_neutres.py
"""

import json
from pathlib import Path

import pefile

ROOT = Path(__file__).resolve().parents[1]
ANALYSIS = ROOT.parent / "analysis/lockdown-2.1.6.03"
STRINGS = ANALYSIS / "strings/LockDownBrowser.exe.json"
PAYLOAD = ANALYSIS / "payload/ProgramFiles64Folder/Respondus/LockDown Browser/LockDownBrowser.exe"
PLAN = ROOT / "plans/lockdown-2.1.6.03-core.json"
IMAGE_BASE = 0x140000000

# Empty by measurement - see the module docstring for the full evidence.
# Entries kept below in comments as the auditable record of what was tried:
#
#   ("alpha-miracast",          0x140B45848, "ascii", None)  - region-exempt but state-lethal
#   ("alpha-spyrix-space",      0x140B45868, "ascii", None)  - region-exempt but state-lethal
#   ("alpha-spyrix",            0x140B458EC, "ascii", None)  - region-exempt but state-lethal
#   ("alpha-selfservice",       0x140B45880, "ascii", None)  - region-exempt but state-lethal
#   ("alpha-citrix-workspace",  0x140B45890, "ascii", None)  - region-exempt but state-lethal
#   ("alpha-readandwrite",      0x140B458D0, "ascii", None)  - region-exempt but state-lethal
#   ("alpha-wudfhost",          0x140B45858, "ascii", None)  - region-exempt but state-lethal
#   ("alpha-process-list-key",  0x140B45700, "ascii", "r-to-z") - auto-launch lethal
#   ("beta-xlmain",             0x140B40B48, "ascii", None)  - integrity-checked region
#   ("beta-opusapp",            0x140B40B70, "ascii", None)  - integrity-checked region
#   ("beta-autohotkeygui",      0x140B43F40, "ascii", None)  - integrity-checked region
#   ("beta-save-a",             0x140B43F94, "ascii", None)  - integrity-checked region
#   ("beta-select-file",        0x140B43FA0, "ascii", None)  - integrity-checked region
#   ("beta-stickykeys",         0x140B43FB0, "ascii", None)  - integrity-checked region
#   ("beta-sticky-keys",        0x140B43FC0, "ascii", None)  - integrity-checked region
#   ("beta-power-options",      0x140B43FD0, "ascii", None)  - integrity-checked region
#   ("beta-message",            0x140B43FE0, "ascii", None)  - integrity-checked region
#   ("beta-message-from-web",   0x140B43FE8, "ascii", None)  - integrity-checked region
#   ("beta-discussion",         0x140B44000, "ascii", None)  - integrity-checked region
#   ("beta-print",              0x140B4400C, "ascii", None)  - integrity-checked region
#   ("beta-wireless-display-toolbar", 0x140B44040, "ascii", None) - integrity-checked region
#   ("gamma-wudfhost-wql",      0x140B45320, "utf-16le", "wql-wudfhost") - integrity-checked region
#   ("gamma-wireless-display-toolbar", 0x140B45488, "utf-16le", None)    - integrity-checked region
#   ("ptc4-scriptlogic",        0x140B451C8, "ascii", None)  - integrity-checked region
#   ("ptc4-pgxsrv",             0x140B451E0, "ascii", None)  - integrity-checked region
#   ("ptc4-ssxsrv",             0x140B451F0, "ascii", None)  - integrity-checked region
#   ("ptc4-efrservice",         0x140B45200, "ascii", None)  - integrity-checked region
#   ("ptc4-sshxsrv",            0x140B45210, "ascii", None)  - integrity-checked region
#   ("ptc4-aswtoolssvc",        0x140B45218, "ascii", None)  - integrity-checked region
#   ("ptc4-avgtoolssvc",        0x140B45228, "ascii", None)  - integrity-checked region
#   ("ptc4-avpmapp",            0x140B45238, "ascii", None)  - integrity-checked region
#
# Also excluded on scope grounds (never neutered, see V3-FINDINGS):
#   IFEO utilman path 0x140b457f0 (lockdown cleanup, not a kill), the beta
#   raise branches (Credential Dialog Xaml Host, 'Connect to '+'Password'),
#   Shell_SecondaryTrayWnd (taskbar management), the decrypted-table window
#   IDs, PTC 2,1 (display-affinity self-check), B10/C2 (zero index xrefs).
TARGETS = []


def corrupt_index1(text):
    second = text[1]
    if second.islower():
        replacement = "q"
    elif second.isupper():
        replacement = "Q"
    else:
        replacement = "Q"
    return text[0] + replacement + text[2:]


def build_replacement(rule, text):
    if rule is None:
        return corrupt_index1(text)
    if rule == "r-to-z":
        return text.replace("r", "z").replace("R", "z")
    if rule == "wql-wudfhost":
        corrupted = text.replace("%WUDFHost%", "%WQDFHost%")
        assert corrupted != text, "WQL corruption rule did not apply"
        return corrupted
    raise ValueError("Unknown replacement rule: " + rule)


def hexspaced(data):
    return " ".join(f"{byte:02x}" for byte in data)


def main():
    strings = json.loads(STRINGS.read_text(encoding="utf-8"))
    by_va = {entry["va"]: entry for entry in strings}
    payload = pefile.PE(str(PAYLOAD), fast_load=True)

    def section_of(rva):
        for section in payload.sections:
            if section.VirtualAddress <= rva < section.VirtualAddress + max(section.Misc_VirtualSize, section.SizeOfRawData):
                return section
        return None

    neutres = []
    ranges = []
    ids = set()
    for neutre_id, va, encoding, rule, rationale in TARGETS:
        entry = by_va.get(hex(va).lower()) or by_va.get(hex(va))
        assert entry is not None, f"{neutre_id}: string VA {hex(va)} missing from strings JSON"
        assert entry["encoding"] == encoding, f"{neutre_id}: encoding mismatch {entry['encoding']} != {encoding}"
        text = entry["text"]
        replacement_text = build_replacement(rule, text)
        assert len(replacement_text) == len(text), f"{neutre_id}: replacement changed length"
        expected = text.encode(encoding)
        replacement = replacement_text.encode(encoding)
        assert expected != replacement, f"{neutre_id}: replacement equals original"
        rva = va - IMAGE_BASE
        section = section_of(rva)
        assert section is not None, f"{neutre_id}: RVA {hex(rva)} outside all sections"
        assert not (section.Characteristics & 0x20000000), \
            f"{neutre_id}: target section {section.Name} is executable; data neutres must stay in data sections"
        assert section.Characteristics & 0x40000040, \
            f"{neutre_id}: target section {section.Name} is not read-only file-backed data"
        offset = payload.get_offset_from_rva(rva)
        raw = payload.__data__[offset:offset + len(expected)]
        assert raw == expected, \
            f"{neutre_id}: payload bytes at RVA {hex(rva)} are {raw!r}, expected {expected!r}"
        start, end = rva, rva + len(expected)
        for other_start, other_end in ranges:
            assert end <= other_start or start >= other_end, f"{neutre_id}: overlaps another neutre"
        ranges.append((start, end))
        assert neutre_id not in ids
        ids.add(neutre_id)
        neutres.append({
            "id": neutre_id,
            "rva": hex(rva),
            "expected": hexspaced(expected),
            "replacement": hexspaced(replacement),
            "rationale": rationale,
        })
        print(f"{neutre_id:38s} {hex(rva)} len={len(expected):3d} {text[:40]!r}")

    plan = json.loads(PLAN.read_text(encoding="utf-8"))
    plan["dataNeutres"] = neutres
    plan["dataNeutresNote"] = (
        "Empty by measurement: the beta/gamma/ptc4 needle regions are covered "
        "by the original's region integrity self-check, and the alpha entries "
        "are state-dependently lethal once the browser enters its auto-launch "
        "flow; see lab/reports/neutre-matrix*.json and "
        "plans/generate_data_neutres.py. The launcher keeps the tested "
        "machinery so a future safe mechanism can use it."
    )
    PLAN.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"\nwrote {len(neutres)} dataNeutres into {PLAN}")


if __name__ == "__main__":
    main()
