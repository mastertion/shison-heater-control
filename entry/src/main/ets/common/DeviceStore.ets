/**
 * 设备库 (对应安卓 DeviceRecord: 多设备记忆 + per-device 自动连接)
 *
 * 鸿蒙端用 preferences 持久化一个已知设备列表(JSON 数组), 字段对齐安卓:
 *   address / name / autoConnect(对应安卓 auto_connect) / lastSeen
 * 安卓的 manufacture_data 在实测里基本为空, 这里省略。
 *
 * 与当前"只存最后一台(last_addr)"的实现相比, 本模块支持记住多台设备,
 * 并允许为其中任意一台开启"自动连接"。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** 一台已保存的加热器 */
export class SavedDevice {
  address: string = '';
  name: string = '';
  /** 是否在该设备出现时自动连接 (对齐安卓 auto_connect) */
  autoConnect: boolean = false;
  /** 上次连接/见到的时间戳 ms */
  lastSeen: number = 0;
}

const STORE_KEY: string = 'sicn_devices';
const PREF_NAME: string = 'sicn_pref';
/** 兼容旧版: 上次连接的地址/名称 */
export const LAST_ADDR: string = 'last_addr';
export const LAST_NAME: string = 'last_name';

function asString(v: Object | undefined, def: string): string {
  if (typeof v === 'string') {
    return v;
  }
  return def;
}

function asBool(v: Object | undefined, def: boolean): boolean {
  if (typeof v === 'boolean') {
    return v;
  }
  return def;
}

function asNumber(v: Object | undefined, def: number): number {
  if (typeof v === 'number') {
    return v;
  }
  return def;
}

export class DeviceStore {
  /** 读取全部已保存设备 */
  static async load(context: common.UIAbilityContext): Promise<SavedDevice[]> {
    const list: SavedDevice[] = [];
    try {
      const pref = await preferences.getPreferences(context, PREF_NAME);
      const json = (await pref.get(STORE_KEY, '[]')) as string;
      const arr = JSON.parse(json) as Array<object>;
      for (const o of arr) {
        const rec = o as Record<string, Object>;
        const d = new SavedDevice();
        d.address = asString(rec['address'], '');
        d.name = asString(rec['name'], '');
        d.autoConnect = asBool(rec['autoConnect'], false);
        d.lastSeen = asNumber(rec['lastSeen'], 0);
        if (d.address !== '') {
          list.push(d);
        }
      }
    } catch (e) {
      // 解析失败/无数据 -> 返回空列表
    }
    return list;
  }

  /** 保存整个列表 */
  static async save(context: common.UIAbilityContext, list: SavedDevice[]): Promise<void> {
    try {
      const pref = await preferences.getPreferences(context, PREF_NAME);
      await pref.put(STORE_KEY, JSON.stringify(list));
      await pref.flush();
    } catch (e) {
      // 忽略
    }
  }

  /** 新增或更新一台设备(按 address 去重), 连接成功后调用 */
  static async upsert(context: common.UIAbilityContext, address: string, name: string): Promise<SavedDevice[]> {
    const list = await DeviceStore.load(context);
    let found = false;
    for (const d of list) {
      if (d.address === address) {
        d.name = name || d.name;
        d.lastSeen = Date.now();
        found = true;
        break;
      }
    }
    if (!found) {
      const d = new SavedDevice();
      d.address = address;
      d.name = name;
      d.autoConnect = false;
      d.lastSeen = Date.now();
      list.push(d);
    }
    await DeviceStore.save(context, list);
    return list;
  }

  /**
   * 设备地址变更: 旧记录迁移到新地址, 保留 autoConnect 标记。
   *
   * 加热器换板/升级固件后 BLE 静态地址会变而设备名不变, 旧地址从此永远连不上
   * (connect 超时且无任何状态回调)。连接前扫描到同名设备时调用本方法纠正记录。
   */
  static async migrate(context: common.UIAbilityContext, oldAddress: string,
    newAddress: string, name: string): Promise<SavedDevice[]> {
    const list: SavedDevice[] = await DeviceStore.load(context);
    const oldKey: string = oldAddress.toUpperCase();
    const newKey: string = newAddress.toUpperCase();
    if (oldKey === newKey) {
      return list;
    }
    let keepAuto: boolean = false;
    const out: SavedDevice[] = [];
    for (const d of list) {
      const k: string = d.address.toUpperCase();
      if (k === oldKey) {
        keepAuto = keepAuto || d.autoConnect;
        continue;
      }
      if (k === newKey) {
        keepAuto = keepAuto || d.autoConnect;
        if (name !== '') {
          d.name = name;
        }
        d.lastSeen = Date.now();
      }
      out.push(d);
    }
    let exists: boolean = false;
    for (const d of out) {
      if (d.address.toUpperCase() === newKey) {
        d.autoConnect = d.autoConnect || keepAuto;
        exists = true;
        break;
      }
    }
    if (!exists) {
      const n = new SavedDevice();
      n.address = newAddress;
      n.name = name;
      n.autoConnect = keepAuto;
      n.lastSeen = Date.now();
      out.push(n);
    }
    await DeviceStore.save(context, out);
    return out;
  }

  /** 切换某设备的自动连接开关 */
  static async setAutoConnect(context: common.UIAbilityContext, address: string,
    on: boolean): Promise<SavedDevice[]> {
    const list = await DeviceStore.load(context);
    for (const d of list) {
      if (d.address === address) {
        d.autoConnect = on;
        break;
      }
    }
    await DeviceStore.save(context, list);
    return list;
  }

  /** 取一台应自动连接的设备: 优先 autoConnect=true 中 lastSeen 最新的; 否则返回 null */
  static async getAutoConnect(context: common.UIAbilityContext): Promise<SavedDevice | null> {
    const list = await DeviceStore.load(context);
    let best: SavedDevice | null = null;
    for (const d of list) {
      if (d.autoConnect) {
        if (best === null || d.lastSeen > best.lastSeen) {
          best = d;
        }
      }
    }
    return best;
  }

  /** 取最后连接的设备(兼容旧版 last_addr) */
  static async getLastConnected(context: common.UIAbilityContext): Promise<SavedDevice | null> {
    try {
      const pref = await preferences.getPreferences(context, PREF_NAME);
      const addr = (await pref.get(LAST_ADDR, '')) as string;
      if (addr === '') {
        return null;
      }
      const name = (await pref.get(LAST_NAME, '')) as string;
      const d = new SavedDevice();
      d.address = addr;
      d.name = name;
      return d;
    } catch (e) {
      return null;
    }
  }
}
