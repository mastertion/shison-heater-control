# SHISON 加热器 HA 接入说明 (ESPHome 路线)

ESP32 已刷 ESPHome，用 `esphome/sicn_heater.yaml` 接入 Home Assistant。

**HA 侧无需写任何 YAML / 自定义插件** —— 实体由 ESPHome 集成自动发现。

## 架构



```
SICN-HEATER-E84 (BLE)
        │  BLE 服务 FFF0 / 特征 FFF1 (无偏移协议, 逆向实证)
        ▼
ESP32 (ESPHome 固件, sicn_heater.yaml)
        │  WiFi + ESPHome native API
        ▼
Home Assistant (ESPHome 集成)
        ▼
5 个实体: 当前温度 / 目标温度 / 华氏单位 / 模式 / 连接状态
```

## 第 1 步：把配置放进 ESPHome

你的 ESP32 已烧 ESPHome，配置文件放法二选一：



* **HAOS + ESPHome Addon（推荐）**：

1. HA → 设置 → 加载项 → 商店 → 打开 **ESPHome** → Web UI

2. 左侧 **Files** 页 → **上传** `sicn_heater.yaml`（或用「新建设备」后粘贴内容）

* **Samba 共享**：把文件放到 `\\你的HA主机IP\config\esphome\`

## 第 2 步：改配置（3 处必改）

在 ESPHome Web UI 里打开 `sicn_heater.yaml` 编辑：



```
wifi:
  ssid: "你的WiFi名"        # ① WiFi
  password: "你的WiFi密码"

ble_client:
  - id: sicn
    mac_address: "A4:6D:33:B8:26:17"   # ② 加热器当前 MAC (虚拟 MAC 会变!)
```



* **查 MAC**：手机开加热器 → 鸿蒙 App 点「扫描设备」弹窗里的地址；

  或 ESPHome 日志里看到 `SICN-HEATER-E84` 前的 `(xx:xx:xx:xx:xx:xx)`。

* 可选：`wifi` 下加 `manual_ip` 固定 IP（防重启漂移）。

## 第 3 步：编译安装

ESPHome Dashboard 上出现 **sicn-heater-gw** 卡片 → 点 **Install**：



* **USB**：ESP32 用数据线连电脑 → 选串口（COM 口）

* **OTA**：之前已烧过 ESPHome 且同一 WiFi → 直接 OTA，免拔线

等编译完成（首次 5\~10 分钟）并烧录成功。

## 第 4 步：确认 BLE 连上加热器

Dashboard 点 **Logs**，应看到：



```
[16:20:01] WiFi: 已连接, IP 192.168.1.50
[16:20:15] 加热器 BLE 已连接
[16:20:16] [BLE] RX: 30 01 03 00 34 02 ...
```

出现 `加热器 BLE 已连接` + `RX: 30 01` 即数据已通。

## 第 5 步: HA 添加 ESPHome 集成



1. HA → 设置 → 设备与服务 → 添加集成 → 搜索 **ESPHome**

2. 输入 `sicn-heater-gw.local`（或 Dashboard 里显示的 IP）

3. 完成 → 设备页出现 **SICN 加热器网关**

## 第 6 步：添加到仪表盘

编辑仪表盘 → 添加卡片 → 按实体：



| 实体                                     | 卡片类型     | 作用                  |
| -------------------------------------- | -------- | ------------------- |
| sensor.sicn\_加热器网关\_sicn\_当前温度         | 传感器 / 仪表 | 实时水温（℃，HA 单位设置可转 ℉） |
| number.sicn\_加热器网关\_sicn\_目标温度         | 实体       | 设目标 18\~34℃         |
| switch.sicn\_加热器网关\_sicn\_华氏单位         | 实体       | 切设备显示单位             |
| text.sicn\_加热器网关\_sicn\_模式             | 实体       | 加热 / 保温 / 待机等       |
| binary\_sensor.sicn\_加热器网关\_sicn\_连接状态 | 实体       | BLE 链路在线            |

## 自动化示例 (configuration.yaml 或 UI 自动化)



```
automation:
  - alias: 夜间水温低于 25 度自动升温到 28
    trigger:
      - platform: numeric_state
        entity_id: sensor.sicn_加热器网关_sicn_当前温度
        below: 25
    condition:
      - condition: time
        after: "18:00:00"
        before: "06:00:00"
    action:
      - service: number.set_value
        target:
          entity_id: number.sicn_加热器网关_sicn_目标温度
        data:
          value: 28
```

## 常见问题



| 现象             | 处理                                         |
| -------------- | ------------------------------------------ |
| 日志一直扫描找不到设备    | MAC 变了 → 手机 App 查当前 MAC → 改 yaml → 重装      |
| 连上又掉线          | 手机 App 同时在连 → 关掉 App 蓝牙控制                  |
| 温度不更新          | 检查日志是否 `RX: 30 01`；没有则重启网关等自动重连            |
| 切换华氏后目标变 28/83 | 已内置自动重写目标（600ms 后），等 1\~2 秒看 number 是否回写正确 |
| 想显示 ℉          | 不改实体：HA → 系统 → 单位 → 温度单位选华氏度（HA 自动换算显示）    |