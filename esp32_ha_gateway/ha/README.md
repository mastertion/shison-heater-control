# SHISON 加热器 HA 接入说明 (ESP32 网关)

ESP32 刷 `esp32_ha_gateway/src/main.cpp` 固件后，通过 **MQTT Discovery 自动发现**，
Home Assistant **无需写任何自定义插件**，装上 MQTT 集成即可自动出现 4 个实体。

## 架构

```
SICN-HEATER-E84 (BLE)
        │  BLE 服务 FFF0 / 特征 FFF1
        ▼
   ESP32 网关固件            ← 扫描并连接加热器, 解析温度/模式
        │  WiFi + MQTT (订阅 sicn/set/*, 发布 sicn/tele)
        ▼
Home Assistant (Mosquitto 集成)
        │  MQTT Discovery 自动发现
        ▼
   4 个实体: 当前温度 / 目标温度 / 华氏单位开关 / 模式
```

## 第 1 步: HA 安装 MQTT 集成 (一次性)

1. HA → 设置 → 加载项 → 商店 → 安装 **Mosquitto broker**
2. 启动 Mosquitto，配置里确认 `port: 1883`（默认匿名开放）
3. HA → 设置 → 设备与服务 → 添加集成 → 搜索 **MQTT** → 填入 Mosquitto 地址 `core-mosquitto`（HAOS 内）或 HA 主机 IP
4. 完成。**不需要** 添加任何 YAML —— 实体由固件自动创建

> 如果启用了 Mosquitto 认证（anonymous: false），把用户名/密码填到固件
> `main.cpp` 顶部的 `MQTT_USER` / `MQTT_PASS`。

## 第 2 步: 编译烧录 ESP32

### 方式 A: PlatformIO（推荐）
1. 安装 VS Code + PlatformIO 扩展
2. 打开 `F:\开发\蓝牙设备\esp32_ha_gateway` 目录
3. 编辑 `src/main.cpp` 顶部配置:
   ```cpp
   const char* WIFI_SSID = "你的WiFi名";
   const char* WIFI_PASS = "你的WiFi密码";
   const char* MQTT_HOST = "192.168.1.100";   // 你的 HA 主机 IP
   ```
4. USB 连接 ESP32 → 点 **Upload and Monitor**（自动编译烧录 + 串口日志）

### 方式 B: Arduino IDE
1. 安装 ESP32 板支持（开发板管理器搜 esp32）
2. 库管理器安装 `PubSubClient` 和 `ArduinoJson`
3. 复制 main.cpp 内容到新工程，改配置后烧录

### 串口日志判断
```
[WiFi] 已连接, IP 192.168.1.x
[MQTT] 已连接, Discovery 已发布
[BLE] 开始扫描...
[BLE] 发现目标: SICN-HEATER-E84 (xx:xx) RSSI=-60
[BLE] 已连接, 通知已使能
[BLE] RX: 30 01 03 00 34 02 ...
```
看到 `RX: 30 01 ...` 即数据已通。

## 第 3 步: 检查 HA 实体

MQTT 集成添加后 30 秒内，HA 仪表盘「设备」里出现 **SICN 加热器**，含:

| 实体 | 类型 | 说明 |
|---|---|---|
| SICN 当前温度 | sensor | ℃，HA 温度单位设置可自动转 ℉ |
| SICN 目标温度 | number | 18~34℃，步进 0.5 |
| SICN 华氏单位 | switch | 开=设备显示℉，关=℃（仅切设备显示，HA 侧数值仍为℃） |
| SICN 模式 | sensor | 加热中/保温/待机/超温保护/离水断电/探头故障 |

之后即可在 HA 卡片、自动化、语音等任意地方控制加热器。

## 自动化示例 (configuration.yaml)

```yaml
automation:
  - alias: 夜间水温低于目标自动开加热
    trigger:
      - platform: numeric_state
        entity_id: sensor.sicn_当前温度
        below: 25
    action:
      - service: number.set_value
        target:
          entity_id: number.sicn_目标温度
        data:
          value: 28
```

## 注意事项

- 加热器一次只能被一个 BLE 客户端连接：ESP32 网关和手机 App **不要同时连**，否则会互相挤掉线
- 温度上报统一为 ℃（固件自动换算），HA 的 `unit_system` 设置决定最终显示
- 设备 5 分钟无操作会待机；固件每 10 秒 `01 03` 轮询保持唤醒推送
- 若加热器 MAC 变了（虚拟 MAC 现象），固件按名称 `SICN-HEATER-E84` 重扫即可找到
