# -*- coding: utf-8 -*-
"""Step 3b: decompile key protocol classes via full androguard Analysis."""
import io, sys, os
from loguru import logger
logger.remove()
import logging
logging.disable(logging.CRITICAL)

from androguard.core.apk import APK
from androguard.core.dex import DEX
from androguard.core.analysis.analysis import Analysis

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

KEY_CLASSES = [
    'Lcom/zddz/app/sicn/OrderSet;',
    'Lcom/zddz/bt/Convert;',
    'Lcom/zddz/bt/DeviceItem;',
    'Lcom/zddz/bt/WriteDataItem;',
    'Lcom/zddz/bt/BtCallback;',
    'Lcom/zddz/bt/BtMethod;',
    'Lcom/zddz/bt/BluetoothGattState;',
    'Lcom/zddz/bt/DeviceRecord;',
    'Lcom/zddz/bt/ConnectListHelper;',
]

apk_path = r'F:\开发\蓝牙设备\sicn.apk'
outdir = r'F:\开发\蓝牙设备\analysis\decompiled'
os.makedirs(outdir, exist_ok=True)

a = APK(apk_path)
d = Analysis()
for raw in a.get_all_dex():
    d.add(DEX(raw))

def find_class(d, name):
    for ca in d.get_classes():
        if ca.get_vm_class().get_name() == name:
            return ca
    return None

for kc in KEY_CLASSES:
    cls = find_class(d, kc)
    if cls is None:
        print('NOT FOUND:', kc)
        continue
    try:
        src = cls.get_source()
    except Exception as e:
        src = f'// get_source failed: {e}\n'
    if src is None:
        src = '// no source\n'
    fn = os.path.join(outdir, kc.strip('L;').replace('/', '_') + '.java')
    with open(fn, 'w', encoding='utf-8') as f:
        f.write(src)
    print('WROTE', fn, len(src), 'chars')
