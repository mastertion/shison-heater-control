# -*- coding: utf-8 -*-
"""Dump MainFragment.notice with absolute instruction offsets (file output)."""
import io, sys
from loguru import logger
logger.remove()
import logging
logging.disable(logging.CRITICAL)

from androguard.core.apk import APK
from androguard.core.dex import DEX

out_lines = []
try:
    a = APK(r'F:\开发\蓝牙设备\sicn.apk')
    found = None
    for raw in a.get_all_dex():
        d = DEX(raw)
        for c in d.get_classes():
            if c.get_name() == 'Lcom/zddz/app/sicn/fragment/MainFragment;':
                found = c
                break
        if found:
            break
    out_lines.append('found: %s' % (found is not None))
    if found:
        for meth in found.get_methods():
            if meth.get_name() == 'notice':
                out_lines.append('METHOD notice found')
                code = meth.get_code()
                bc = code.get_bc()
                for ins in bc.get_instructions():
                    try:
                        off = getattr(ins, 'get_offset', None)
                        offstr = ('@%04x' % off()) if off else '????'
                        out = ins.get_output()
                    except Exception as e:
                        out = '<err %s>' % e
                    out_lines.append('%s %-26s %s' % (offstr, ins.get_name(), out))
except Exception as e:
    out_lines.append('EXCEPTION: %r' % e)

with open(r'F:\开发\蓝牙设备\analysis\step6_out.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(out_lines))
print('done, lines:', len(out_lines))
