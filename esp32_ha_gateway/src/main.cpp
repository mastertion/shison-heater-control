/**
 * ============================================================
 * SHISON 加热器 (SICN-HEATER-E84) ESP32 BLE -> MQTT 网关固件
 * ============================================================
 * 职责:
 *   1. BLE 客户端连接加热器 (服务 FFF0 / 特征 FFF1, 协议与鸿蒙 App 逆向一致)
 *   2. 解析 3001(当前温度/模式/单位) 与 3101(目标温度), 统一换算成 ℃ 上报
 *   3. MQTT 发布状态 + Home Assistant MQTT Discovery 自动发现实体
 *   4. 订阅 HA 命令: 设目标温度 / 切单位 / 刷新
 *
 * 协议要点 (无偏移, 2026-10-30 实测):
 *   写目标: 编码 = 温度 × 10, 小端 [31 01 LO HI]
 *   切单位: [31 02];  刷新: [01 03]
 *   3001:   MODE UNIT T_LO T_HI -> 温度=(byte5*256+byte4)/10, UNIT 0=℃ 1=℉
 *   3101:   LO HI              -> 目标 = (byte3*256+byte2)/10 (直接显示)
 * ============================================================
 */

#include <WiFi.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <BLEDevice.h>
#include <BLEScan.h>
#include <BLEClient.h>
#include <BLEUtils.h>
#include <BLEAdvertisedDevice.h>

// ==================== 配置区 (烧录前必改) ====================
const char* WIFI_SSID   = "你的WiFi名";
const char* WIFI_PASS   = "你的WiFi密码";
const char* MQTT_HOST   = "192.168.1.100";   // HA 主机地址 (或 Mosquitto)
const int   MQTT_PORT   = 1883;
const char* MQTT_USER   = "";                 // HA 用户名 (Mosquitto 若启用了认证则填)
const char* MQTT_PASS   = "";
// 设备名过滤 (留空 = 按服务 UUID FFF0 匹配第一个)
const char* TARGET_NAME = "SICN-HEATER-E84";

#define SERVICE_UUID    "0000fff0-0000-1000-8000-00805f9b34fb"
#define CHAR_UUID       "0000fff1-0000-1000-8000-00805f9b34fb"
#define SCAN_TIME       12          // 扫描时长(秒)
#define POLL_INTERVAL   10000       // 状态轮询间隔(ms): 写 01 03 触发设备推送
#define CONNECT_ATTEMPTS_PER_SCAN 1
// ============================================================

// ---------- MQTT Topic ----------
#define TOPIC_TELE    "sicn/tele"              // 状态上报 {"temp":..,"target":..,"unit":"C","mode":..}
#define TOPIC_CMD_T   "sicn/set/target"        // 设目标温度, payload: "24.5"
#define TOPIC_CMD_U   "sicn/set/unit"          // 切单位, payload: "ON"(切℉) / "OFF"(切℃)
#define TOPIC_CMD_R   "sicn/set/refresh"       // 刷新, payload: 任意
#define TOPIC_AVAIL   "sicn/availability"      // LWT 在线状态 "online"/"offline"

WiFiClient wifiClient;
PubSubClient mqtt(wifiClient);

// ---------- BLE 状态 ----------
BLEClient*  bleClient = nullptr;
BLERemoteCharacteristic* bleChar = nullptr;
bool bleConnected = false;
bool bleReady = false;         // 特征已找到、通知已使能
unsigned long lastPoll = 0;

// ---------- 设备状态 ----------
float curTemp = 0;        // 当前温度 (设备单位)
int   curUnit = 0;        // 0=℃ 1=℉
int   curMode = 0;        // 0..5
float tgtTemp = 0;        // 目标温度 (设备单位)

static bool needReconnectBle = false;
static unsigned long lastConnAttempt = 0;
static bool mqttSentDiscovery = false;

// ---------- 工具 ----------
static String modeText(int m) {
  switch (m) {
    case 0: return "探头故障";
    case 1: return "离水断电";
    case 2: return "超温保护";
    case 3: return "加热中";
    case 4: return "保温";
    case 5: return "待机";
    default: return "未知";
  }
}

/** 统一换算到 ℃ (上报给 HA 用) */
static float toC(float v) {
  return curUnit == 1 ? (v - 32.0f) / 1.8f : v;
}

/** 构造并发布 MQTT Discovery 实体配置 (retained) */
static void publishDiscovery(const char* type, const char* uid, const char* payload) {
  String topic = String("homeassistant/") + type + "/sicn_heater_" + uid + "/config";
  mqtt.publish(topic.c_str(), payload, true);
}

static void publishDiscoveryAll() {
  // 当前温度 (℃)
  publishDiscovery("sensor", "cur_temp",
    "{\"name\":\"SICN 当前温度\",\"unique_id\":\"sicn_heater_cur_temp\","
    "\"state_topic\":\"sicn/tele\",\"value_template\":\"{{ value_json.temp }}\","
    "\"unit_of_measurement\":\"°C\",\"device_class\":\"temperature\","
    "\"availability_topic\":\"sicn/availability\",\"payload_available\":\"online\",\"payload_not_available\":\"offline\","
    "\"device\":{\"identifiers\":[\"sicn_heater\"],\"name\":\"SICN 加热器\",\"model\":\"SICN-HEATER-E84\"}}");
  // 目标温度 (number, 18~34℃ step 0.5)
  publishDiscovery("number", "target",
    "{\"name\":\"SICN 目标温度\",\"unique_id\":\"sicn_heater_target\","
    "\"command_topic\":\"sicn/set/target\",\"state_topic\":\"sicn/tele\","
    "\"value_template\":\"{{ value_json.target }}\",\"min\":18,\"max\":34,\"step\":0.5,"
    "\"unit_of_measurement\":\"°C\",\"device_class\":\"temperature\","
    "\"availability_topic\":\"sicn/availability\",\"payload_available\":\"online\",\"payload_not_available\":\"offline\","
    "\"device\":{\"identifiers\":[\"sicn_heater\"],\"name\":\"SICN 加热器\",\"model\":\"SICN-HEATER-E84\"}}");
  // 单位开关 (ON=℉ OFF=℃)
  publishDiscovery("switch", "unit",
    "{\"name\":\"SICN 华氏单位\",\"unique_id\":\"sicn_heater_unit\","
    "\"command_topic\":\"sicn/set/unit\",\"state_topic\":\"sicn/tele\","
    "\"value_template\":\"{{ 'ON' if value_json.unit == 'F' else 'OFF' }}\","
    "\"payload_on\":\"ON\",\"payload_off\":\"OFF\","
    "\"availability_topic\":\"sicn/availability\",\"payload_available\":\"online\",\"payload_not_available\":\"offline\","
    "\"device\":{\"identifiers\":[\"sicn_heater\"],\"name\":\"SICN 加热器\",\"model\":\"SICN-HEATER-E84\"}}");
  // 模式 (文本)
  publishDiscovery("sensor", "mode",
    "{\"name\":\"SICN 模式\",\"unique_id\":\"sicn_heater_mode\","
    "\"state_topic\":\"sicn/tele\",\"value_template\":\"{{ value_json.mode_text }}\","
    "\"icon\":\"mdi:heat-wave\","
    "\"availability_topic\":\"sicn/availability\",\"payload_available\":\"online\",\"payload_not_available\":\"offline\","
    "\"device\":{\"identifiers\":[\"sicn_heater\"],\"name\":\"SICN 加热器\",\"model\":\"SICN-HEATER-E84\"}}");
}

/** 发布状态 (统一 ℃) */
static void publishTele() {
  JsonDocument doc;
  doc["temp"]   = round(toC(curTemp) * 10) / 10.0;
  doc["target"] = round(toC(tgtTemp) * 10) / 10.0;
  doc["unit"]   = curUnit == 1 ? "F" : "C";
  doc["mode"]   = curMode;
  doc["mode_text"] = modeText(curMode).c_str();
  char buf[256];
  serializeJson(doc, buf);
  mqtt.publish(TOPIC_TELE, buf, false);
}

// ---------- BLE 写指令 ----------
static void bleWriteCmd(uint8_t* data, size_t len) {
  if (!bleChar) return;
  bleChar->writeValue(data, len, false);
}

/** 设目标温度: 编码 = 温度×10, 小端 [31 01 LO HI] */
static void bleSetTarget(float temp) {
  int v = (int)(temp * 10.0f + 0.5f);
  uint8_t cmd[4] = {0x31, 0x01, (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF)};
  bleWriteCmd(cmd, 4);
  Serial.printf("[BLE] 设目标 %.1f -> %02X %02X %02X %02X\n", temp, cmd[0], cmd[1], cmd[2], cmd[3]);
}

static void bleSwitchUnit() { uint8_t c[2] = {0x31, 0x02}; bleWriteCmd(c, 2); }
static void bleRefresh()    { uint8_t c[2] = {0x01, 0x03}; bleWriteCmd(c, 2); }

// ---------- 通知解析 ----------
static void notifyCallback(BLERemoteCharacteristic* ch, uint8_t* data, size_t len, bool isNotify) {
  if (len < 2) return;
  Serial.printf("[BLE] RX: ");
  for (size_t i = 0; i < len; i++) Serial.printf("%02X ", data[i]);
  Serial.println();

  if (data[0] == 0x30 && data[1] == 0x01 && len >= 6) {
    // 3001 MODE UNIT T_LO T_HI ...
    curMode = data[2];
    curUnit = data[3]; // 0=℃ 1=℉
    curTemp = (data[5] * 256 + data[4]) / 10.0f;
    publishTele();
  } else if (data[0] == 0x31 && data[1] == 0x01 && len >= 4) {
    // 3101 LO HI -> 目标
    tgtTemp = (data[3] * 256 + data[2]) / 10.0f;
    publishTele();
  }
}

// ---------- MQTT 命令 ----------
static void onMqtt(char* topic, byte* payload, unsigned int len) {
  payload[len] = 0;
  String t = String(topic);
  String p = String((char*)payload);
  Serial.printf("[MQTT] %s = %s\n", topic, p.c_str());

  if (t == TOPIC_CMD_T) {
    float c = p.toFloat();                       // HA 下发 ℃
    if (c < 5 || c > 60) return;
    // 设备 ℉ 档时先换算成 ℉ 再写 (无偏移编码)
    float writeTemp = (curUnit == 1) ? c * 1.8f + 32.0f : c;
    bleSetTarget(writeTemp);
  } else if (t == TOPIC_CMD_U) {
    bleSwitchUnit();
  } else if (t == TOPIC_CMD_R) {
    bleRefresh();
  }
}

// ---------- MQTT 连接 ----------
static bool mqttConnect() {
  if (mqtt.connected()) return true;
  Serial.print("[MQTT] 连接 ");
  Serial.println(MQTT_HOST);
  bool ok;
  if (MQTT_USER[0] != 0) {
    ok = mqtt.connect("sicn_esp32_gw", MQTT_USER, MQTT_PASS, TOPIC_AVAIL, 1, true, "offline");
  } else {
    ok = mqtt.connect("sicn_esp32_gw", TOPIC_AVAIL, 1, true, "offline");
  }
  if (ok) {
    mqtt.publish(TOPIC_AVAIL, "online", true);
    mqtt.subscribe(TOPIC_CMD_T);
    mqtt.subscribe(TOPIC_CMD_U);
    mqtt.subscribe(TOPIC_CMD_R);
    if (!mqttSentDiscovery) {
      publishDiscoveryAll();
      mqttSentDiscovery = true;
    }
    Serial.println("[MQTT] 已连接, Discovery 已发布");
  } else {
    Serial.printf("[MQTT] 失败 rc=%d\n", mqtt.state());
  }
  return ok;
}

// ---------- BLE 扫描回调 ----------
static void connectHeater(BLEAdvertisedDevice* adv);   // 前置声明

class ScanCB : public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice adv) override {
    if (bleConnected) return;
    String nm = String(adv.getName().c_str());
    bool nameMatch = (TARGET_NAME[0] != 0) && (nm.indexOf(TARGET_NAME) >= 0);
    bool svcMatch = adv.isAdvertisingService(BLEUUID(SERVICE_UUID));
    if (nameMatch || svcMatch || (TARGET_NAME[0] == 0 && svcMatch)) {
      Serial.printf("[BLE] 发现目标: %s (%s) RSSI=%d\n",
        adv.getName().c_str(), adv.getAddress().toString().c_str(), adv.getRSSI());
      adv.getScan()->stop();
      connectHeater(&adv);
    }
  }
};

// ---------- BLE 连接 ----------
static void connectHeater(BLEAdvertisedDevice* adv) {
  bleReady = false;
  bleClient = BLEDevice::createClient();
  Serial.printf("[BLE] 连接 %s ...\n", adv->getAddress().toString().c_str());
  if (!bleClient->connect(adv)) {
    Serial.println("[BLE] 连接失败");
    bleClient->disconnect();
    needReconnectBle = true;
    return;
  }
  bleConnected = true;
  Serial.println("[BLE] 已连接, 发现服务...");

  BLERemoteService* svc = bleClient->getService(BLEUUID(SERVICE_UUID));
  if (!svc) {
    Serial.println("[BLE] FFF0 服务未找到");
    bleClient->disconnect();
    needReconnectBle = true;
    return;
  }
  bleChar = svc->getCharacteristic(BLEUUID(CHAR_UUID));
  if (!bleChar) {
    Serial.println("[BLE] FFF1 特征未找到");
    bleClient->disconnect();
    needReconnectBle = true;
    return;
  }
  if (bleChar->canNotify()) {
    bleChar->registerForNotify(notifyCallback);  // 自动写 CCCD 2902
  }
  bleReady = true;
  lastPoll = millis();
  Serial.println("[BLE] 就绪, 通知已使能");
  delay(1000);
  bleRefresh();   // 首次握手 01 03
}

/** BLE 掉线/失败后清理, 交给主循环重新扫描 */
static void teardownBle() {
  bleReady = false;
  bleConnected = false;
  bleChar = nullptr;
  if (bleClient) {
    try {
      bleClient->disconnect();
    } catch (...) {}
    bleClient = nullptr;
  }
  needReconnectBle = true;
  Serial.println("[BLE] 已断开, 稍后重连");
}

// ---------- 主循环 ----------
void setup() {
  Serial.begin(115200);
  Serial.println("\n=== SICN ESP32 网关启动 ===");

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.print("[WiFi] 连接 ");
  int tries = 0;
  while (WiFi.status() != WL_CONNECTED && tries < 40) {
    delay(500);
    Serial.print(".");
    tries++;
  }
  Serial.println();
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("[WiFi] 已连接, IP %s\n", WiFi.localIP().toString().c_str());
  } else {
    Serial.println("[WiFi] 连接失败, 检查 SSID/密码");
  }

  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setCallback(onMqtt);
  mqttConnect();

  BLEDevice::init("SICN_GW");
  Serial.println("[BLE] 初始化完成");
}

void loop() {
  if (!mqtt.connected()) {
    mqttConnect();
  }
  mqtt.loop();

  // BLE 状态机
  if (!bleReady) {
    if (!bleConnected && millis() - lastConnAttempt > 8000) {
      lastConnAttempt = millis();
      BLEScan* scan = BLEDevice::getScan();
      scan->setAdvertisedDeviceCallbacks(new ScanCB(), true);
      scan->setActiveScan(true);
      scan->setInterval(100);
      scan->setWindow(99);
      Serial.println("[BLE] 开始扫描...");
      scan->start(SCAN_TIME, false);
    }
  } else {
    // 轮询刷新 (写 01 03 触发设备推送最新状态)
    if (millis() - lastPoll > POLL_INTERVAL) {
      lastPoll = millis();
      bleRefresh();
    }
    // 检测连接是否还活着
    if (!bleClient || !bleClient->isConnected()) {
      teardownBle();
    }
  }
  delay(50);
}
