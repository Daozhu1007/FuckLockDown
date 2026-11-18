import json

d = json.load(open(r'D:/Code/FuckLockDown/analysis/lockdown-2.1.6.03/string-hits/LockDownBrowser.exe.json', encoding='utf-8'))
s = json.dumps(d).lower()
for kw in ['powershell', 'cmd.exe', 'notepad', 'onedrive', 'msedge', 'firefox',
           'chrome.exe', 'teamviewer', 'vmware', 'vbox', 'explorer.exe', 'skype',
           'zoom', 'discord', 'spotify', 'anydesk', 'teamviewer_service', 'ultraviewer']:
    print(kw, kw in s)

# Also dump any string that looks like a program name (ends with .exe)
import re
hits = sorted(set(re.findall(r'[a-z0-9_.\- ]{2,40}\.exe', s)))
print('total .exe-like strings:', len(hits))
for h in hits[:120]:
    print(' ', h)
