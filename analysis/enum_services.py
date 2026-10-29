# -*- coding: utf-8 -*-
"""Enumerate GATT services with many retries, catching CancelledError."""
import asyncio
from bleak import BleakClient

ADDR = "A4:6D:33:B8:26:17"

async def enum_once(client):
    lines = []
    lines.append("已连接: %s MTU=%s" % (client.is_connected, client.mtu_size))
    for svc in client.services:
        lines.append("=" * 60)
        lines.append("服务: %s  (%s)" % (svc.uuid, svc.description))
        for ch in svc.characteristics:
            lines.append("  特征: %s  [%s]  handle=%s" % (ch.uuid, ",".join(ch.properties or []), ch.handle))
            for d in ch.descriptors:
                lines.append("     描述符: %s  handle=%s" % (d.uuid, d.handle))
    lines.append("\n" + "=" * 60)
    lines.append("尝试读取可读特征:")
    for svc in client.services:
        for ch in svc.characteristics:
            if "read" in (ch.properties or []):
                try:
                    val = await client.read_gatt_char(ch)
                    lines.append("  %s = %s" % (ch.uuid, val.hex()))
                except Exception as e:
                    lines.append("  %s 读取失败: %s" % (ch.uuid, e))
    return lines

async def try_once(attempt, use_pair):
    lines = []
    lines.append("\n##### 第 %d 次尝试%s #####" % (attempt, " (配对)" if use_pair else ""))
    client = BleakClient(ADDR, timeout=15)
    try:
        await client.connect()
        if use_pair:
            lines.append("开始配对...")
            await client.pair()
    except BaseException as e:
        lines.append("连接失败/超时: %r: %s" % (type(e).__name__, e))
        return lines, False
    try:
        l2 = await enum_once(client)
        lines.extend(l2)
        return lines, True
    except BaseException as e:
        lines.append("枚举失败: %r: %s" % (type(e).__name__, e))
        return lines, False
    finally:
        try:
            await client.disconnect()
        except BaseException:
            pass

async def main():
    all_lines = []
    ok = False
    for attempt in range(1, 6):
        lines, done = await try_once(attempt, use_pair=False)
        all_lines.extend(lines)
        if done:
            ok = True
            break
        await asyncio.sleep(3)
    if not ok:
        for attempt in range(6, 9):
            lines, done = await try_once(attempt, use_pair=True)
            all_lines.extend(lines)
            if done:
                ok = True
                break
            await asyncio.sleep(3)
    all_lines.append("\n最终结果: " + ("SUCCESS" if ok else "FAILED"))
    with open(r"F:\开发\蓝牙设备\analysis\enum_services.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(all_lines))
    print("done", ok)

asyncio.run(main())
