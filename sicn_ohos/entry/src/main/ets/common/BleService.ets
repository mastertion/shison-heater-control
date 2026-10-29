/**
 * BLE 服务封装 (HarmonyOS NEXT ConnectivityKit)
 *
 * 本 SDK (HarmonyOS NEXT 5.0, API 12) 的 ble 模块接口:
 *  - 扫描: ble.startBLEScan(filters, options) + 'BLEDeviceFind' 事件
 *  - 蓝牙开关: access.getState()
 *  - GATT: createGattClientDevice + getServices(); connect 同步 + 'BLEConnectionStateChange'
 *  - 写入: writeCharacteristicValue(char, GattWriteType), 数据放 characteristicValue
 *  - 释放: close()
 *
 * 所有调用均做异常保护, 失败通过 onError 回调交给 UI 显示, 绝不闪退。
 */

import { access, ble, constant } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SERVICE_UUID, CHAR_UUID } from './Protocol';

const TAG = 'SICN-BLE';
const CONNECT_TIMEOUT_MS = 15000;

export class BleService {
  private static gatt: ble.GattClientDevice | undefined = undefined;
  private static ch: ble.BLECharacteristic | undefined = undefined;

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
   * 开始扫描 (事件回调持续推送新发现设备).
   *
   * 兼容策略 (针对不同鸿蒙版本的 startBLEScan 参数校验):
   *  鸿蒙 7 = API 26, 官方示例写法为 filters 传 null (表示全设备扫描);
   *  旧 SDK (API 12) 类型要求 Array, 这里用函数引用断言绕开类型,
   *  运行时按顺序尝试: null+官方options -> null -> []+官方options -> []。
   * 事件注册与扫描启动分开 try, 精确定位失败环节。
   *
   * @param onFind  每批新设备回调
   * @param onError 扫描启动失败回调 (权限不足/蓝牙关闭等), 由 UI 展示, 不抛出
   */
  static startScan(onFind: (devices: Array<ble.ScanResult>) => void,
    onError: (msg: string) => void): void {
    // 第一步: 注册发现事件
    try {
      ble.on('BLEDeviceFind', onFind);
    } catch (e) {
      onError('扫描事件注册失败(BLEDeviceFind): ' + JSON.stringify(e) + ' (请反馈开发者)');
      return;
    }

    // API 26 允许 filters 为 null; API 12 类型为 Array, 用函数引用断言兼容
    type ScanStart = (filters: Array<ble.ScanFilter> | null, options?: ble.ScanOptions) => void;
    const scanStart: ScanStart = ble.startBLEScan as ScanStart;

    const errors: string[] = [];
    const attempts: Array<() => void> = [
      // 1) API 26 官方示例: null + options
      () => scanStart(null,
        {
          interval: 1000,
          dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
          matchMode: ble.MatchMode.MATCH_MODE_STICKY
        }),
      // 2) null, 无 options
      () => scanStart(null),
      // 3) 空数组 + options
      () => scanStart([],
        {
          interval: 1000,
          dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
          matchMode: ble.MatchMode.MATCH_MODE_STICKY
        }),
      // 4) 空数组, 无 options
      () => scanStart([])
    ];
    for (const attempt of attempts) {
      try {
        attempt();
        return; // 成功, 等待 BLEDeviceFind 回调
      } catch (e) {
        errors.push(JSON.stringify(e));
        hilog.warn(0x0000, TAG, 'startBLEScan attempt failed: %{public}s', JSON.stringify(e));
      }
    }

    // 全部尝试失败: 解绑并汇总报错
    try {
      ble.off('BLEDeviceFind');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'off after fail: %{public}s', JSON.stringify(e));
    }
    const joined: string = errors.join(' | ');
    if (joined.indexOf('201') >= 0) {
      onError('启动扫描失败(201): 蓝牙权限被拒绝。请到 设置-应用-权限管理 开启蓝牙权限。');
    } else if (joined.indexOf('401') >= 0) {
      onError('启动扫描失败(401): 4种参数形态均被拒: ' + joined);
    } else {
      onError('启动扫描失败: ' + joined);
    }
  }

  /** 停止扫描并解绑事件 */
  static stopScan(): void {
    try {
      ble.stopBLEScan();
    } catch (e) {
      hilog.warn(0x0000, TAG, 'stopBLEScan: %{public}s', JSON.stringify(e));
    }
    try {
      ble.off('BLEDeviceFind');
    } catch (e) {
      hilog.warn(0x0000, TAG, 'off BLEDeviceFind: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 连接并等待连接建立 (设备需具备 FFF0 服务).
   * connect() 是同步调用, 结果由 BLEConnectionStateChange 事件给出.
   */
  static async connect(deviceId: string): Promise<void> {
    await BleService.disconnect();
    const gatt: ble.GattClientDevice = ble.createGattClientDevice(deviceId);
    BleService.gatt = gatt;
    await BleService.waitConnected(gatt);
  }

  private static waitConnected(gatt: ble.GattClientDevice): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let settled: boolean = false;
      const timer: number = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        BleService.offState(gatt);
        reject(new Error('connect timeout'));
      }, CONNECT_TIMEOUT_MS);

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
    const services: Array<ble.GattService> = await gatt.getServices();
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
    gatt.on('BLECharacteristicChange', (data: ble.BLECharacteristic) => {
      onData(new Uint8Array(data.characteristicValue));
    });
    await gatt.setCharacteristicChangeNotification(c, true);
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
    try {
      await gatt.writeCharacteristicValue(c, ble.GattWriteType.WRITE);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'WRITE failed, fallback no-response: %{public}s', JSON.stringify(e));
      await gatt.writeCharacteristicValue(c, ble.GattWriteType.WRITE_NO_RESPONSE);
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
