# linp.sensor_occupy.es4b 设备分析

> 日期: 2026-10-28 | 地址: A4:6D:33:B8:26:17 | RSSI: 约 -81 dBm
> 来源: 按名称搜索命中 + GATT 服务枚举（Windows bleak 3.0.2 / WinRT 后端，MTU 247）

## 结论

**`linp.sensor_occupy.es4b` 是领普（Linptech）人体存在/占用传感器（小米生态链设备），不是 SHISON 加热器。**

证据：
1. 设备名的构成是小米生态链标准格式 `厂商.产品.型号`（与本次扫描到的 `yeelink.switch.ylsw5`、`ftd.light.dsplmp` 同类）。
2. GATT 服务只有 `1800/1801` 标准服务 + **`FE95`（Xiaomi Inc. 私有服务）**，没有加热器的 `FFF0` 服务。
3. 特征布局与小米私有 BLE 设备完全一致（0x0004 固件版本 / 0x0005 密文数据通道 / 0x0010~0x001C 多个写+通知通道）。
4. 固件版本读回值 `32 2e 31 2e 32 5f 30 30 38 35...` = ASCII `"2.1.2_0085..."`。

## GATT 结构

| 服务 UUID | 特征 UUID | 属性 | 说明 |
|---|---|---|---|
| 1800 Generic Access | 2a00 | read | 设备名（空） |
| | 2a01 | read | Appearance = 0x0000 |
| | 2a04 | read | 连接参数 |
| 1801 Generic Attribute | 2a05 | indicate | 服务变更通知 |
| **fe95 Xiaomi Inc.** | 00000004 | read | 固件版本 = "2.1.2_0085..." |
| | 00000005 | notify+read | 小米密文数据通道（数据为空，需 MiBeacon 密钥） |
| | 00000010 | write-noresp+notify | 小米私有命令通道 |
| | 00000017 | notify+write | 小米私有命令通道 |
| | 00000018 | write-noresp+notify | 小米私有命令通道 |
| | 00000019 | write-noresp+notify | 小米私有命令通道 |
| | 0000001a | write-noresp+notify | 小米私有命令通道 |
| | 0000001b | write-noresp+notify | 小米私有命令通道 |
| | 0000001c | write-noresp+notify | 小米私有命令通道 |

## 为什么控制面板连不上

控制面板按 SHISON 协议去读写 `0000FFF1` 特征——该设备没有这个特征，故报
`Characteristic 0000fff1 ... was not found`。**这是预期行为，不是程序故障。**

## 要读取该传感器数据的现实路径

- 该设备工作依赖小米私有 MiBeacon 协议，且数据通道（0x0005 等）是**密文**，
  密钥保存在米家账号云端，直连 Windows 无法直接解密。
- 推荐路线（任选）：
  1. **米家 App / 小米网关**：传感器通过米家网关接入，查看占用状态最省事。
  2. **Home Assistant**：若传感器已绑定米家，用 `Xiaomi Miot Auto` 或
     `Xiaomi Gateway 3`（多模/中枢网关）集成读取；HA 的 BLE 直连同样受限于
     MiBeacon 密钥与绑定状态。
  3. 若坚持 Windows 直连读明文：需要先从米家账号抓取该设备的 MiBeacon 密钥
     （fe95 服务数据解析 + token），属高成本逆向，且小米可能不定期改协议。

## 附：本次连接失败的两种形态（排障记录）

- `Connection timed out` / `get_gatt_services_async 被取消`：设备进入休眠
  不响应，需在设备活跃窗口（触发感应/进入配对模式）重试。
- bleak 3.x 中 `connect(pair=...)` 关键字参数不存在（TypeError），配对用
  `client.pair()`。
