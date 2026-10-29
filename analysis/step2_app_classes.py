# -*- coding: utf-8 -*-
"""Step 2: find app's own classes (com.zddz) and classes referencing android.bluetooth."""
import io, sys
from loguru import logger
logger.remove()
import logging
logging.disable(logging.CRITICAL)

from androguard.core.dex import DEX

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

app_classes = []
bluetooth_refs = set()
android_bluetooth = ('Landroid/bluetooth/',)

for dex_path in [r'F:\开发\蓝牙设备\sicn_extract\classes.dex',
                 r'F:\开发\蓝牙设备\sicn_extract\classes2.dex']:
    with open(dex_path, 'rb') as f:
        d = DEX(f.read())
    for cls in d.get_classes():
        name = cls.get_name()
        if name.startswith('Lcom/zddz/'):
            app_classes.append(name)
        # check if class references android.bluetooth types
        try:
            for t in cls.get_interfaces() or []:
                pass
        except Exception:
            pass
        # scan method refs / field refs for bluetooth usage
        for meth in cls.get_methods():
            try:
                for _, _, tname in meth.get_method().get_information():
                    pass
            except Exception:
                pass

# Build reverse index: which classes contain string constants or type refs related to bluetooth
print('=== com.zddz package classes ===')
for c in sorted(app_classes):
    print(c)
print('TOTAL app classes:', len(app_classes))
