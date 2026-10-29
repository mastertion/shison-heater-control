# -*- coding: utf-8 -*-
"""Enumerate string resources correctly."""
from loguru import logger
logger.remove()
from androguard.core.apk import APK

lines = []
a = APK(r'F:\开发\蓝牙设备\sicn.apk')
arsc = a.get_android_resources()
pkg = 'com.zddz.app.sicn'

# public resources: name -> id
pub = arsc.get_public_resources(pkg)
rev = {v: k for k, v in pub.items()}

targets = [2131755063, 2131755089, 2131755099, 2131755207, 2131755217, 2131755219,
           2131755074, 2131755076, 2131755040, 2131755061]
for rid in targets:
    name = rev.get(rid)
    lines.append('%s name=%s' % (hex(rid), name))

# get resolved strings
try:
    rs = arsc.get_resolved_strings(pkg)
    if isinstance(rs, dict):
        for k, v in rs.items():
            if k in targets or (isinstance(k, tuple) and k[0] in targets):
                lines.append('resolved %r -> %r' % (k, v))
    else:
        lines.append('resolved type: %s len=%s' % (type(rs), len(rs)))
        if targets[0] in rs:
            lines.append('found by rid: %r' % rs[targets[0]])
except Exception as e:
    lines.append('resolved err: %r' % e)

# get_string_resources
try:
    sr = arsc.get_string_resources(pkg)
    lines.append('string_resources type: %s' % type(sr))
    if isinstance(sr, dict):
        for (rid, cfg), val in list(sr.items())[:3]:
            lines.append('sample %s %s -> %r' % (hex(rid), cfg, val))
except Exception as e:
    lines.append('string_resources err: %r' % e)

with open(r'F:\开发\蓝牙设备\analysis\strings_out.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))
print('done')
