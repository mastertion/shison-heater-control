# -*- coding: utf-8 -*-
"""Dump R$string / R$drawable field name->id mappings."""
from loguru import logger
logger.remove()
from androguard.core.apk import APK
from androguard.core.dex import DEX

targets = {2131755063, 2131755089, 2131755099, 2131755207, 2131755217, 2131755219,
           2131755074, 2131755076, 2131755040, 2131755061,
           2131165380, 2131165381, 2131165382, 2131165383, 2131165384, 2131165385}
lines = []
a = APK(r'F:\开发\蓝牙设备\sicn.apk')
for raw in a.get_all_dex():
    d = DEX(raw)
    for cls in d.get_classes():
        name = cls.get_name()
        if name in ('Lcom/zddz/app/sicn/R$string;', 'Lcom/zddz/app/sicn/R$drawable;', 'Lcom/zddz/app/sicn/R$id;'):
            for f in cls.get_fields():
                try:
                    fid = f.get_static_value()
                    fname = f.get_name()
                    if isinstance(fid, int) and fid in targets:
                        lines.append('%s.%s = 0x%x' % (name.split('$')[-1], fname, fid))
                except Exception:
                    pass
with open(r'F:\开发\蓝牙设备\analysis\r_ids.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))
print('done')
