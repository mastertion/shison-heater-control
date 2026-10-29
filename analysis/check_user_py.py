# -*- coding: utf-8 -*-
"""Verify user Python312 can import bleak and run the script entry."""
import sys
lines = []
try:
    import bleak
    lines.append('bleak import OK: %s' % bleak)
    from bleak import BleakScanner, BleakClient
    lines.append('BleakScanner/BleakClient import OK')
except Exception as e:
    lines.append('IMPORT FAIL: %r' % e)

# smoke: parse args path without entering interactive (simulate 'q')
import subprocess
with open(r'F:\开发\蓝牙设备\analysis\user_py_check.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))
print('done')
