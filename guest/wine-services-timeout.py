#!/usr/bin/env python3
# Runs inside the guest (as the Steam user): raise Wine's service start timeout in a Proton prefix. services.exe
# gives a starting service 10 s (ServicesPipeTimeout); x86 processes under FEX start slower, so RpcSs missed it,
# explorer.exe exited and games waited forever for a desktop. Usage: wine-services-timeout.py <system.reg> [ms]
import re
import sys

path = sys.argv[1]
ms = sys.argv[2] if len(sys.argv) > 2 else '120000'
text = open(path, encoding='utf-8', errors='surrogateescape').read()
value = f'"ServicesPipeTimeout"="{ms}"\n'
text = re.sub(r'^"ServicesPipeTimeout"=.*\n', '', text, flags=re.M)
# CurrentControlSet is a link to ControlSet001 in Wine's registry files
section = re.search(r'^\[System\\\\ControlSet001\\\\Control\][^\n]*\n(#time=[^\n]*\n)?', text, re.M)
if section:
    text = text[:section.end()] + value + text[section.end():]
else:
    text += '\n[System\\\\ControlSet001\\\\Control]\n' + value
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(text)
print(f'{path}: ServicesPipeTimeout={ms}')
