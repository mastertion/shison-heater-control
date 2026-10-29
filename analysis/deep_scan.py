# -*- coding: utf-8 -*-
"""Enhanced scan: show ALL devices with full advertisement details."""
import asyncio, io, sys
from loguru import logger
logger.remove()
from bleak import BleakScanner

async def main():
    out = []
    out.append("=== 增强扫描 (15秒, 显示全部设备) ===")
    devs = await BleakScanner.discover(timeout=15, return_adv=True)
    out.append("发现 %d 台设备:" % len(devs))
    for addr, val in devs.items():
        adv = val[1] if isinstance(val, tuple) else val
        out.append("-" * 60)
        out.append("地址: %s" % addr)
        out.append("名称: %r" % adv.local_name)
        out.append("RSSI: %s" % adv.rssi)
        out.append("厂商数据: %s" % {hex(k): v.hex() for k, v in (adv.manufacturer_data or {}).items()})
        out.append("服务数据: %s" % {str(k): v.hex() for k, v in (adv.service_data or {}).items()})
        out.append("服务UUID: %s" % [str(u) for u in (adv.service_uuids or [])])
    with open(r"F:\开发\蓝牙设备\analysis\deep_scan.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    print("done")

asyncio.run(main())
