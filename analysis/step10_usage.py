# -*- coding: utf-8 -*-
"""Find usages of OrderSet fields (hour/minute/sync) across all classes."""
from loguru import logger
logger.remove()
from androguard.core.apk import APK
from androguard.core.dex import DEX

targets = ['write_hour_data', 'write_minute_data', 'write_synchronize',
           'notice_hour_data', 'notice_minute_data',
           'write_change_temperature_type', 'write_target_temperature',
           'notice_current_temperature', 'notice_target_temperature']

a = APK(r'F:\开发\蓝牙设备\sicn.apk')
hits = []
for raw in a.get_all_dex():
    d = DEX(raw)
    for cls in d.get_classes():
        for meth in cls.get_methods():
            code = meth.get_code()
            if code is None:
                continue
            try:
                bc = code.get_bc()
                for ins in bc.get_instructions():
                    out = ins.get_output()
                    for t in targets:
                        if t in out:
                            hits.append('%s :: %s :: %s -> %s' % (
                                cls.get_name(), meth.get_name(), ins.get_name(), out.strip()))
            except Exception:
                pass

with open(r'F:\开发\蓝牙设备\analysis\order_usage.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(hits))
print('hits:', len(hits))
