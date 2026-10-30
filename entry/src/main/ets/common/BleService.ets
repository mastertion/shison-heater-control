/**
 * BLE 服务封装 (HarmonyOS 7 / API 26, ConnectivityKit)
 *
 * API 26 扫描: 官方推荐 BleScanner 多路扫描 (createBleScanner + startScan),
 *   startScan 的 filters 传 null 表示不过滤 (API 15+ 文档明确允许)。
 * 连接: createGattClientDevice + getServices + writeCharacteristicValue (API 26 未变)。
 *
 * 所有调用均做异常保护, 失败通过 onError 回调交给 UI 显示, 绝不闪退。
 */

import { access, ble, constant } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SERVICE_UUID, CHAR_UUID } from './Protocol';

const TAG = 'SICN-BLE';
const CONNECT_TIMEOUT_MS = 12000;
const GATT_TIMEOUT_MS = 8000;
/** 连接重试次数: 升级/重装后系统侧常残留旧 GATT 连接, 首次 connect 会被拒或超时 */
const CONNECT_MAX_ATTEMPT = 3;

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 给 Promise 加超时, 超时 reject, 避免 UI 无限等待 */
function withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer: number = setTimeout(() => {
      reject(new Error(what + ' 超时 (' + ms + 'ms)'));
    }, ms);
    p.then((v: T) => {
      clearTimeout(timer);
      resolve(v);
    }).catch((e: Error) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

/** 字节转大写十六进制字符串 (日志用) */
function bytesToHexLog(b: Uint8Array): string {
  let s = '';
  for (let i = 0; i < b.length; i++) {
    s += b[i].toString(16).padStart(2, '0').toUpperCase() + ' ';
  }
  return s.trim();
}

export class BleService {
  private static gatt: ble.GattClientDevice | undefined = undefined;
  private static ch: ble.BLECharacteristic | undefined = undefined;
  private static scanner: ble.BleScanner | null = null;
  /** 诊断日志回调: 鸿蒙7 系统 hilog 对普通 App 封闭(write socket failed), 改为回调到 UI/文件 */
  static diagListener: ((s: string) => void) | null = null;

  private static diag(s: string): void {
    if (BleService.diagListener) {
      try {
        BleService.diagListener(s);
      } catch (e) {
        // 忽略
      }
    }
  }

  /** 检查本机蓝牙是否开启 */
  static isBluetoothOn(): Promise<boolean> {
    return Promise.resolve().then(() => {
      try {
        const state: access.BluetoothState = access.getState();
        return state === access.BluetoothState.STATE_ON ||
          state === access.BluetoothState.STATE_BLE_ON;
      } catch (e) {
        hilog.error(0x0000, TAG, 'getState failed: %{public}s', JSON.stringify(e));
        return false;
      }
    });
  }

  /** 请求蓝牙权限 (HarmonyOS NEXT 统一使用 ACCESS_BLUETOOTH) */
  static async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(context,
        ['ohos.permission.ACCESS_BLUETOOTH']);
      let ok = true;
      for (const g of result.authResults) {
        if (g !== 0) {
          ok = false;
        }
      }
      return ok;
    } catch (e) {
      hilog.error(0x0000, TAG, 'requestPermission failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /**
   * 查询 ACCESS_BLUETOOTH 的实际授权状态 (用于诊断).
   * @returns 如 "granted" / "denied" / "check_error:xxx"
   */
  static async checkPermission(context: common.UIAbilityContext): Promise<string> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const tokenId: number = context.applicationInfo.accessTokenId;
      const status: abilityAccessCtrl.GrantStatus = await atManager.checkAccessToken(tokenId,
        'ohos.permission.ACCESS_BLUETOOTH');
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ? 'granted' : 'denied';
    } catch (e) {
      return 'check_error: ' + JSON.stringify(e);
    }
  }

  /** 详细展开错误对象 (用于诊断 401 来源) */
  static describeError(e: object): string {
    let detail: string = 'json=' + JSON.stringify(e);
    detail += ' isError=' + (e instanceof Error);
    try {
      const rec: Record<string, Object> = e as Record<string, Object>;
      const keys: string[] = Object.keys(rec);
      detail += ' keys=' + keys.join(',');
      detail += ' code=' + JSON.stringify(rec['code']) + ' msg=' + JSON.stringify(rec['message']);
    } catch (err) {
      detail += ' fields_err=' + JSON.stringify(err);
    }
    return detail;
  }

  /**
   * 把连接错误翻译成可操作的中文提示 (升级后连不上时, 用户需要知道该动哪里)。
   * 只对已知错误码给结论, 其余一律给通用排查步骤, 不臆测含义。
   */
  static hintFor(e: object): string {
    let msg: string = '';
    let code: number = -1;
    try {
      const rec: Record<string, Object> = e as Record<string, Object>;
      const mv: Object | undefined = rec['message'];
      if (typeof mv === 'string') {
        msg = mv;
      }
      const cv: Object | undefined = rec['code'];
      if (typeof cv === 'number') {
        code = cv as number;
      }
    } catch (err) {
      // 取不到字段时按通用处理
    }
    if (msg.indexOf('timeout') >= 0) {
      return '连接超时: 加热器已被其他手机/旧版 App 占用, 或不在范围内。请关开手机蓝牙、断电重启加热器后重试。';
    }
    if (code === 201 || code === 401) {
      return '权限不足(201/401): 设置→应用→SICN加热器→权限, 打开"附近设备/蓝牙"。';
    }
    if (code === 2900003) {
      return '系统蓝牙未开启或蓝牙服务异常: 关开一次手机蓝牙后重试。';
    }
    if (code === 2900001) {
      return '蓝牙服务尚未就绪: 稍等 2 秒再点连接。';
    }
    if (code === 2900099 || code === 2901003 || code === 2901004) {
      return '蓝牙栈忙/连接冲突: 多为旧版 App 的 GATT 连接未释放。请关开手机蓝牙(或重启加热器电源)后重试。';
    }
    return '请关开手机蓝牙后重试; 若仍失败, 断电重启加热器, 并确认没有其他手机连着它。';
  }

  /**
   * 开始扫描 (BleScanner, API 26 官方推荐方式; 失败自动回退旧 API startBLEScan).
   *
   * 过滤器降级链 (API 26 native 校验多变):
   *   1. [{}] 空对象 = 不过滤 (v26.7 实测有效)
   *   2. [{name:'SICN-HEATER-E84'}] 设备名精确过滤
   *   3. [{serviceUuid:FFF0}] 服务 UUID 过滤 (广播可能不含, 最后尝试)
   * 每次新建扫描器实例, 避免复用脏状态导致 401。
   *
   * @param onFind  每批新设备回调 (BleScanner: ScanReport.scanResult; 旧API: 直接 ScanResult 数组)
   * @param onError 扫描启动失败回调, 由 UI 展示, 不抛出
   * @param onInfo  状态提示回调 (如回退模式), 可选
   */
  static startScan(onFind: (devices: Array<ble.ScanResult>) => void,
    onError: (msg: string) => void, onInfo?: (msg: string) => void): void {
    let scanner: ble.BleScanner;
    try {
      scanner = ble.createBleScanner();
    } catch (e) {
      BleService.startScanLegacy(onFind, onError, onInfo,
        'scanner_create_fail: ' + BleService.describeError(e));
      return;
    }
    BleService.scanner = scanner;
    try {
      scanner.on('BLEDeviceFind', (report: ble.ScanReport) => {
        onFind(report.scanResult);
      });
    } catch (e) {
      BleService.startScanLegacy(onFind, onError, onInfo,
        'scanner_on_fail: ' + BleService.describeError(e));
      return;
    }
    const attempts: Array<Array<ble.ScanFilter>> = [
      [{} as ble.ScanFilter],
      [{ name: 'SICN-HEATER-E84' } as ble.ScanFilter],
      [{ serviceUuid: SERVICE_UUID } as ble.ScanFilter],
    ];
    BleService.tryScanFilters(scanner, attempts, 0, onFind, onError, onInfo);
  }

  private static tryScanFilters(scanner: ble.BleScanner,
    attempts: Array<Array<ble.ScanFilter>>, idx: number,
    onFind: (devices: Array<ble.ScanResult>) => void,
    onError: (msg: string) => void, onInfo?: (msg: string) => void): void {
    if (idx >= attempts.length) {
      BleService.startScanLegacy(onFind, onError, onInfo,
        'all filters rejected (last: ' + (attempts.length - 1) + ')');
      return;
    }
    try {
      scanner.startScan(attempts[idx]).then(() => {
        hilog.info(0x0000, TAG, 'BleScanner scan started, filterIdx=%{public}d', idx);
        if (onInfo !== undefined && idx > 0) {
          onInfo('扫描过滤器已自动调整 (第 ' + (idx + 1) + ' 种)。');
        }
      }).catch((err: object) => {
        hilog.warn(0x0000, TAG, 'startScan filter#%{public}d failed: %{public}s',
          idx, JSON.stringify(err));
        BleService.tryScanFilters(scanner, attempts, idx + 1, onFind, onError, onInfo);
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'startScan throw filter#%{public}d: %{public}s',
        idx, JSON.stringify(e));
      BleService.tryScanFilters(scanner, attempts, idx + 1, onFind, onError, onInfo);
    }
  }

  /** 回退路径: 旧 API startBLEScan (API 26 仍支持, 同步调用) */
  private static startScanLegacy(onFind: (devices: Array<ble.ScanResult>) => void,
    onError: (msg: string) => void, onInfo: ((msg: string) => void) | undefined,
    reason: string): void {
    hilog.warn(0x0000, TAG, 'fallback startBLEScan, reason=%{public}s', reason);
    if (onInfo !== undefined) {
      onInfo('BleScanner 不可用, 已自动切换到兼容扫描模式。原因: ' + reason);
    }
    try {
      ble.on('BLEDeviceFind', (data: Array<ble.ScanResult>) => {
        onFind(data);
      });
    } catch (e) {
      onError('注册扫描事件失败(兼容模式): ' + BleService.describeError(e));
      return;
    }
    const attempts: Array<Array<ble.ScanFilter>> = [
      [{} as ble.ScanFilter],
      [{ name: 'SICN-HEATER-E84' } as ble.ScanFilter],
      [{ serviceUuid: SERVICE_UUID } as ble.ScanFilter],
    ];
    for (let i = 0; i < attempts.length; i++) {
      try {
        ble.startBLEScan(attempts[i]);
        if (onInfo !== undefined) {
          onInfo('兼容扫描模式已启动 (startBLEScan)。');
        }
        hilog.info(0x0000, TAG, 'startBLEScan ok filterIdx=%{public}d', i);
        return;
      } catch (e) {
        hilog.warn(0x0000, TAG, 'startBLEScan filter#%{public}d failed: %{public}s',
          i, JSON.stringify(e));
      }
    }
    onError('启动扫描失败(兼容模式): 所有过滤器均被系统拒绝');
  }

  /**
   * 停止扫描并等待蓝牙栈真正释放 (连接前必须 await)。
   * 旧实现直接返回, 扫描仍占着栈, 紧接着 connect 会被系统拒绝或超时。
   */
  static async stopScan(): Promise<void> {
    const sc = BleService.scanner;
    if (sc) {
      try {
        await sc.stopScan();
        hilog.info(0x0000, TAG, 'scan stopped');
      } catch (e) {
        hilog.warn(0x0000, TAG, 'stopScan: %{public}s', JSON.stringify(e));
      }
      try {
        sc.off('BLEDeviceFind');
      } catch (e) {
        hilog.warn(0x0000, TAG, 'off BLEDeviceFind: %{public}s', JSON.stringify(e));
      }
      BleService.scanner = null;
    }
    // 兼容回退模式: 旧 API 的停止 (无副作用, 未启动时静默失败)
    try {
      ble.off('BLEDeviceFind');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'off module BLEDeviceFind: %{public}s', JSON.stringify(e));
    }
    try {
      ble.stopBLEScan();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'stopBLEScan: %{public}s', JSON.stringify(e));
    }
    // 给系统一个释放 radio 的窗口, 否则 connect 常报蓝牙栈忙
    await delay(250);
  }

  /**
   * 连接并等待连接建立 (设备需具备 FFF0 服务)。
   * connect() 是同步调用, 结果由 BLEConnectionStateChange 事件给出。
   *
   * 重试策略 (升级/重装后最常见故障是系统侧残留旧 GATT 连接):
   *   每次尝试都用全新的 GattClientDevice, 失败后 disconnect+close 释放句柄,
   *   间隔 1.5s/3s 再试, 共 3 次; 首次超时 12s, 后续 9s。
   */
  static async connect(deviceId: string): Promise<void> {
    await BleService.disconnect();
    await delay(200);
    let lastMsg: string = 'unknown';
    for (let attempt = 1; attempt <= CONNECT_MAX_ATTEMPT; attempt++) {
      let gatt: ble.GattClientDevice | undefined = undefined;
      try {
        gatt = ble.createGattClientDevice(deviceId);
        BleService.gatt = gatt;
        BleService.diag('连接尝试 ' + attempt + '/' + CONNECT_MAX_ATTEMPT + ' -> ' + deviceId);
        await BleService.waitConnected(gatt, attempt === 1 ? CONNECT_TIMEOUT_MS : 9000);
        BleService.diag('连接成功 (第 ' + attempt + ' 次尝试)');
        return;
      } catch (e) {
        lastMsg = BleService.describeError(e);
        hilog.warn(0x0000, TAG, 'connect attempt %{public}d failed: %{public}s',
          attempt, lastMsg);
        BleService.diag('第 ' + attempt + ' 次连接失败: ' + lastMsg);
        if (gatt !== undefined) {
          try {
            gatt.disconnect();
          } catch (err) {
            // 未连上时 disconnect 报错属正常
          }
          try {
            gatt.close();
          } catch (err) {
            // 同上
          }
        }
        BleService.gatt = undefined;
        BleService.ch = undefined;
        if (attempt < CONNECT_MAX_ATTEMPT) {
          const waitMs: number = attempt === 1 ? 1500 : 3000;
          BleService.diag('等待 ' + waitMs + 'ms 后重试...');
          await delay(waitMs);
        }
      }
    }
    throw new Error('连接失败(已重试 ' + CONNECT_MAX_ATTEMPT + ' 次): ' + lastMsg);
  }

  private static waitConnected(gatt: ble.GattClientDevice, timeoutMs: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let settled: boolean = false;
      const timer: number = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        BleService.offState(gatt);
        reject(new Error('connect timeout (' + timeoutMs + 'ms)'));
      }, timeoutMs);

      gatt.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
        hilog.info(0x0000, TAG, 'conn state -> %{public}d', state.state);
        if (settled) {
          return;
        }
        if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
          settled = true;
          clearTimeout(timer);
          BleService.offState(gatt);
          resolve();
        } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
          settled = true;
          clearTimeout(timer);
          BleService.offState(gatt);
          reject(new Error('disconnected during connect'));
        }
      });

      try {
        gatt.connect();
      } catch (e) {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          BleService.offState(gatt);
          reject(new Error('connect() failed: ' + JSON.stringify(e)));
        }
      }
    });
  }

  private static offState(gatt: ble.GattClientDevice): void {
    try {
      gatt.off('BLEConnectionStateChange');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'off state: %{public}s', JSON.stringify(e));
    }
  }

  /** 从 getServices() 结果中定位 FFF0/FFF1 */
  private static async getChar(): Promise<ble.BLECharacteristic> {
    if (BleService.ch) {
      return BleService.ch;
    }
    const gatt = BleService.gatt;
    if (!gatt) {
      throw new Error('not connected');
    }
    const services: Array<ble.GattService> = await withTimeout(gatt.getServices(),
      GATT_TIMEOUT_MS, '服务发现');
    // 全量枚举日志: 打印鸿蒙看到的真实 GATT 结构 (服务/特征/描述符/属性)
    for (const svc of services) {
      hilog.info(0x0000, TAG, 'GATT svc: %{public}s chars=%{public}d',
        svc.serviceUuid, svc.characteristics.length);
      BleService.diag('GATT服务: ' + svc.serviceUuid + ' 特征数=' + svc.characteristics.length);
      for (const c of svc.characteristics) {
        let desc: string = '';
        for (const d of c.descriptors) {
          desc += d.descriptorUuid + ',';
        }
        hilog.info(0x0000, TAG, 'GATT char: %{public}s props=%{public}s desc=[%{public}s]',
          c.characteristicUuid, JSON.stringify(c.properties), desc);
        BleService.diag('GATT特征: ' + c.characteristicUuid +
          ' props=' + JSON.stringify(c.properties) + ' desc=[' + desc + ']');
      }
    }
    for (const svc of services) {
      if (svc.serviceUuid.toLowerCase() !== SERVICE_UUID) {
        continue;
      }
      for (const c of svc.characteristics) {
        if (c.characteristicUuid.toLowerCase() === CHAR_UUID) {
          BleService.ch = c;
          return c;
        }
      }
    }
    throw new Error('FFF0/FFF1 not found: device is not a SHISON heater');
  }

  /** 使能 FFF1 通知 */
  static async enableNotify(onData: (value: Uint8Array) => void): Promise<void> {
    const gatt = BleService.gatt;
    if (!gatt) {
      throw new Error('not connected');
    }
    const c: ble.BLECharacteristic = await BleService.getChar();
    hilog.info(0x0000, TAG, 'char found: %{public}s props=%{public}s',
      c.characteristicUuid, JSON.stringify(c.properties));
    BleService.diag('已定位 FFF1: props=' + JSON.stringify(c.properties) +
      ' descCount=' + c.descriptors.length);
    gatt.on('BLECharacteristicChange', (data: ble.BLECharacteristic) => {
      const bytes: Uint8Array = new Uint8Array(data.characteristicValue);
      hilog.info(0x0000, TAG, 'NOTIFY: %{public}s len=%{public}d',
        bytesToHexLog(bytes), bytes.length);
      BleService.diag('设备推送: ' + bytesToHexLog(bytes));
      onData(bytes);
    });
    try {
      await withTimeout(gatt.setCharacteristicChangeNotification(c, true),
        GATT_TIMEOUT_MS, '使能通知');
      hilog.info(0x0000, TAG, 'setCharacteristicChangeNotification ok');
      BleService.diag('通知使能: setCharacteristicChangeNotification ok');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'setCharacteristicChangeNotification failed, retry: %{public}s',
        JSON.stringify(e));
      BleService.diag('通知使能失败, 重试: ' + JSON.stringify(e));
      try {
        await withTimeout(gatt.setCharacteristicChangeNotification(c, true),
          GATT_TIMEOUT_MS, '使能通知重试');
        hilog.info(0x0000, TAG, 'setCharacteristicChangeNotification ok (retry)');
        BleService.diag('通知使能成功(重试)');
      } catch (e2) {
        hilog.warn(0x0000, TAG, 'setCharacteristicChangeNotification failed twice: %{public}s',
          JSON.stringify(e2));
        BleService.diag('通知使能两次失败: ' + JSON.stringify(e2));
      }
    }
    // 写 CCCD(2902=01 00) 使能设备端通知: Android 原版 App 也这么做 (smali 证实),
    // 不写设备不会推数据。后台异步执行, 不阻塞主流程。
    BleService.writeCccd(gatt, c);
  }

  /** 枚举 FFF1 描述符, 供 UI 诊断展示 */
  static describeChar(): string {
    const c = BleService.ch;
    if (!c) {
      return '未连接';
    }
    let s = 'FFF1 props=' + JSON.stringify(c.properties) + ' desc=';
    if (c.descriptors.length === 0) {
      s += '(无)';
    } else {
      for (const d of c.descriptors) {
        s += d.descriptorUuid + ',';
      }
    }
    return s;
  }

  /** 后台写 CCCD (2902) = 01 00, 失败不影响主流程 */
  private static async writeCccd(gatt: ble.GattClientDevice,
    c: ble.BLECharacteristic): Promise<void> {
    try {
      const list: Array<ble.BLEDescriptor> = c.descriptors.filter(
        (d: ble.BLEDescriptor): boolean => d.descriptorUuid.toLowerCase().indexOf('2902') >= 0);
      if (list.length === 0) {
        hilog.warn(0x0000, TAG, 'writeCccd: no 2902 descriptor found');
        return;
      }
      const cc: ble.BLEDescriptor | undefined = list[0];
      if (cc === undefined) {
        return;
      }
      const buf: ArrayBuffer = new ArrayBuffer(2);
      const dv: DataView = new DataView(buf);
      dv.setUint8(0, 0x01);
      dv.setUint8(1, 0x00);
      cc.descriptorValue = buf;
      await withTimeout(gatt.writeDescriptorValue(cc), 5000, '写CCCD');
      hilog.info(0x0000, TAG, 'CCCD(2902) written: 01 00');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'writeCccd failed (non-fatal): %{public}s', JSON.stringify(e));
    }
  }

  /** 写 FFF1 (优先带响应写 WRITE, 与 Android 原版一致; 失败回退无响应写) */
  static async write(bytes: Uint8Array): Promise<void> {
    const gatt = BleService.gatt;
    if (!gatt) {
      throw new Error('not connected');
    }
    const c: ble.BLECharacteristic = await BleService.getChar();
    c.characteristicValue = bytes.buffer.slice(bytes.byteOffset,
      bytes.byteOffset + bytes.byteLength);
    hilog.info(0x0000, TAG, 'WRITE sending: %{public}s', bytesToHexLog(bytes));
    BleService.diag('发送: ' + bytesToHexLog(bytes));
    try {
      await withTimeout(gatt.writeCharacteristicValue(c, ble.GattWriteType.WRITE),
        GATT_TIMEOUT_MS, '写入(带响应)');
      hilog.info(0x0000, TAG, 'WRITE ok (with response): %{public}s', bytesToHexLog(bytes));
      BleService.diag('写入成功(带响应): ' + bytesToHexLog(bytes));
    } catch (e) {
      hilog.warn(0x0000, TAG, 'WRITE failed, fallback no-response: %{public}s', JSON.stringify(e));
      BleService.diag('带响应写失败(' + JSON.stringify(e) + '), 改用无响应写...');
      await withTimeout(gatt.writeCharacteristicValue(c, ble.GattWriteType.WRITE_NO_RESPONSE),
        GATT_TIMEOUT_MS, '写入(无响应)');
      hilog.info(0x0000, TAG, 'WRITE ok (no response): %{public}s', bytesToHexLog(bytes));
      BleService.diag('写入成功(无响应): ' + bytesToHexLog(bytes));
    }
  }

  /** 主动读 FFF1 (通知不可用时读通道可能仍可用; API 26 读取结果直接由 Promise 返回) */
  static async readOnce(): Promise<void> {
    const gatt = BleService.gatt;
    if (!gatt) {
      return;
    }
    try {
      const c: ble.BLECharacteristic = await BleService.getChar();
      const result: ble.BLECharacteristic = await withTimeout(
        gatt.readCharacteristicValue(c), GATT_TIMEOUT_MS, '读取');
      const b: Uint8Array = new Uint8Array(result.characteristicValue);
      hilog.info(0x0000, TAG, 'READ ok: %{public}s len=%{public}d',
        bytesToHexLog(b), b.length);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'read failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 断开并释放 */
  static async disconnect(): Promise<void> {
    const gatt = BleService.gatt;
    BleService.gatt = undefined;
    BleService.ch = undefined;
    if (!gatt) {
      return;
    }
    try {
      gatt.off('BLECharacteristicChange');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'off charChange: %{public}s', JSON.stringify(e));
    }
    BleService.offState(gatt);
    try {
      gatt.disconnect();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'disconnect: %{public}s', JSON.stringify(e));
    }
    try {
      gatt.close();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'close: %{public}s', JSON.stringify(e));
    }
  }
}
