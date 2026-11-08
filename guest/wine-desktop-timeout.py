#!/usr/bin/env python3
"""Raise Wine's wait for explorer.exe in Proton's win32u.so (x86_64 unix side) from 10 s to 60 s.

get_desktop_window() starts explorer.exe and calls NtUserWaitForInputIdle(process, 10000, FALSE); under FEX
explorer needs ~15 s (X11 driver + Vulkan setup), so the caller gives up and every window fails with "The explorer
process failed to start" (README: Banished under gamescope). The wait returns as soon as explorer is ready, so a
longer limit costs nothing. Matches exactly one `xor edx,edx; mov esi,10000; call` or does nothing.
Usage: wine-desktop-timeout.py WIN32U_SO [MILLISECONDS]
"""
import os
import stat
import sys

PREFIX = b'\x31\xd2\xbe'  # xor %edx,%edx; mov $imm32,%esi
CALL = b'\xe8'


def pattern(ms: int) -> bytes:
    return PREFIX + ms.to_bytes(4, 'little') + CALL


def main() -> int:
    path = sys.argv[1]
    new_ms = int(sys.argv[2]) if len(sys.argv) > 2 else 60000
    data = open(path, 'rb').read()
    if data.count(pattern(new_ms)) == 1:
        print(f'{path}: already {new_ms} ms')
        return 0
    if data.count(pattern(10000)) != 1:
        print(f'{path}: pattern not found exactly once, left alone')
        return 1
    mode = os.stat(path).st_mode
    os.chmod(path, mode | stat.S_IWUSR)
    with open(path, 'r+b') as f:
        f.seek(data.index(pattern(10000)))
        f.write(pattern(new_ms))
    os.chmod(path, mode)
    print(f'{path}: explorer wait 10000 -> {new_ms} ms')
    return 0


if __name__ == '__main__':
    sys.exit(main())
