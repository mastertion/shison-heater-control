# SHISON 加热器 ESP32 → Home Assistant 网关

让 `SICN-HEATER-E84` 电热器接入 Home Assistant 的 BLE 网关方案。

## 目录

```
esp32_ha_gateway/
├── platformio.ini        # PlatformIO 工程配置 (ESP32 Arduino)
├── src/
│   └── main.cpp          # 固件: BLE 连接 + 协议解析 + MQTT 上报/命令 + HA Discovery
└── ha/
    └── README.md         # HA 侧接入说明 (MQTT 集成 + 实体 + 自动化示例)
```

## 原理

- ESP32 作为 **BLE 客户端** 连接加热器（服务 `0000fff0-...` / 特征 `0000fff1-...`，协议与鸿蒙 App 逆向一致：无偏移编码，写目标 = 温度×10 小端 `31 01 LO HI`，切单位 `31 02`，刷新 `01 03`）
- 解析 `3001`（当前温度/模式/单位）与 `3101`（目标温度），**统一换算为 ℃** 后经 MQTT 发布
- 固件发送 **MQTT Discovery** 配置 → HA 自动创建实体，**零 YAML 自定义插件**
- 订阅 `sicn/set/target`、`sicn/set/unit`、`sicn/set/refresh` 命令写回设备

## 使用

1. 编辑 `src/main.cpp` 顶部：WiFi 名/密码、HA 主机 IP（必改）
2. PlatformIO 编译烧录（见 `ha/README.md` 第 2 步）
3. HA 安装 Mosquitto + MQTT 集成 → 自动出现 4 个实体

详细步骤、串口日志判断、自动化示例见 **[ha/README.md](ha/README.md)**。

## 实体清单 (MQTT Discovery 自动)

| 实体 | 类型 | 范围/步进 |
|---|---|---|
| 当前温度 | sensor | ℃（HA 单位设置可转 ℉） |
| 目标温度 | number | 18~34 ℃ / 0.5 |
| 华氏单位 | switch | 设备显示单位切换 |
| 模式 | sensor | 加热/保温/待机/超温/离水/探头故障 |

## 协议速查（与鸿蒙 App 实测一致）

| 指令 | HEX | 说明 |
|---|---|---|
| 刷新握手 | `01 03` | 触发设备推送状态 |
| 写目标 | `31 01 LO HI` | 值 = 温度×10，小端 |
| 切单位 | `31 02` | 0=℃ 1=℉ |
| 状态 | `30 01 MODE UNIT T_LO T_HI` | 温度=(byte5*256+byte4)/10 |
| 目标回显 | `31 01 LO HI` | 目标=(byte3*256+byte2)/10，无偏移 |

## 限制

- 加热器同一时间只允许一个 BLE 客户端，网关与手机 App 勿同时连接
- 本工程源码基于逆向分析，仅供个人设备控制使用
