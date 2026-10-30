# 诗彦加热棒（SHISON）· 鸿蒙蓝牙控制 App

用 HarmonyOS 手机通过蓝牙（BLE）直连控制 SHISON 加热棒。

> 协议来源：对原厂安卓控制 App 的 BLE 通信做了逆向分析（smali / arsc 解析），本 App 是其在鸿蒙端的完整移植。指令构造与通知解析集中在 `entry/src/main/ets/common/Protocol.ets`。

## 功能特性

- 蓝牙扫描附近设备，自动识别 SHISON 加热器（名称为 `SICN-HEATER-*` 或广播含 `FFF0` 服务）
- 实时显示当前温度与工作状态（加热中 / 保温 / 待机 / 探头故障 / 离水断电 / 超温保护）
- 设置目标温度：滑块、加减步进、快捷档位；支持 ℃ / ℉ 切换
- 拉取 24 小时 / 60 分钟历史温度，绘制曲线并统计最低 / 最高 / 平均
- 设备库：连接过的加热器自动记忆（支持多设备），可在扫描弹窗里一键连接或开关「自动连接」
- 自动重连：启动时优先连接标记为「自动连接」的设备，否则回退上次连接的设备（基于应用偏好存储）
- 三类报警（探头故障 / 离水断电 / 超温保护）触发独立报警页：脉冲动画 + 震动提醒，确认后返回
- 纯 ArkTS 实现，无第三方依赖；诊断日志写入应用沙箱文件，便于排查

## 运行环境

- DevEco Studio **26.x**（HarmonyOS 26 SDK，API 26）
- 华为手机 / 平板（HarmonyOS 7，API 26），已开启开发者模式与 USB 调试
- 系统权限：`ohos.permission.ACCESS_BLUETOOTH`（首次运行申请，inuse 场景）；报警震动需 `ohos.permission.VIBRATE`（普通权限，自动授予）
- 加热器已通电开机、与手机距离尽量 ≤ 1 米

## 工程信息

| 项 | 值 |
|---|---|
| bundleName | `com.zddz.app.sicn.ohos` |
| versionName / versionCode | `1.0.0` / `1000000` |
| 应用显示名 | 诗彦加热棒（SHISON HEATER）|
| compatibleSdk / targetSdk | `26.0.0` |
| 应用模型 | Stage 模型（stageMode）|
| 模块 | 单一 `entry` 模块 |

## 目录结构

```
sicn_ohos26/
├── AppScope/
│   ├── app.json5                 # bundleName、版本、应用图标/名称
│   └── resources/...             # 应用级图标
├── build-profile.json5           # 工程构建配置（products，API 26）
├── hvigorfile.ts / oh-package.json5
└── entry/
    ├── build-profile.json5       # 模块构建（stageMode，混淆关闭）
    ├── module.json5              # entry Ability、首页、蓝牙权限声明
    └── src/main/
        ├── ets/
        │   ├── entryability/
        │   │   └── EntryAbility.ets   # 标准 UIAbility，加载 pages/Index
        │   ├── common/
        │   │   ├── Protocol.ets       # 协议层：指令构造 + 通知解析
        │   │   ├── BleService.ets     # 蓝牙层：扫描/连接/写/订阅（容错封装）
        │   │   └── DeviceStore.ets    # 设备库：多设备记忆 + 自动连接（preferences 持久化）
        │   ├── model/
        │   │   └── HeaterModels.ets   # DeviceItem 模型 + 工作模式文案映射
        │   └── pages/
        │       ├── Index.ets          # 控制面板 UI 与全部交互逻辑
        │       └── AlarmPage.ets       # 报警页：探头故障/离水断电/超温保护（脉冲动画+震动）
        └── resources/...               # 字符串/颜色/图标/页面配置
```

## 编译与运行

1. 用 DevEco Studio 26 打开本仓库根目录，等待自动 Sync（确认 `compatibleSdkVersion = 26.0.0`）。
2. 配置签名：`File → Project Structure → Signing Configs`，勾选 **Automatically generate signature**（需登录华为账号并具备调试证书）。
   命令行构建产物为未签名 HAP，无法直接装机，须经 Studio 签名。
3. 手机 USB 连接并开启 USB 调试，DevEco 识别设备后点 `Run ▶` 安装运行；
   或 `Build → Build Hap(s)`，签名产物位于 `entry/build/default/outputs/default/entry-default-signed.hap`。

## 使用说明

| 操作 | 说明 |
|---|---|
| 扫描设备 | 打开设备选择弹窗列出附近 BLE 设备；名称含 `sicn`/`heater` 或广播含 `FFF0` 服务者标 `★ [FFF0 加热器]`，点击即连接 |
| 设温度 | 滑块（步进 ℃ 0.5 / ℉ 1）、`+ / -` 按钮或快捷档位（20/24/28/32/34℃ 或对应 ℉）；释放滑块或修改即下发 |
| 切单位 | 右上 `℃⇄` 按钮，℃ ↔ ℉ 切换，目标温度按物理换算跟随刷新 |
| 刷新 | 重新下发 `01 03` 触发设备推送当前状态 |
| 小时 / 分钟历史 | 请求历史采样，曲线追加并刷新最低/最高/平均统计 |
| 断开 | 断开 GATT 并释放资源 |
| 报警 | 设备上报探头故障 / 离水断电 / 超温保护时，自动弹出全屏报警页（脉冲动画 + 震动），点「我知道了」返回 |

状态区大字显示当前温度 / 目标温度 / 工作模式（颜色区分：加热中橙、故障或保护红、正常绿）。

连接建立后自动记录设备地址，下次启动 App 自动重连，无需重新扫描。在扫描弹窗的「已保存设备」区可看到历史连接过的所有加热器，点击「连接」即可直接连接，拨动开关可将其设为「自动连接」（下次优先自动重连该设备）。

## 通信协议（BLE）

- 服务 UUID：`0000FFF0-0000-1000-8000-00805f9b34fb`
- 特征 UUID：`0000FFF1-0000-1000-8000-00805f9b34fb`（可写 + 通知；CCCD `0x2902`）
- 连接时序：连接 → 使能 FFF1 通知（并写 CCCD `01 00`）→ 约 1.5s 后写 `01 03` 触发设备推送状态；若迟迟未收到推送，会在 6.5s / 11.5s 自动重发握手。首次握手后另主动读一次 FFF1 作为兜底。

### 下发指令（写 FFF1，优先带响应写，失败回退无响应写）

| 指令 | 说明 |
|---|---|
| `01 03` | 状态同步握手 |
| `31 01 LO HI` | 设目标温度：值 = `round(温度 × 10)`，小端填入。例：20.0℃ → 200(0x00C8) → `C8 00`。**无偏移协议**，设备 LCD 直接显示该温度 |
| `31 02` | 切换 ℃ / ℉ |
| `31 04` | 请求小时历史（设备响应 `30 03`）|
| `31 03` | 请求分钟历史（设备响应 `30 02`）|

> 实测修正：早期版本曾按安卓 App 的 `±64` / `×2-36` 偏移写入，导致 App 设 20℃ 而设备显示 84℃。现已确认这些偏移是安卓 App 自身的 UI 显示换算，并非设备协议——正确写法是直接 `温度 × 10`。

### 通知解析

| 通知 | 含义 |
|---|---|
| `30 01 MODE UNIT T_LO T_HI [...]` | 当前温度 = `(T_HI × 256 + T_LO) / 10`；`UNIT` 0=℃、1=℉；`MODE` 见下 |
| `31 01 LO HI` | 目标温度回显 = `(HI × 256 + LO) / 10`（无偏移，即真实温度）|
| `30 03 SEG [采样…]` | 小时历史：3 段 × 8 点 = 24 小时，每段 8 个采样 |
| `30 02 SEG [采样…]` | 分钟历史：8 段 × 8 点 = 60 分钟 |

- 历史采样：每 2 字节为一点，后字节为高字节，取低 12 位后 ÷10。
- 工作模式 `MODE`：0=探头故障、1=离水断电、2=超温保护、3=加热中、4=保温、5=待机。前三种会触发 App 顶部警报提示。

## 实现要点

- **扫描（API 26）**：优先 `ble.createBleScanner()` + `startScan`（官方推荐），失败自动回退旧 API `ble.startBLEScan`。过滤器按 `[{}]`（不过滤）→ `[{name:'SICN-HEATER-E84'}]` → `[{serviceUuid:FFF0}]` 逐级降级，规避鸿蒙 7 对过滤器校验多变导致的 `401`。
- **连接与特征定位**：`ble.createGattClientDevice` + 监听连接状态（15s 超时）；`getServices` 发现服务（8s 超时）后定位 FFF0/FFF1，并把完整 GATT 结构（服务/特征/描述符/属性）写入诊断日志。
- **通知使能**：订阅 `BLECharacteristicChange`，调用 `setCharacteristicChangeNotification`；后台再写 CCCD（`2902 = 01 00`）以开启设备端推送，失败会重试，确保不丢数据。
- **容错**：所有 BLE 调用均加 try/catch 与超时包装，异常经 `diagListener` 反馈到 UI / 文件，绝不闪退；扫描、连接、写均可失败重试。
- **诊断日志**：鸿蒙 7 对普通 App 的 `hilog` 写权限受限，诊断信息改为写入应用沙箱文件 `filesDir/sicn_log.txt`（可用 `hdc file recv` 导出）便于排查。
- **设备库与自动重连**：基于 `@kit.ArkData` 的 `preferences`（`sicn_pref`）持久化一个已保存设备列表（`DeviceStore.ets`，字段对齐安卓 `DeviceRecord`：地址 / 名称 / 自动连接 / 最近连接时间）。连接成功后自动 upsert 进设备库；启动时优先连接标记为「自动连接」的设备（取最近连接的一台），否则回退到旧版的 `last_addr` 记录。扫描弹窗内可查看已保存设备、一键连接或开关自动连接。
- **报警页**：设备上报 `MODE 0/1/2`（探头故障 / 离水断电 / 超温保护）时，经 `router` 跳转到独立 `AlarmPage`，播放脉冲动画并调用 `vibrator` 震动提醒（`ohos.permission.VIBRATE` 权限），用户确认后 `router.back()` 返回；同一报警只弹一次，返回后复位。

## 常见问题

- **扫描不到加热器**：确认加热器已通电开机、手机靠近（1 米内）；未广播时任何工具都搜不到。若报错含 `401/201`，请到 设置 → 应用 → 诗彦加热棒 → 权限，手动开启「附近设备 / 蓝牙」权限后重试。
- **连接失败 / 无 FFF0 服务**：设备并非 SHISON 加热器（例如某些小米生态链设备使用 FE95 服务，本 App 不支持），或距离过远 / 设备断电。靠近或重启加热器电源后重试。
- **设温度后设备显示不一致**：确保单位（℃/℉）与设备一致；本 App 已修正写入协议（直接 `温度×10`），如仍偏差请反馈诊断日志 `sicn_log.txt`。
- **需要真机**：BLE 功能无法在模拟器上测试。

## 相关

- 协议逆向参考：原厂安卓控制 App（BLE 通信 smali 分析）。
- Windows 控制端（独立仓库）：`sicn_control.py` / `sicn_gui.py`，与本案采用同一套协议。
