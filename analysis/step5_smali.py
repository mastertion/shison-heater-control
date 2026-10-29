# -*- coding: utf-8 -*-
"""Step 5: dump remaining protocol classes."""
import io, sys, os
from loguru import logger
logger.remove()
import logging
logging.disable(logging.CRITICAL)

from androguard.core.apk import APK
from androguard.core.dex import DEX

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

KEY_CLASSES = [
    'Lcom/zddz/app/sicn/fragment/MainFragment$1;',
    'Lcom/zddz/app/sicn/fragment/MainFragment$2;',
    'Lcom/zddz/app/sicn/fragment/MainFragment$3;',
    'Lcom/zddz/bt/WriteDataItem;',
    'Lcom/zddz/bt/BtMethod;',
    'Lcom/zddz/bt/BtCallback;',
    'Lcom/zddz/app/sicn/fragment/ScanFragment;',
    'Lcom/zddz/app/sicn/activity/AlarmActivity;',
    'Lcom/zddz/bt/BtService$9;',
    'Lcom/zddz/bt/ConnectListHelper;',
    'Lcom/zddz/app/sicn/adapter/DeviceItemRAdapter;',
    'Lcom/zddz/app/sicn/MainActivity$1;',
    'Lcom/zddz/app/sicn/MainActivity$3;',
    'Lcom/zddz/app/sicn/MainActivity$4;',
]

apk_path = r'F:\开发\蓝牙设备\sicn.apk'
outdir = r'F:\开发\蓝牙设备\analysis\smali'
os.makedirs(outdir, exist_ok=True)

a = APK(apk_path)
class_index = {}
for raw in a.get_all_dex():
    d = DEX(raw)
    for cls in d.get_classes():
        class_index[cls.get_name()] = cls

def dump_class(cls, out_path):
    lines = []
    lines.append(f'### CLASS {cls.get_name()} (super={cls.get_superclassname()})')
    for f in cls.get_fields():
        lines.append(f'FIELD: {f.get_name()} {f.get_descriptor()} (access={f.get_access_flags_string()})')
    lines.append('')
    for meth in cls.get_methods():
        m = meth
        access = m.get_access_flags_string()
        lines.append(f'METHOD: {access} {m.get_name()}{m.get_descriptor()}')
        code = m.get_code()
        if code is not None:
            bc = code.get_bc()
            try:
                for ins in bc.get_instructions():
                    try:
                        out = ins.get_output()
                    except Exception:
                        out = ''
                    lines.append(f'    {ins.get_name():24s} {out}')
            except Exception as e:
                lines.append(f'    <disasm error: {e}>')
        lines.append('')
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

for kc in KEY_CLASSES:
    if kc not in class_index:
        print('NOT FOUND:', kc)
        continue
    out_path = os.path.join(outdir, kc.strip('L;').replace('/', '_') + '.smali.txt')
    dump_class(class_index[kc], out_path)
    print('WROTE', out_path)
