"""Locate VM-detection related strings in the extracted LockDownBrowser.exe."""
import re
from pathlib import Path

target = Path(r'D:/Code/FuckLockDown/analysis/lockdown-2.1.6.03/payload/ProgramFiles64Folder/Respondus/LockDown Browser/LockDownBrowser.exe')
data = target.read_bytes()
print('size:', len(data))

needles = [
    b'virtual machine software such as',
    b'Virtual PC, VMWare and Parallels',
    b'V\x00i\x00r\x00t\x00u\x00a\x00l\x00 \x00m\x00a\x00c\x00h\x00i\x00n\x00e\x00',
    b'QEMU',
    b'VBOX',
    b'VirtualBox',
    b'VMware',
    b'Parallels',
    b'Microsoft Corporation' + b'',
    b'Hyper-V',
    b'KVM',
    b'bochs',
    b'Bochs',
    b'innotek',
    b'Virtual Machine',
]

for n in needles:
    idxs = []
    start = 0
    while True:
        i = data.find(n, start)
        if i < 0:
            break
        idxs.append(hex(i))
        start = i + 1
        if len(idxs) > 12:
            break
    print(repr(n[:40]), '->', idxs if idxs else 'not found')
