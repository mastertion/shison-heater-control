# SHISON 加热器 鸿蒙 App (sicn_ohos)

用 HarmonyOS 手机直接蓝牙控制 SHISON 加热器。协议与 Windows 版
(`sicn_control.py` / `sicn_gui.py`) 完全一致，逻辑为逐行移植。

## 环境要求

- DevEco Studio 5.0 及以上（HarmonyOS NEXT，SDK API 12）
- 华为手机（HarmonyOS NEXT 5.0+），开启开发者模式
- 手机与加热器距离 ≤ 10 米，加热器通电开机

## 导入步骤

1. 打开 DevEco Studio → `File → Open`，选择本目录 `F:\开发\蓝牙设备\sicn_ohos`
2. 首次打开自动 Sync；若提示 SDK 版本，在 `File → Project Structure` 确认
   `compatibleSdkVersion = 5.0.0(12)`
3. 签名：`File → Project Structure → Signing Configs` → 勾选自动签名
   （需登录华为账号并开通调试证书；或使用你自己的签名配置）
4. 手机连 USB（开启 USB 调试），DevEco 识别设备后点 `Run ▶`

## 使用说明

| 操作 | 说明 |
|---|---|
| 扫描设备 | 列出附近 BLE 设备，`★ [FFF0 加热器]` 标记的就是本协议设备（名称通常是 SICN-HEATER-XXXX），点击即连接 |
| 设温度 | 输入目标温度（℃，或 ℉ 需与设备当前单位一致）→ 点"设温度" |
| 切单位 | 切换设备 ℃/℉ 显示单位 |
| 刷新 | 重新触发设备推送当前状态 |
| 小时/分钟历史 | 请求历史温度采样，数据追加到下方日志 |
| 断开 | 断开并释放 GATT |

状态大字区：当前温度 / 目标温度 / 工作模式
（加热中 / 保温 / 待机 / 探头故障 / 离水断电 / 超温保护）。

## 协议摘要（与 Windows 版一致）

- 服务 `0000FFF0-...`，特征 `0000FFF1-...`（写 + 通知，CCCD 0x2902）
- 连接时序：连接 → 使能 FFF1 通知 → 延时 1000ms → 写 `01 03`
- 指令（全部写 FFF1，优先 no-response 写，失败回退标准写）：
  - `01 03` 状态同步握手
  - `31 01 LO HI` 设目标温度：值 = round(温度×10)，小端
    （26.0℃ → 260 → `31 01 04 01`）
  - `31 02` 切换单位；`31 04` 小时历史（响应 `30 03`）；
    `31 03` 分钟历史（响应 `30 02`）
- 通知解析：
  - `3001 MODE UNIT T_LO ?? T_HI ??` → 当前温度 = (T_HI×256+T_LO)/10，
    UNIT 0=℉ 1=℃；MODE 0=探头故障 1=离水断电 2=超温保护 3=加热中
    4=保温 5=待机
  - `3101 LO HI` → 目标温度回显 = (HI×256+LO)/10
  - `30 03 / 30 02 SEG [采样…]` → 历史：采样 2 字节取低 12 位 ÷10，
    每段 8 个采样

实现位置：`entry/src/main/ets/common/Protocol.ets`（协议）、
`common/BleService.ets`（BLE 封装）、`pages/Index.ets`（界面）。

## 常见问题

- **扫描不到加热器**：确认加热器通电开机、手机距离足够近；
  加热器不广播时任何工具都搜不到（Windows 版同样）。
- **连接失败 / 没有 FFF0 服务**：设备不是 SHISON 加热器
  （例如小米生态链设备如 `linp.sensor_occupy.es4b` 用的是 FE95 服务，
  本 App 不支持）。
- **点击"扫描"闪退（鸿蒙 NEXT 7）**：已修复。旧版扫描调用缺少异常保护，
  新版对全部 BLE 调用做了 try/catch，扫描失败会在日志区显示具体错误文字，
  不再闪退。若仍失败，把日志区文字发我。
- **设温度无反应**：确认单位与设备一致；温度会以 `3101` 回显确认。
- **需要真机**：BLE 功能无法在模拟器上测试。

## 生成可安装的签名版（重要）

命令行构建产出的是 **unsigned HAP，无法直接装机**（鸿蒙要求签名）。
请用 DevEco Studio 一键签名装机：

1. `File → Open` 打开本目录（`F:\开发\蓝牙设备\sicn_ohos`）
2. `File → Project Structure → Signing Configs` → 勾选 **Automatically generate
   signature**（使用本机已配置的华为调试证书，位于 `C:\Users\13798\.ohos\config`）
3. 连接手机（USB 调试）→ 点 **Run ▶** 直接装机运行；
   或 `Build → Build Hap(s)` 生成已签名 HAP（输出在
   `entry/build/default/outputs/default/entry-default-signed.hap`）

## 文件结构

```
sicn_ohos/
├── AppScope/                  # 应用级配置 (bundleName, 图标)
├── build-profile.json5        # 工程构建配置 (API 12)
├── hvigorfile.ts / oh-package.json5
└── entry/
    ├── build-profile.json5 / hvigorfile.ts / oh-package.json5
    └── src/main/
        ├── module.json5       # 权限: ACCESS_BLUETOOTH
        ├── ets/
        │   ├── entryability/EntryAbility.ets
        │   ├── common/Protocol.ets      # 指令构造 + 通知解析
        │   ├── common/BleService.ets    # 扫描/连接/写/订阅
        │   ├── model/HeaterModels.ets   # 设备与状态模型
        │   └── pages/Index.ets          # 控制面板
        └── resources/         # 字符串/颜色/图标/页面配置
```
