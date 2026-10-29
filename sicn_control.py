# -*- coding: utf-8 -*-
"""
SHISON HEATER 蓝牙控制脚本（Windows）
=====================================
通过 BLE 控制 SHISON 加热器（sicn.apk 对应设备）。

协议来源：对 sicn.apk (v1.55) 反编译逆向所得。

GATT:
  服务       0000FFF0-0000-1000-8000-00805F9B34FB
  特征       0000FFF1-0000-1000-8000-00805F9B34FB  (写 + 通知)

连接流程:
  1. 连接
  2. 使能 FFF1 通知
  3. 写入同步指令 [0x01, 0x03]
  4. 设备开始推送状态通知

写指令 (全部写到 FFF1):
  01 03                 请求状态同步
  31 01 LO HI           设置目标温度  value = LO + HI*256
                          摄氏度: value = round(degC * 10)
                          华氏度: value = round(degF * 10)
  31 02                 切换温度单位 (℃ <-> ℉)
  31 04                 请求小时历史曲线
  31 03                 请求分钟历史曲线

通知 (FFF1, 十六进制):
  30 01 MODE UNIT T_LO ?? T_HI ??     当前温度 = (T_HI*256 + T_LO) / 10
                                          UNIT: 0=℉  1=℃
                                          MODE: 0=探头故障 1=离水断电 2=超温保护
                                                3=加热中 4=保温/其他 5=待机/其他
  31 01 LO HI                          目标温度 = (HI*256 + LO) / 10
  30 03 ...                            小时历史 (8 个 12bit 采样值/包, 值/10)
  30 02 ...                            分钟历史 (8 个 12bit 采样值/包, 值/10)

依赖: pip install bleak    (Windows 10/11, BLE 需要系统蓝牙适配器)

用法示例:
  python sicn_control.py scan
  python sicn_control.py status --mac AA:BB:CC:DD:EE:FF
  python sicn_control.py temp --mac AA:BB:CC:DD:EE:FF --value 26 --unit C
  python sicn_control.py unit --mac AA:BB:CC:DD:EE:FF
  python sicn_control.py history --mac AA:BB:CC:DD:EE:FF --kind hour
"""
import argparse
import asyncio
import sys
import time

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    sys.exit("缺少 bleak 库，请先执行: pip install bleak")

SERVICE_UUID = "0000fff0-0000-1000-8000-00805f9b34fb"
CHAR_UUID = "0000fff1-0000-1000-8000-00805f9b34fb"
NOTIFY_UUID = "00002902-0000-1000-8000-00805f9b34fb"  # CCCD

CMD_SYNC = bytes([0x01, 0x03])
CMD_TARGET_TEMP = bytes([0x31, 0x01, 0x00, 0x00])  # 模板, 后两字节待填
CMD_CHANGE_UNIT = bytes([0x31, 0x02])
CMD_HOUR_HISTORY = bytes([0x31, 0x04])
CMD_MINUTE_HISTORY = bytes([0x31, 0x03])

STATE_NAMES = {
    0: "探头故障(报警)",
    1: "离水断电(报警)",
    2: "超温保护(报警)",
    3: "加热中",
    4: "状态4(保温?)",
    5: "待机",
}


def parse_current_temp(pkt: bytes):
    """解析 '3001' 当前温度通知: (byte6*256+byte4)/10"""
    if len(pkt) < 8 or pkt[0] != 0x30 or pkt[1] != 0x01:
        return None
    mode = pkt[2]
    unit = pkt[3]  # 0=℉ 1=℃
    raw = (pkt[6] << 8) | pkt[4]
    temp = raw / 10.0
    return {
        "type": "current",
        "mode": mode,
        "state": STATE_NAMES.get(mode, "未知"),
        "unit": "C" if unit == 1 else "F",
        "temp": temp,
        "packet": pkt.hex(" "),
    }


def parse_target_temp(pkt: bytes):
    """解析 '3101' 目标温度通知: (byte3*256+byte2)/10"""
    if len(pkt) < 4 or pkt[0] != 0x31 or pkt[1] != 0x01:
        return None
    raw = (pkt[3] << 8) | pkt[2]
    return {
        "type": "target",
        "temp": raw / 10.0,
        "packet": pkt.hex(" "),
    }


def parse_history(pkt: bytes, kind: str):
    """解析 '3003'(小时)/'3002'(分钟) 历史通知。
    每包 8 个采样点, 每个采样 2 字节的低 12 位, 值/10。
    注意: 30 03 = 小时历史, 30 02 = 分钟历史 (与直觉相反)。"""
    prefix = 0x03 if kind == "hour" else 0x02
    if len(pkt) < 3 or pkt[0] != 0x30 or pkt[1] != prefix:
        return None
    seg = pkt[2]  # 段序号 (从1开始)
    samples = []
    body = pkt[3:]
    for i in range(0, len(body) - 1, 2):
        v = (body[i] << 8) | body[i + 1]
        v &= 0x0FFF  # 低 12 位
        samples.append(v / 10.0)
    return {
        "type": kind,
        "segment": seg,
        "samples": samples,
        "packet": pkt.hex(" "),
    }


async def scan_devices(timeout: float = 8.0):
    print(f"扫描 BLE 设备 (最多 {timeout:.0f} 秒)...")
    devices = await BleakScanner.discover(timeout=timeout, return_adv=True)
    found = []
    for addr, val in devices.items():
        # 兼容不同 bleak 版本: 值可能是 (BLEDevice, AdvertisementData) 或 AdvertisementData
        adv = val[1] if isinstance(val, tuple) else val
        name = adv.local_name or "(无名称)"
        svc = adv.service_uuids or []
        match = SERVICE_UUID in svc
        found.append((addr, name, adv.rssi, svc, match))
    found.sort(key=lambda x: (-x[2]))
    print(f"{'地址':<20}{'名称':<24}{'RSSI':<6}{'匹配FFF0':<9}服务UUID")
    for addr, name, rssi, svc, match in found:
        flag = "YES" if match else "no"
        print(f"{addr:<20}{name:<24}{rssi:<6}{flag:<9}{','.join(svc)[:80]}")
    if not found:
        print("未发现任何 BLE 设备（请确认设备已开机且在范围内）")
    return found


class SicnHeater:
    def __init__(self, mac: str):
        self.mac = mac
        self.client = None
        self.last_pkt = b""
        self.state = {"current": None, "target": None, "history": None}

    def _on_notify(self, _char, data: bytearray):
        self.last_pkt = bytes(data)
        pkt = self.last_pkt
        if pkt[:2] == b"\x30\x01":
            self.state["current"] = parse_current_temp(pkt)
        elif pkt[:2] == b"\x31\x01":
            self.state["target"] = parse_target_temp(pkt)
        elif pkt[:2] == b"\x30\x03":
            self.state["history"] = parse_history(pkt, "hour")
        elif pkt[:2] == b"\x30\x02":
            self.state["history"] = parse_history(pkt, "minute")
        else:
            print(f"[通知] 未识别数据: {pkt.hex(' ')}")
            return
        print(f"[通知] {pkt.hex(' ')}")

    async def connect(self):
        self.client = BleakClient(self.mac, timeout=20.0)
        await self.client.connect()
        print(f"已连接: {self.mac}")
        await self.client.start_notify(CHAR_UUID, self._on_notify)
        print("已使能 FFF1 通知")
        # 同步握手: 等待 1 秒后写 01 03
        await asyncio.sleep(1.0)
        await self._write(CMD_SYNC, "同步指令 01 03")

    async def _write(self, data: bytes, label: str = ""):
        """先尝试无响应写, 失败则改用带响应写。"""
        try:
            await self.client.write_gatt_char(CHAR_UUID, data, response=False)
        except Exception:
            await self.client.write_gatt_char(CHAR_UUID, data, response=True)
        if label:
            print(f"[写] {label}: {data.hex(' ')}")

    def make_temp_cmd(self, deg: float, unit: str) -> bytes:
        """目标温度指令: value = round(deg*10), 小端 2 字节。"""
        unit = unit.upper()
        if unit == "F":
            value = round(deg * 10)
        else:
            value = round(deg * 10)
        cmd = bytearray(CMD_TARGET_TEMP)
        cmd[2] = value & 0xFF
        cmd[3] = (value >> 8) & 0xFF
        return bytes(cmd)

    async def set_temperature(self, deg: float, unit: str):
        cmd = self.make_temp_cmd(deg, unit)
        await self._write(cmd, f"设置目标温度 {deg:.1f}{'F' if unit.upper()=='F' else 'C'}")

    async def request_status(self):
        """再次发送同步指令, 触发设备上报当前/目标温度。"""
        await self._write(CMD_SYNC, "请求状态同步")

    async def toggle_unit(self):
        await self._write(CMD_CHANGE_UNIT, "切换温度单位")

    async def request_history(self, kind: str):
        cmd = CMD_HOUR_HISTORY if kind == "hour" else CMD_MINUTE_HISTORY
        await self._write(cmd, f"请求{'小时' if kind=='hour' else '分钟'}历史")

    async def wait_notifications(self, seconds: float, quiet: bool = False):
        end = time.time() + seconds
        while time.time() < end:
            if self.state["current"] and not quiet:
                cur = self.state["current"]
                print(f"  当前温度: {cur['temp']:.1f}℃/℉ 单位={cur['unit']} 状态={cur['state']}")
            if self.state["target"] and not quiet:
                tgt = self.state["target"]
                print(f"  目标温度: {tgt['temp']:.1f}℃/℉")
            await asyncio.sleep(0.5)

    async def close(self):
        if self.client and self.client.is_connected:
            try:
                await self.client.stop_notify(CHAR_UUID)
            except Exception:
                pass
            await self.client.disconnect()
        print("已断开")


async def cmd_status(mac: str, seconds: float):
    h = SicnHeater(mac)
    await h.connect()
    print(f"等待状态通知 {seconds:.0f} 秒...")
    await h.wait_notifications(seconds, quiet=True)
    print("\n=== 最终状态 ===")
    if h.state["current"]:
        c = h.state["current"]
        print(f"当前温度: {c['temp']:.1f}°{c['unit']}")
        print(f"工作状态: {c['state']}")
    if h.state["target"]:
        t = h.state["target"]
        print(f"目标温度: {t['temp']:.1f}°C/°F(按设备当前单位)")
    if not h.state["current"] and not h.state["target"]:
        print("未收到任何通知，请确认设备已开机并靠近适配器。")
    await h.close()


async def cmd_temp(mac: str, value: float, unit: str, seconds: float):
    h = SicnHeater(mac)
    await h.connect()
    await h.set_temperature(value, unit)
    print(f"等待回显确认...")
    await h.wait_notifications(seconds, quiet=True)
    if h.state["target"]:
        t = h.state["target"]
        print(f"\n设备回显目标温度: {t['temp']:.1f} (数值, 单位以设备显示为准)")
    await h.close()


async def cmd_unit(mac: str, seconds: float):
    h = SicnHeater(mac)
    await h.connect()
    await h.toggle_unit()
    await h.wait_notifications(seconds, quiet=True)
    await h.close()


async def cmd_history(mac: str, kind: str, seconds: float):
    h = SicnHeater(mac)
    await h.connect()
    await h.request_history(kind)
    await h.wait_notifications(seconds, quiet=True)
    if h.state["history"]:
        hist = h.state["history"]
        print(f"\n=== {('小时' if kind=='hour' else '分钟')}历史 段{hist['segment']} ===")
        print(" ".join(f"{s:.1f}" for s in hist["samples"]))
    else:
        print("未收到历史数据。")
    await h.close()


async def _ask(prompt: str) -> str:
    """在 asyncio 环境中安全地读取用户输入 (不阻塞通知回调)。"""
    return await asyncio.to_thread(input, prompt)


async def _pick_device() -> str:
    """扫描并让用户选择设备, 返回 MAC; 返回空串表示放弃。"""
    while True:
        devices = await scan_devices(8.0)
        if not devices:
            ans = await _ask("未发现设备。回车重新扫描, q 退出: ")
            if ans.strip().lower() == "q":
                return ""
            continue
        ans = await _ask("输入设备编号选择 (q 退出): ")
        ans = ans.strip()
        if ans.lower() == "q":
            return ""
        if ans.isdigit():
            i = int(ans)
            if 0 <= i < len(devices):
                return devices[i][0]
        print("无效选择, 请重试。")


async def interactive():
    """双击运行的交互菜单。"""
    print("=" * 52)
    print("  SHISON HEATER 蓝牙控制台 (sicn_control)")
    print("  1. 确保加热器已开机且靠近电脑")
    print("  2. 按下面菜单操作, 随时输入 q 退出")
    print("=" * 52)

    while True:
        print("\n--- 主菜单 ---")
        print("  1  扫描并连接设备")
        print("  q  退出")
        ans = await _ask("请选择: ")
        if ans.strip().lower() == "q":
            break
        if ans.strip() != "1":
            continue

        mac = await _pick_device()
        if not mac:
            continue

        h = SicnHeater(mac)
        try:
            await h.connect()
        except Exception as e:
            print(f"连接失败: {e} (确认设备开机、距离近、无其他设备占用)")
            continue

        while True:
            print("\n--- 已连接: %s ---" % mac)
            c = h.state["current"]
            t = h.state["target"]
            if c:
                print("  当前温度: %.1f°%s  状态: %s" % (c["temp"], c["unit"], c["state"]))
            else:
                print("  当前温度: (等待设备上报...)")
            if t:
                print("  目标温度: %.1f°C/°F (以设备单位为准)" % t["temp"])
            print("  1  查看/刷新状态")
            print("  2  设置目标温度")
            print("  3  切换温度单位")
            print("  4  查看小时历史")
            print("  5  查看分钟历史")
            print("  0  断开连接返回主菜单")
            print("  q  退出程序")
            ans = await _ask("请选择: ")
            ans = ans.strip().lower()
            if ans == "q":
                await h.close()
                return
            if ans == "0":
                await h.close()
                break
            if ans == "1":
                await h.request_status()
                await h.wait_notifications(4.0, quiet=True)
            elif ans == "2":
                unit = (await _ask("单位 C(摄氏度)/F(华氏度), 回车默认 C: ")).strip().upper()
                if unit not in ("C", "F"):
                    unit = "C"
                try:
                    val = float(await _ask("目标温度值 (如 26 或 78.8): "))
                except ValueError:
                    print("无效温度。")
                    continue
                await h.set_temperature(val, unit)
                await h.wait_notifications(3.0, quiet=True)
            elif ans == "3":
                await h.toggle_unit()
                await h.wait_notifications(3.0, quiet=True)
            elif ans == "4":
                await h.request_history("hour")
                await h.wait_notifications(4.0, quiet=True)
                if h.state["history"]:
                    hist = h.state["history"]
                    print("小时历史(段%d): %s" % (hist["segment"], " ".join(f"{s:.1f}" for s in hist["samples"])))
            elif ans == "5":
                await h.request_history("minute")
                await h.wait_notifications(4.0, quiet=True)
                if h.state["history"]:
                    hist = h.state["history"]
                    print("分钟历史(段%d): %s" % (hist["segment"], " ".join(f"{s:.1f}" for s in hist["samples"])))
            else:
                print("无效选择。")

    print("已退出。")


def main():
    ap = argparse.ArgumentParser(description="SHISON HEATER BLE 控制 (Windows)")
    sub = ap.add_subparsers(dest="cmd")
    # 不传参数 = 双击运行 -> 进入交互菜单

    p = sub.add_parser("scan", help="扫描 BLE 设备")
    p.add_argument("--timeout", type=float, default=8.0)

    p = sub.add_parser("status", help="连接并读取状态")
    p.add_argument("--mac", required=True)
    p.add_argument("--seconds", type=float, default=5.0)

    p = sub.add_parser("temp", help="设置目标温度")
    p.add_argument("--mac", required=True)
    p.add_argument("--value", type=float, required=True, help="温度值, 如 26 或 78.8")
    p.add_argument("--unit", choices=["C", "F"], default="C")
    p.add_argument("--seconds", type=float, default=4.0)

    p = sub.add_parser("unit", help="切换温度单位")
    p.add_argument("--mac", required=True)
    p.add_argument("--seconds", type=float, default=4.0)

    p = sub.add_parser("history", help="请求历史温度曲线")
    p.add_argument("--mac", required=True)
    p.add_argument("--kind", choices=["hour", "minute"], default="hour")
    p.add_argument("--seconds", type=float, default=6.0)

    args = ap.parse_args()
    if not args.cmd:
        # 双击运行 / 无参数 -> 进入交互菜单
        asyncio.run(interactive())
        return
    if args.cmd == "scan":
        asyncio.run(scan_devices(args.timeout))
        return
    if args.cmd == "status":
        asyncio.run(cmd_status(args.mac, args.seconds))
    elif args.cmd == "temp":
        asyncio.run(cmd_temp(args.mac, args.value, args.unit, args.seconds))
    elif args.cmd == "unit":
        asyncio.run(cmd_unit(args.mac, args.seconds))
    elif args.cmd == "history":
        asyncio.run(cmd_history(args.mac, args.kind, args.seconds))


if __name__ == "__main__":
    main()
