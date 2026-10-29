# -*- coding: utf-8 -*-
"""Dump HistoryDialog and MainActivity$3 handler classes."""
from loguru import logger
logger.remove()
from androguard.core.apk import APK
from androguard.core.dex import DEX
import io, sys, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

KEY_CLASSES = [
    'Lcom/zddz/app/sicn/fragment/HistoryDialog;',
    'Lcom/zddz/app/sicn/fragment/HistoryDialog$1;',
    'Lcom/zddz/app/sicn/fragment/HistoryDialog$2;',
    'Lcom/zddz/app/sicn/MainActivity$3;',
    'Lcom/zddz/app/sicn/MainActivity$3$1;',
    'Lcom/zddz/app/sicn/fragment/MainFragment$1;',
    'Lcom/zddz/app/sicn/fragment/MainFragment$3$1;',
    'Lcom/zddz/bt/BtService$7;',
    'Lcom/zddz/bt/BtService$8;',
    'Lcom/zddz/bt/BtService$9;',
    'Lcom/zddz/bt/BtMethod;',
]

a = APK(r'F:\开发\蓝牙设备\sicn.apk')
class_index = {}
for raw in a.get_all_dex():
    d = DEX(raw)
    for cls in d.get_classes():
        class_index[cls.get_name()] = cls

outdir = r'F:\开发\蓝牙设备\analysis\smali'

def dump_class(cls, out_path):
    lines = []
    lines.append('### CLASS %s (super=%s)' % (cls.get_name(), cls.get_superclassname()))
    for f in cls.get_fields():
        lines.append('FIELD: %s %s' % (f.get_name(), f.get_descriptor()))
    lines.append('')
    for meth in cls.get_methods():
        m = meth
        lines.append('METHOD: %s %s%s' % (m.get_access_flags_string(), m.get_name(), m.get_descriptor()))
        code = m.get_code()
        if code is not None:
            bc = code.get_bc()
            try:
                for ins in bc.get_instructions():
                    try:
                        out = ins.get_output()
                    except Exception:
                        out = ''
                    lines.append('    %-24s %s' % (ins.get_name(), out))
            except Exception as e:
                lines.append('    <disasm error: %s>' % e)
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
