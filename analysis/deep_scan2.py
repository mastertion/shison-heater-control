# -*- coding: utf-8 -*-
"""60s deep scan: find the SHISON heater (name SICN-HEATER-E84 or FFF0 service)."""
import asyncio
from bleak import BleakScanner

async def main():
    out = []
    out.append("=== 60秒深扫描: 找 SICN-HEATER-E84 / FFF0 服务 ===")
    devs = await BleakScanner.discover(timeout=60, return_adv=True)
    out.append("发现 %d 台设备:" % len(devs))
    heater = []
    for addr, val in devs.items():
        adv = val[1] if isinstance(val, tuple) else val
        name = adv.local_name or ""
        svcs = [str(u) for u in (adv.service_uuids or [])]
        is_heater = ("sicn" in name.lower()) or ("heater" in name.lower()) or \
                    ("0000fff0-0000-1000-8000-00805f9b34fb" in svcs) or \
                    ("fff0" in name.lower())
        flag = "  <<<< 加热器?" if is_heater else ""
        out.append("-" * 60)
        out.append("地址: %s%s" % (addr, flag))
        out.append("名称: %r" % name)
        out.append("RSSI: %s" % adv.rssi)
        out.append("厂商数据: %s" % {hex(k): v.hex() for k, v in (adv.manufacturer_data or {}).items()})
        out.append("服务数据: %s" % {str(k): v.hex() for k, v in (adv.service_data or {}).items()})
        out.append("服务UUID: %s" % svcs)
        if is_heater:
            heater.append((addr, name, adv.rssi))
    out.append("\n=== 加热器候选 ===")
    if heater:
        for h in heater:
            out.append("  %s  %r  %s dBm" % h)
    else:
        out.append("  (无)")
    with open(r"F:\开发\蓝牙设备\analysis\deep_scan2.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    print("done", len(heater))

asyncio.run(main())
