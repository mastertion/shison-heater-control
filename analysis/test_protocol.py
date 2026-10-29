# -*- coding: utf-8 -*-
"""Unit test for sicn_control.py protocol decoders."""
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("sicn", r"F:\开发\蓝牙设备\sicn_control.py")
mod = importlib.util.module_from_spec(spec)
# 不执行 argparse main
spec.loader.exec_module(mod)

fails = []

def check(name, got, want):
    ok = got == want
    print(("PASS" if ok else "FAIL"), name, "->", got)
    if not ok:
        fails.append(name)

# 1. temp command C: 26.0C -> 260 = 0x0104 -> [31,01,04,01]
check("temp_cmd_C_26", mod.SicnHeater("x").make_temp_cmd(26.0, "C").hex(), "31010401")
# 2. temp command F: 78F -> 780 = 0x030C -> [31,01,0c,03]
check("temp_cmd_F_78", mod.SicnHeater("x").make_temp_cmd(78, "F").hex(), "31010c03")
# 3. temp command C: 25.5 -> 255 = 0x00ff
check("temp_cmd_C_255", mod.SicnHeater("x").make_temp_cmd(25.5, "C").hex(), "3101ff00")
# 4. parse target echo 31010401 -> 26.0
t = mod.parse_target_temp(bytes.fromhex("31010401"))
check("parse_target_26", (t["temp"], t["type"]), (26.0, "target"))
# 5. parse current 3001: mode=3 heating, unit=1 C, t=(0*256+0xfa)/10=25.0
c = mod.parse_current_temp(bytes.fromhex("30010301fa000000"))
check("parse_current", (c["temp"], c["mode"], c["unit"], c["state"]), (25.0, 3, "C", "加热中"))
# 6. parse current F: unit=0, b4=0x14, b6=0x01 -> (0x0114)/10 = 27.6
c2 = mod.parse_current_temp(bytes.fromhex("3001050014010100"))
check("parse_current_F", (c2["temp"], c2["unit"]), (27.6, "F"))
# 7. history: 3003 01 + samples: [00,01]->0x001=0.1, [00,ff]->0x0ff=25.5,
#    [00,02]->0x002=0.2, [10,03]->0x003=0.3, [20,04]->0x004=0.4  (hour: prefix 0x03)
pkt = bytes.fromhex("3003010001" + "00ff" + "0002" + "1003" + "2004")
h = mod.parse_history(pkt, "hour")
check("parse_history_hour", (h["segment"], h["samples"]), (1, [0.1, 25.5, 0.2, 0.3, 0.4]))
# 8. minute history: prefix 0x02
h2 = mod.parse_history(bytes.fromhex("30020100ff"), "minute")
check("parse_history_minute", h2["samples"], [25.5])
# 9. non-matching packet
check("parse_other_none", mod.parse_current_temp(bytes.fromhex("31010401")), None)

print("\n" + ("ALL PASS" if not fails else "FAILED: %s" % fails))
sys.exit(1 if fails else 0)
