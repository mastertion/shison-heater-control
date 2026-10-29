# SHISON 加热器 ESP32 → Home Assistant 网关

让 `SICN-HEATER-E84` 电热器接入 Home Assistant 的 BLE 网关方案。

## 目录



```
esp32_ha_gateway/
├── esphome/
│   └── sicn_heater.yaml     # ★ 推荐: ESPHome 配置 (BLE Client + 实体, HA 零插件自动发现)
├── src/
│   └── main.cpp             # 备选: Arduino/PlatformIO 固件 (BLE + MQTT + Discovery)
├── platformio.ini           # Arduino 备选方案工程配置
└── ha/
    └── README.md            # HA 侧接入说明 (MQTT 方案)
```

## 两条路线



|       | **ESPHome (推荐，你已刷)**       | Arduino MQTT (备选) |
| ----- | -------------------------- | ----------------- |
| 文件    | `esphome/sicn_heater.yaml` | `src/main.cpp`    |
| HA 集成 | 原生 ESPHome, 自动发现           | MQTT Discovery    |
| 改动量   | 只改 yaml 重编译                | 改 C++ 重编译         |
| 维护    | ESPHome 生态，官方更新            | 自维护               |

## ESPHome 快速上手



1. 把 `esphome/sicn_heater.yaml` 放入 ESPHome 配置目录（HAOS 的 `/config/esphome/`，或 ESPHome Dashboard config 目录）

2. 改三处：`wifi.ssid` / `wifi.password` / `ble_client.mac_address`

3. **MAC 是虚拟的会变**：先用手机 App 或 ESPHome 日志确认加热器当前地址（如 `A4:6D:33:B8:26:17`），烧录后若连不上再重查更新

4. ESPHome Dashboard → Install → 编译上传

5. HA → 设置 → 设备与服务 → 添加集成 **ESPHome** → 自动发现 **SICN 加热器网关**

## ESPHome 实体 (自动)



| 实体        | 类型             | 说明                                 |
| --------- | -------------- | ---------------------------------- |
| SICN 当前温度 | sensor         | ℃（HA 单位设置可转 ℉）                     |
| SICN 目标温度 | number         | 18\~34 ℃ / 步进 0.5                  |
| SICN 华氏单位 | switch         | 设备显示单位切换（切后自动重写目标，防重置 28/83）       |
| SICN 模式   | text\_sensor   | 加热中 / 保温 / 待机 / 超温保护 / 离水断电 / 探头故障 |
| SICN 连接状态 | binary\_sensor | BLE 链路在线状态                         |

协议速查见下方；详细 HA 侧说明见 `ha/README.md`。

## 协议速查（与鸿蒙 App 实测一致）



| 指令   | HEX                         | 说明                            |
| ---- | --------------------------- | ----------------------------- |
| 刷新握手 | `01 03`                     | 触发设备推送状态                      |
| 写目标  | `31 01 LO HI`               | 值 = 温度 ×10，小端                 |
| 切单位  | `31 02`                     | 0=℃ 1=℉                       |
| 状态   | `30 01 MODE UNIT T_LO T_HI` | 温度 =(byte5\*256+byte4)/10     |
| 目标回显 | `31 01 LO HI`               | 目标 =(byte3\*256+byte2)/10，无偏移 |

## 限制



* 加热器同一时间只允许一个 BLE 客户端，网关与手机 App 勿同时连接

* 本工程源码基于逆向分析，仅供个人设备控制使用