"""Disassemble the periodic-scan code path of the original 2.1.6.03 build.

Targets (from lab/analysis/process-gate-reachability.json):
  0x1402c7300  timer scan call site (SetTimer 0x3fa handler region)
  0x140265c50  dispatcher (gate: global+0xf390 selects one of two branches)
  0x14022dd10  branch A
  0x1402311a0  branch B
"""
import capstone
import pefile
from pathlib import Path

TARGET = Path(r"D:\Code\FuckLockDown\analysis\lockdown-2.1.6.03\payload\ProgramFiles64Folder\Respondus\LockDown Browser\LockDownBrowser.exe")
IMAGE_BASE = 0x140000000
OUT = Path(r"D:\Code\FuckLockDown\rewrite\lab\analysis")

pe = pefile.PE(str(TARGET))

def rva_to_offset(rva: int) -> int:
    return pe.get_offset_from_rva(rva)

md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = False

REGIONS = {
    "scan-call-site":  (0x1402c7300, 0x180),
    "dispatcher":       (0x140265c50, 0x300),
    "branch-a":         (0x14022dd10, 0x500),
    "branch-b":         (0x1402311a0, 0x500),
}

raw = TARGET.read_bytes()
for name, (va, size) in REGIONS.items():
    rva = va - IMAGE_BASE
    off = rva_to_offset(rva)
    code = raw[off:off + size]
    lines = []
    for insn in md.disasm(code, va):
        lines.append(f"{insn.address:x}  {insn.mnemonic} {insn.op_str}")
    out = OUT / f"periodic-{name}.asm"
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"{name}: {va:#x} +{size:#x} -> {out} ({len(lines)} insns)")
