# -*- coding: utf-8 -*-
"""Step 1: scan dex classes for bluetooth-related code."""
import logging, io, sys
from loguru import logger
logger.remove()  # silence androguard's loguru noise
logging.disable(logging.CRITICAL)  # silence androguard debug noise

from androguard.core.dex import DEX

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

results = []
for dex_path in [r'F:\开发\蓝牙设备\sicn_extract\classes.dex',
                 r'F:\开发\蓝牙设备\sicn_extract\classes2.dex']:
    with open(dex_path, 'rb') as f:
        d = DEX(f.read())
    for cls in d.get_classes():
        name = cls.get_name()
        low = name.lower()
        if any(k in low for k in ('bluetooth', 'gatt', 'ble')):
            results.append(name)

print('\n'.join(sorted(set(results))))
print('\nTOTAL:', len(set(results)))
