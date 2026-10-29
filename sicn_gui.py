# -*- coding: utf-8 -*-
"""
SHISON HEATER 蓝牙控制面板 (GUI 版, Windows)
=============================================
图形界面版控制脚本, 双击"启动控制台.bat"即可使用。

协议与 sicn_control.py 相同 (服务 FFF0 / 特征 FFF1), 见 sicn协议分析报告.md。
"""
import asyncio
import ctypes
import os
import queue
import sys
import threading
import tkinter as tk
from tkinter import ttk, messagebox

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    ctypes.windll.user32.MessageBoxW(
        0, "缺少 bleak 库，请先运行:  pip install bleak\n\n"
           "或在命令行执行:  python -m pip install bleak",
        "SHISON 控制面板 - 缺少依赖", 0x10)
    sys.exit(1)

SERVICE_UUID = "0000fff0-0000-1000-8000-00805f9b34fb"
CHAR_UUID = "0000fff1-0000-1000-8000-00805f9b34fb"

CMD_SYNC = bytes([0x01, 0x03])
CMD_TARGET_TEMP = bytes([0x31, 0x01, 0x00, 0x00])
CMD_CHANGE_UNIT = bytes([0x31, 0x02])
CMD_HOUR_HISTORY = bytes([0x31, 0x04])
CMD_MINUTE_HISTORY = bytes([0x31, 0x03])

STATE_NAMES = {
    0: "探头故障(报警)", 1: "离水断电(报警)", 2: "超温保护(报警)",
    3: "加热中", 4: "保温/其他", 5: "待机",
}


class BleWorker:
    """后台线程运行 asyncio 事件循环, 与 tkinter 主线程通过队列通信。"""

    def __init__(self, q: "queue.Queue"):
        self.q = q
        self.loop = None
        self.thread = None
        self.client = None
        self.mac = None

    def start(self):
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self._run_loop, daemon=True)
        self.thread.start()

    def _run_loop(self):
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    def submit(self, coro):
        asyncio.run_coroutine_threadsafe(coro, self.loop)

    def _notify(self, _char, data: bytearray):
        pkt = bytes(data)
        if pkt[:2] == b"\x30\x01":
            mode = pkt[2]
            unit = "C" if pkt[3] == 1 else "F"
            temp = ((pkt[6] << 8) | pkt[4]) / 10.0
            self.q.put(("current", temp, unit, STATE_NAMES.get(mode, "未知(%d)" % mode)))
        elif pkt[:2] == b"\x31\x01":
            temp = ((pkt[3] << 8) | pkt[2]) / 10.0
            self.q.put(("target", temp))
        elif pkt[:2] == b"\x30\x03":  # 小时历史
            self._history("hour", pkt)
        elif pkt[:2] == b"\x30\x02":  # 分钟历史
            self._history("minute", pkt)
        else:
            self.q.put(("log", "未识别数据: " + pkt.hex(" ")))

    def _history(self, kind, pkt):
        seg = pkt[2]
        body = pkt[3:]
        samples = []
        for i in range(0, len(body) - 1, 2):
            v = ((body[i] << 8) | body[i + 1]) & 0x0FFF
            samples.append(v / 10.0)
        self.q.put(("history", kind, seg, samples))

    async def _scan(self, timeout):
        try:
            devs = await BleakScanner.discover(timeout=timeout, return_adv=True)
            items = []
            for addr, val in devs.items():
                adv = val[1] if isinstance(val, tuple) else val
                name = adv.local_name or ""
                match = SERVICE_UUID in (adv.service_uuids or [])
                items.append((addr, name, adv.rssi, match))
            self.q.put(("scan_done", items))
        except Exception as e:
            self.q.put(("error", "扫描失败: %s" % e))

    def scan(self, timeout=8):
        self.q.put(("log", "正在扫描蓝牙设备 (%.0f 秒)..." % timeout))
        self.submit(self._scan(timeout))

    async def _scan_named(self, keyword, timeout):
        """按名称关键词长时扫描, 适合平时不广播/短时广播的设备。"""
        try:
            keyword_l = keyword.lower()
            found = []
            self.q.put(("log", "按名称 \"%s\" 搜索 (%.0f 秒)..." % (keyword, timeout)))
            devs = await BleakScanner.discover(timeout=timeout, return_adv=True)
            for addr, val in devs.items():
                adv = val[1] if isinstance(val, tuple) else val
                name = adv.local_name or ""
                if keyword_l in name.lower():
                    found.append((addr, name, adv.rssi, False))
            self.q.put(("name_found", keyword, found))
        except Exception as e:
            self.q.put(("error", "搜索失败: %s" % e))

    def scan_named(self, keyword, timeout=30):
        self.submit(self._scan_named(keyword, timeout))

    async def _connect(self, mac):
        try:
            self.client = BleakClient(mac, timeout=20.0)
            await self.client.connect()
            await self.client.start_notify(CHAR_UUID, self._notify)
            self.q.put(("connected", mac))
            await asyncio.sleep(1.0)
            await self._write(CMD_SYNC, "请求状态同步")
        except Exception as e:
            self.q.put(("error", "连接失败: %s (确认设备已开机且在范围内)" % e))

    def connect(self, mac):
        self.submit(self._connect(mac))

    async def _write(self, data, label):
        try:
            await self.client.write_gatt_char(CHAR_UUID, data, response=False)
        except Exception:
            await self.client.write_gatt_char(CHAR_UUID, data, response=True)
        self.q.put(("log", label))

    def set_temp(self, deg, unit):
        value = round(deg * 10)
        cmd = bytearray(CMD_TARGET_TEMP)
        cmd[2] = value & 0xFF
        cmd[3] = (value >> 8) & 0xFF
        self.q.put(("log", "设置目标温度 %.1f°%s" % (deg, "F" if unit == "F" else "C")))
        self.submit(self._write(bytes(cmd), ""))

    def toggle_unit(self):
        self.q.put(("log", "切换温度单位"))
        self.submit(self._write(CMD_CHANGE_UNIT, ""))

    def history(self, kind):
        self.q.put(("log", "请求%s历史..." % ("小时" if kind == "hour" else "分钟")))
        self.submit(self._write(CMD_HOUR_HISTORY if kind == "hour" else CMD_MINUTE_HISTORY, ""))

    def refresh(self):
        self.submit(self._write(CMD_SYNC, "请求状态同步"))

    async def _disconnect(self):
        try:
            if self.client and self.client.is_connected:
                await self.client.stop_notify(CHAR_UUID)
                await self.client.disconnect()
        except Exception:
            pass
        self.q.put(("disconnected",))

    def disconnect(self):
        self.submit(self._disconnect())


class App:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.q = queue.Queue()
        self.worker = BleWorker(self.q)
        self.worker.start()
        self.devices = []

        root.title("SHISON HEATER 蓝牙控制面板")
        root.geometry("760x600")
        root.minsize(640, 500)

        self._build_ui()
        self.root.after(100, self._poll)

    def _build_ui(self):
        pad = {"padx": 10, "pady": 5}

        # --- 连接区 ---
        top = ttk.LabelFrame(self.root, text=" 1. 扫描并连接 ")
        top.pack(fill="x", **pad)
        row = ttk.Frame(top)
        row.pack(fill="x", padx=8, pady=6)
        self.btn_scan = ttk.Button(row, text="扫描全部设备", command=self.on_scan)
        self.btn_scan.pack(side="left")
        ttk.Label(row, text="按名称搜:").pack(side="left", padx=(12, 2))
        self.var_search = tk.StringVar(value="")
        self.ent_search = ttk.Entry(row, textvariable=self.var_search, width=18)
        self.ent_search.pack(side="left")
        self.btn_search = ttk.Button(row, text="搜索", command=self.on_search)
        self.btn_search.pack(side="left", padx=4)
        self.lbl_conn = ttk.Label(row, text="未连接", foreground="#888")
        self.lbl_conn.pack(side="left", padx=12)

        self.list_dev = tk.Listbox(top, height=5, font=("Consolas", 10))
        self.list_dev.pack(fill="x", padx=8, pady=(0, 4))
        self.list_dev.bind("<<ListboxSelect>>", lambda e: self.btn_connect.config(state="normal"))

        row2 = ttk.Frame(top)
        row2.pack(fill="x", padx=8, pady=(0, 8))
        ttk.Label(row2, text="手动 MAC/名称:").pack(side="left")
        self.var_manual = tk.StringVar(value="")
        self.ent_manual = ttk.Entry(row2, textvariable=self.var_manual, width=22)
        self.ent_manual.pack(side="left", padx=4)
        self.btn_connect = ttk.Button(row2, text="连接", command=self.on_connect_manual)
        self.btn_connect.pack(side="left")

        # --- 状态区 ---
        st = ttk.LabelFrame(self.root, text=" 2. 设备状态 ")
        st.pack(fill="x", **pad)
        f = ttk.Frame(st)
        f.pack(fill="x", padx=8, pady=6)
        ttk.Label(f, text="当前温度", font=("Microsoft YaHei", 11)).grid(row=0, column=0, sticky="w")
        ttk.Label(f, text="目标温度", font=("Microsoft YaHei", 11)).grid(row=1, column=0, sticky="w")
        ttk.Label(f, text="工作状态", font=("Microsoft YaHei", 11)).grid(row=2, column=0, sticky="w")
        self.lbl_cur = ttk.Label(f, text="--", font=("Microsoft YaHei", 16, "bold"), foreground="#0a6")
        self.lbl_cur.grid(row=0, column=1, padx=20, sticky="w")
        self.lbl_tgt = ttk.Label(f, text="--", font=("Microsoft YaHei", 16, "bold"), foreground="#06a")
        self.lbl_tgt.grid(row=1, column=1, padx=20, sticky="w")
        self.lbl_state = ttk.Label(f, text="--", font=("Microsoft YaHei", 12), foreground="#a60")
        self.lbl_state.grid(row=2, column=1, padx=20, sticky="w")

        # --- 控制区 ---
        ct = ttk.LabelFrame(self.root, text=" 3. 控制 ")
        ct.pack(fill="x", **pad)
        f2 = ttk.Frame(ct)
        f2.pack(fill="x", padx=8, pady=6)
        ttk.Label(f2, text="目标温度:").pack(side="left")
        self.var_temp = tk.StringVar(value="26")
        sp = ttk.Spinbox(f2, from_=18, to=93, textvariable=self.var_temp, width=6, font=("Consolas", 11))
        sp.pack(side="left", padx=6)
        self.var_unit = tk.StringVar(value="C")
        ttk.Radiobutton(f2, text="℃", variable=self.var_unit, value="C").pack(side="left")
        ttk.Radiobutton(f2, text="℉", variable=self.var_unit, value="F").pack(side="left")
        self.btn_set = ttk.Button(f2, text="设置温度", command=self.on_set_temp, state="disabled")
        self.btn_set.pack(side="left", padx=12)
        self.btn_unit = ttk.Button(f2, text="切换单位", command=self.on_toggle_unit, state="disabled")
        self.btn_unit.pack(side="left", padx=4)
        self.btn_refresh = ttk.Button(f2, text="刷新状态", command=self.on_refresh, state="disabled")
        self.btn_refresh.pack(side="left", padx=4)
        self.btn_hist_h = ttk.Button(f2, text="小时历史", command=lambda: self.worker.history("hour"), state="disabled")
        self.btn_hist_h.pack(side="left", padx=4)
        self.btn_hist_m = ttk.Button(f2, text="分钟历史", command=lambda: self.worker.history("minute"), state="disabled")
        self.btn_hist_m.pack(side="left", padx=4)

        # --- 历史/日志区 ---
        lg = ttk.LabelFrame(self.root, text=" 4. 历史曲线 / 日志 ")
        lg.pack(fill="both", expand=True, **pad)
        self.txt = tk.Text(lg, height=8, font=("Consolas", 10), state="disabled", wrap="word")
        self.txt.pack(fill="both", expand=True, padx=8, pady=8)
        self.txt.tag_configure("info", foreground="#0a6")
        self.txt.tag_configure("warn", foreground="#a60")
        self.txt.tag_configure("err", foreground="#c00")

    # ---------- UI 回调 ----------
    def on_scan(self):
        self.btn_scan.config(state="disabled")
        self.worker.scan(8)

    def on_search(self):
        kw = self.var_search.get().strip()
        if not kw:
            messagebox.showwarning("提示", "请先输入要搜索的设备名称关键词。")
            return
        self.btn_search.config(state="disabled")
        self.worker.scan_named(kw, 30)

    def on_connect_manual(self):
        target = self.var_manual.get().strip()
        if not target:
            sel = self.list_dev.curselection()
            if not sel:
                return
            item = self.devices[int(sel[0])]
            target = item[0]
        # 支持输入 MAC (AA:BB:..) 或设备名
        import re
        if re.match(r"^[0-9A-Fa-f:]{17}$", target):
            self.btn_connect.config(state="disabled")
            self._log("正在连接 %s ..." % target, "warn")
            self.worker.connect(target)
        else:
            # 按名称尝试: 先短扫描找匹配, 找到就连接
            self._log("按名称 \"%s\" 查找并连接 (30秒)..." % target, "warn")
            self.btn_connect.config(state="disabled")
            self.worker.scan_named(target, 30)

    def on_set_temp(self):
        try:
            val = float(self.var_temp.get())
        except ValueError:
            messagebox.showwarning("输入错误", "温度值无效, 请输入数字。")
            return
        if val < 0 or val > 120:
            messagebox.showwarning("输入错误", "温度超出合理范围 (0~120)。")
            return
        self.worker.set_temp(val, self.var_unit.get())

    def on_toggle_unit(self):
        self.worker.toggle_unit()

    def on_refresh(self):
        self.worker.refresh()

    # ---------- 队列轮询 ----------
    def _poll(self):
        try:
            while True:
                msg = self.q.get_nowait()
                self._handle(msg)
        except queue.Empty:
            pass
        self.root.after(100, self._poll)

    def _handle(self, msg):
        kind = msg[0]
        if kind == "log":
            self._log(msg[1])
        elif kind == "error":
            self._log(msg[1], "err")
            self.btn_scan.config(state="normal")
            self.btn_connect.config(state="normal")
        elif kind == "scan_done":
            self.devices = msg[1]
            self.list_dev.delete(0, "end")
            if not self.devices:
                self.list_dev.insert("end", "(未发现设备 - 请确认设备已开机且在范围内)")
                self._log("扫描完成, 未发现设备。", "warn")
            else:
                for i, (addr, name, rssi, match) in enumerate(self.devices):
                    tag = " ★FFF0" if match else ""
                    disp = name if name else "(无名称)"
                    self.list_dev.insert("end", "%02d  %-14s  %-18s  %5s dBm%s" % (i + 1, disp, addr, rssi, tag))
                self._log("扫描完成, 发现 %d 台设备。若无名称设备也要显示, 已全部列出。" % len(self.devices), "info")
            self.btn_scan.config(state="normal")
            self.btn_search.config(state="normal")
        elif kind == "name_found":
            keyword, found = msg[1], msg[2]
            self.btn_search.config(state="normal")
            self.btn_connect.config(state="normal")
            if not found:
                self._log("按名称 \"%s\" 未搜索到设备。请确认: 设备已开机, 且处于可被搜索状态(部分设备需长按按键进入配对模式)。" % keyword, "warn")
            elif len(found) == 1:
                addr, name, rssi, _ = found[0]
                self._log("找到 \"%s\" (%s, %s dBm), 正在连接..." % (name or keyword, addr, rssi), "info")
                self.btn_connect.config(state="disabled")
                self.worker.connect(addr)
            else:
                self.devices = found
                self.list_dev.delete(0, "end")
                for i, (addr, name, rssi, _) in enumerate(found):
                    self.list_dev.insert("end", "%02d  %s  %s  %s dBm" % (i + 1, name, addr, rssi))
                self._log("找到 %d 台名称匹配设备, 请在列表中选中后点\"连接\"。" % len(found), "info")
        elif kind == "connected":
            mac = msg[1]
            self.lbl_conn.config(text="已连接: " + mac, foreground="#0a6")
            self._set_enabled(True)
            self._log("已连接, 等待设备上报状态...", "info")
        elif kind == "disconnected":
            self.lbl_conn.config(text="未连接", foreground="#888")
            self._set_enabled(False)
            self._log("已断开连接。")
        elif kind == "current":
            temp, unit, state = msg[1], msg[2], msg[3]
            self.lbl_cur.config(text="%.1f °%s" % (temp, unit))
            self.lbl_state.config(text=state)
        elif kind == "target":
            self.lbl_tgt.config(text="%.1f °C/°F" % msg[1])
        elif kind == "history":
            _, hkind, seg, samples = msg
            txt = "%s历史(段%d): " % ("小时" if hkind == "hour" else "分钟", seg)
            txt += " ".join("%.1f" % s for s in samples)
            self._log(txt, "info")
        else:
            pass

    def _set_enabled(self, on):
        state = "normal" if on else "disabled"
        for b in (self.btn_set, self.btn_unit, self.btn_refresh, self.btn_hist_h, self.btn_hist_m):
            b.config(state=state)

    def _log(self, text, tag=None):
        self.txt.config(state="normal")
        self.txt.insert("end", text + "\n", tag)
        self.txt.see("end")
        self.txt.config(state="disabled")

    def on_close(self):
        try:
            self.worker.disconnect()
            import time
            time.sleep(0.3)
        except Exception:
            pass
        self.root.destroy()


def main():
    try:
        root = tk.Tk()
    except Exception as e:
        ctypes.windll.user32.MessageBoxW(
            0, "无法创建图形窗口: %s\n\n请确认系统已安装桌面环境。" % e,
            "SHISON 控制面板", 0x10)
        sys.exit(1)
    app = App(root)
    root.protocol("WM_DELETE_WINDOW", app.on_close)
    # 测试钩子: SICN_GUI_TEST=1 时窗口 2 秒后自动关闭 (用于自动化验证)
    if os.environ.get("SICN_GUI_TEST") == "1":
        root.after(2000, app.on_close)
    root.mainloop()


if __name__ == "__main__":
    main()
