# -*- coding: utf-8 -*-
"""Step 3: decompile key protocol classes with androguard DAD decompiler."""
import io, sys, os
from loguru import logger
logger.remove()
import logging
logging.disable(logging.CRITICAL)

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

dex_files = [r'F:\开发\蓝牙设备\sicn_extract\classes.dex',
             r'F:\开发\蓝牙设备\sicn_extract\classes2.dex']

outdir = r'F:\开发\蓝牙设备\analysis\decompiled'
os.makedirs(outdir, exist_ok=True)

class_index = {}
for dex_path in dex_files:
    with open(dex_path, 'rb') as f:
        d = DEX(f.read())
    for cls in d.get_classes():
        class_index[cls.get_name()] = cls

for kc in KEY_CLASSES:
    if kc not in class_index:
        print('NOT FOUND:', kc)
        continue
    cls = class_index[kc]
    src = cls.get_source()
    if src is None:
        src = '// (no source — using DAD decompiler)\n'
        try:
            a = Analysis()
            a.add(dex_files)
            from androguard.decompiler.decompiler import DecompilerDAD
            dec = DecompilerDAD(kc, a)
            src = dec.get_methods_as_source() if hasattr(dec, 'get_methods_as_source') else str(dec)
        except Exception as e:
            src = f'// DAD failed: {e}\n'
    fn = os.path.join(outdir, kc.strip('L;').replace('/', '_') + '.java')
    with open(fn, 'w', encoding='utf-8') as f:
        f.write(src)
    print('WROTE', fn, len(src), 'chars')
