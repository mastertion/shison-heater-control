# SHISON HEATER 蓝牙协议逆向分析报告

> 对象：`sicn.apk`（v1.55，包名 `com.zddz.app.sicn`，应用名 SHISON HEATER）
> 目标：解析 App 与加热器之间的 BLE 通信协议，在 Windows 上用 Python（bleak）实现同等控制能力
> 方法：APK 解包 → dex 反汇编（androguard）→ 逐类还原指令、UUID、字节序与状态含义

---

## 1. 结论速览

设备是 **BLE 加热器**（电热/水暖类），App 通过单服务单特征与其通信：

| 项目 | 值 |
|---|---|
| GATT 服务 UUID | `0000FFF0-0000-1000-8000-00805F9B34FB` |
| GATT 特征 UUID | `0000FFF1-0000-1000-8000-00805F9B34FB`（写入 + 通知） |
| 连接握手 | 连接 → 使能 FFF1 通知 → 延时 1s → 写 `01 03` |
| 温度编码 | 当前温度 = 原始值 ÷ 10，小端 2 字节（高字节在后） |
| 目标温度写入 | `31 01 LO HI`；℃档 value=(温度+64)×10，℉档 value=(温度+36)×5 |
| 目标温度回显 | `3101 LO HI`；℃档显示=raw/10-64，℉档显示=2×raw/10-36 |
| 单位切换 | 写 `31 02`；`3001` 的 byte3：0=℃ 1=℉ |
| 历史曲线 | 写 `31 04` 取小时历史；写 `31 03` 取分钟历史；采样后字节为高、低12位÷10 |

配套交付：`sicn_control.py`（Windows 可运行的控制脚本）。

---

## 2. 反编译依据（关键类 → 结论）

### 2.1 `com.zddz.app.sicn.OrderSet`（指令集常量）

```
write_synchronize           = [0x01, 0x03]
write_target_temperature    = [0x31, 0x01, 0x00, 0x00]   // 后 2 字节运行时填温度
write_change_temperature_type = [0x31, 0x02]
write_minute_data           = [0x31, 0x03]
write_hour_data             = [0x31, 0x04]
notice_current_temperature  = "3001"
notice_minute_data          = "3002"     // 注意: 字符串为 "3002"（分钟历史响应）
notice_hour_data            = "3003"     // 字符串为 "3003"（小时历史响应）
notice_target_temperature   = "3101"
FFF0 / FFF1 为上述两个标准 16 位 UUID
```

**注意**：`notice_minute_data`/`notice_hour_data` 的字符串与直觉相反——`3002` 是分钟历史、`3003` 是小时历史（在 `HistoryDialog.notice()` 中验证：以 `notice_hour_data` 开头的通知按"小时段"解析）。

### 2.2 `com.zddz.bt.BtService`（GATT 封装）

- `writeCharacteristic(addr, FFF0, FFF1, data)`：所有指令统一写 FFF1，不强制写类型（沿用特征默认属性）。
- `setCharacteristicNotification`：标准 CCCD 使能通知。
- 扫描过滤：`buildScanFilters` 按**厂商数据（Manufacturer Data）**匹配历史设备（重连用）；首次连接在 `ScanFragment` 中列出全部可见 BLE 设备供用户选择，**无设备名过滤**。
- 通知经 Handler（`MainActivity$3`，what=4）原样转发给 `MainFragment.notice()`。

### 2.3 连接时序（`MainActivity$3` + `MainActivity$3$1`）

1. 扫描到设备 → 点击 → `discoverServices(address)`
2. 服务发现完成（what=3）→ `setCharacteristicNotification(addr, FFF0, FFF1, true)`
3. 延迟 **1000ms** → `writeCharacteristic(addr, FFF0, FFF1, [0x01, 0x03])`（同步握手）
4. 此后设备主动推送状态：`3001…` 当前温度、`3101…` 目标温度

### 2.4 当前温度通知 `3001`（`MainFragment.notice`）

```
字节: 30 01 MODE UNIT T_LO T_HI [扩展...]
解析: 当前温度 = (T_HI × 256 + T_LO) ÷ 10   // 安卓: substring(10,12)+substring(8,10), 高字节在后
     UNIT: 0 = ℃，1 = ℉   ← 2026-10-29 用户实测确认 (旧报告 0=℉ 1=℃ 为反)
     MODE (byte2):
       0 = 探头故障（AlarmActivity type=1，红色告警）
       1 = 离水断电（AlarmActivity type=0）
       2 = 超温保护（AlarmActivity type=2）
       3 = 加热中（青色文本 + 温度计动画）
       4 = 保温（绿色）
       5 = 待机（蓝色）
```

> 实测例：`30 01 00 01 00 03 01` = byte4=0x00 byte5=0x03 → 3.0℃；`30 01 00 01 00 00` = 0.0℃。
> 当前温度**不**做 ±64 偏移（设备按当前单位直接推真实温度）。

### 2.5 目标温度通知 `3101` 与写入换算（2026-10-29 修正，smali 逐行实证）

**写入侧**（`MainFragment$2` 加减按钮 + `MainFragment$3` SeekBar，`Convert.intToBytes4Little` 小端）：

| 单位档 | SeekBar max | 写值公式 | 等价式 |
|---|---|---|---|
| ℃ (level=0) | 32 | progress×10 + 640 | **(温度℃ + 64) × 10** |
| ℉ (level=1) | 29 | progress×5 + 180 | **(温度℉ + 36) × 5** |

例：设 26.0℃ → (26+64)×10 = 900 = 0x0384 → `31 01 84 03`；设 77.0℉ → (77+36)×5 = 565 = 0x0235 → `31 01 35 02`。

**回显侧**（`3101 LO HI`，安卓 431-466 行）：
```
raw = (HI×256 + LO) ÷ 10     // substring(6,8)+substring(4,6), 高字节在后
℃ 档显示 = raw - 64
℉ 档显示 = 2 × raw - 36
```
验证互逆：写 26℃ (900) → raw=90 → 90-64 = 26.0℃ ✓；写 77℉ (565) → raw=56.5 → 2×56.5-36 = 77.0℉ ✓。

> ⚠️ 旧报告"value = 温度×10"为错误结论（当时未深读 smali 写值公式），已按安卓实证修正。

**±1 步进**（`MainFragment$2`）：progress∓1 后按上表公式换算写入；下限 progress≤0 时忽略，上限 progress≥max 时忽略。

**切单位**（`MainFragment$2` 点击 2131231273 → 写 `31 02`）：设备切换后推 `3001`（byte3 变化），App 据 byte3 刷新单位图标、SeekBar max 与温度计类型。

### 2.6 历史曲线 `3002`/`3003`（`HistoryDialog`）

- 写 `31 04`（=`write_hour_data`，请求小时历史）→ 设备回 `3003` 开头；写 `31 03`（=`write_minute_data`）→ 回 `3002` 开头。安卓点击"小时/分钟"tab 时**只写命令不带段号**，直接解析设备回包。
- 包结构：`30 03 SEG [采样×8]`（固定每段 8 个采样）。
- 每个采样 2 字节，**后字节为高字节**（安卓 `substring(10,12)+substring(8,10)`），取 16bit **低 12 位** ÷10：
  `raw = (byte_odd << 8) | byte_even; value = (raw & 0x0FFF) ÷ 10`
- 安卓显示换算：℃ 档原样显示；℉ 档 `×0.95 + 40`（HistoryDialog 152-156 行，与主界面公式不同，待实测核对）。
- 统计：HistoryDialog 汇总 min/max/avg（浮点 0.0 起步），负值/异常采样跳过。

### 2.7 报警类型（`AlarmActivity`）

三类报警与 `3001` MODE 0/1/2 一一对应（探头故障/离水断电/超温保护），点击警报横幅进入对应告警动画页。

### 2.8 蓝牙状态与主界面（`MainFragment.changeBtState` / `onCreateView`）

- 连接成功：蓝牙图标 level=1 + 绿色"已连接" + 关闭扫描弹窗；断开：level=0 + 红色。
- UI 组件清单：`ll_bluetooth`(扫描/连接)、`uiv_bluetooth`(状态图标)、`tv_state`(状态文本)、`uiv_temperature_type`(单位图标)、`tmr_current`(温度计动画)、`tv_current_temperature`、`tv_current_mode`、`tv_target_temperature`、`uiv_sub`/`uiv_add`(±1)、`bar_target_temperature`(SeekBar)、`tv_history`(历史入口)。

---

## 3. Windows 实现要点

- 库：`bleak`（Windows 后端走 WinRT 原生 BLE，无需额外驱动），`pip install bleak`。
- 连接：`BleakClient(设备MAC)` → `start_notify(FFF1)` → 写 `01 03`。
- 写入方式：优先无响应写（`response=False`），失败回退带响应写——对应 App 不设置写类型的做法。
- 扫描：用 `service_uuids=[FFF0]` 精确匹配本设备；首次使用可用 `scan` 子命令先看设备列表。

## 4. 交付物

| 文件 | 说明 |
|---|---|
| `启动控制台.bat` | **双击即用**的启动器（无控制台黑窗，直接弹出图形控制面板） |
| `sicn_gui.py` | **图形控制面板**（推荐，双击后所见即所得） |
| `sicn_control.py` | 命令行控制脚本（scan / status / temp / unit / history 子命令 + 交互菜单） |
| `analysis/` | 反编译中间产物（smali 反汇编、脚本、字符串池等） |

## 5. 使用

**方式一（推荐，双击）**：双击 `启动控制台.bat` → 直接弹出**图形控制面板**（`sicn_gui.py`），无需命令行操作：
扫描设备 → 选设备连接 → 实时显示当前温度/目标温度/工作状态 → 设置温度/切换单位/查看小时分钟历史。
> bat 会自动绕过 Windows 应用商店的 python 占位程序（app execution alias），直接使用真实安装的 Python；若本机未装 Python 会给出安装提示。

**方式二（命令行）**：

```
pip install bleak
python sicn_control.py scan
python sicn_control.py status --mac AA:BB:CC:DD:EE:FF
python sicn_control.py temp --mac AA:BB:CC:DD:EE:FF --value 26 --unit C
python sicn_control.py unit --mac AA:BB:CC:DD:EE:FF
python sicn_control.py history --mac AA:BB:CC:DD:EE:FF --kind hour
```

> 无参数直接运行 `python sicn_control.py` 也会进入交互菜单。

## 6. 已知待确认项

- `3001` 包中 byte5 之后的多余字节用途未知（设备推送包长 6-7 字节，扩展位疑似校验/固定 0x00）。
- 历史 ℉ 档换算 `×0.95+40` 与主界面 `2×raw-36` 不一致，待设备实测核对（鸿蒙版暂按原始值显示）。
- 分钟历史段号语义与包长上限未实测（以设备实际响应为准）。
- 温度单位切换（31 02）后设备回显单位随之变化，App 以 3001 的 byte3 为准。
- 3101 回显换算基准 = 当前单位档位（℃ 档 -64 / ℉ 档 2×-36），切单位后旧回显按新档换算可能短暂错位（安卓同样行为）。

## 7. 鸿蒙 App 功能对照（2026-10-29 v26.17）

| 安卓原版功能 | 鸿蒙版实现 | 状态 |
|---|---|---|
| 当前温度 (3001) | byte5×256+byte4 ÷10 | ✅ v26.16 修正 |
| 单位显示 (3001 byte3) | 0=℃ 1=℉ | ✅ v26.17 翻转 |
| 目标温度显示 (3101) | ℃=raw-64 ℉=2×raw-36 | ✅ v26.17 |
| 设目标温度 (31 01) | ℃=(T+64)×10 ℉=(T+36)×5 | ✅ v26.17 |
| ±1 步进按钮 | -1/+1 按钮 | ✅ v26.17 |
| 切换单位 (31 02) | 切单位按钮 | ✅ |
| 刷新状态 (01 03) | 刷新按钮 | ✅ |
| 小时/分钟历史 (31 04/31 03) | 双按钮 + min/max/avg 统计 | ✅ v26.17 修正字节序 |
| 模式状态 6 种 | 文案+颜色 | ✅ |
| 三类警报 (AlarmActivity) | Toast 警报提示 | ✅ v26.17 |
| 温度计动画/SeekBar 滑条 | 数字输入代替 | 未实现(UI 差异) |
