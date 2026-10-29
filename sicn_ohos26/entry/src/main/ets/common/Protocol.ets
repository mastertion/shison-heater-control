/**
 * SHISON 加热器 BLE 协议 (与安卓原版 apk smali 逐行逆向一致)
 *
 * 服务: 0000FFF0-...  特征: 0000FFF1-...(写+通知)
 * 连接时序: 连接 -> 使能通知 -> 延时1s -> 写 [01 03] 触发设备推送状态
 *
 * 安卓原版关键公式 (smali 实证, 2026-10-29):
 *  3001 当前温度 = (byte5*256+byte4)/10,  byte3: 0=℃ 1=℉  (用户实测: 旧映射反了)
 *  3101 目标温度: 原始值 v0=raw/10; ℃档显示=v0-64; ℉档显示=2*v0-36
 *  写目标温度:    ℃档=(温度+64)*10; ℉档=(温度+36)*5, 小端填 [31 01 LO HI]
 *  历史采样:      2字节取低12位/10, 且后字节为高字节 (与3001/3101同规律)
 */

import { modeText } from '../model/HeaterModels';

export const SERVICE_UUID: string = '0000fff0-0000-1000-8000-00805f9b34fb';
export const CHAR_UUID: string = '0000fff1-0000-1000-8000-00805f9b34fb';

/** 写指令: 状态同步握手 (连接后使能通知, 延时1s, 写此指令) */
export function makeSyncCmd(): Uint8Array {
  return new Uint8Array([0x01, 0x03]);
}

/**
 * 设目标温度 (无偏移协议, 2026-10-30 实测修正):
 *  设备固件与 3001 当前温度一致: 编码 = 温度×10, LCD 直接显示该温度。
 *  安卓原版 +64/-64、+36 那套偏移是安卓 APP 自己的 UI 换算, 不是设备协议,
 *  之前按偏移写入导致 "APP 20℃ 设备显示 84" 差 64。
 *  例: 20.0℃ -> 200 = 0x00C8 -> C8 00; 68.0℉ -> 680 = 0x02A8 -> A8 02
 * 小端填 [31 01 LO HI] (isF 参数保留仅为兼容调用, 协议不再区分单位)
 */
export function makeTempCmd(temp: number, isF: boolean): Uint8Array {
  const value: number = Math.round(temp * 10);
  return new Uint8Array([0x31, 0x01, value & 0xFF, (value >> 8) & 0xFF]);
}

/** 切换温度单位 (℃ <-> ℉) */
export function makeUnitCmd(): Uint8Array {
  return new Uint8Array([0x31, 0x02]);
}

/** 请求小时历史 (设备响应 3003) */
export function makeHourHistoryCmd(): Uint8Array {
  return new Uint8Array([0x31, 0x04]);
}

/** 请求分钟历史 (设备响应 3002) */
export function makeMinuteHistoryCmd(): Uint8Array {
  return new Uint8Array([0x31, 0x03]);
}

export class NotifyData {
  kind: string = '';
  temp: number = 0;
  mode: number = 0;
  unit: string = '';
  stateText: string = '';
  /** 3101 目标温度: 存原始值 raw/10 (未做 ±64/×2-36 显示换算, 由 UI 按当前单位换算) */
  target: number = 0;
  segment: number = 0;
  history: number[] = [];
  /** 历史类型: 'hour'=3003 小时历史(3段x8点=24小时), 'minute'=3002 分钟历史(8段x8点) */
  histKind: string = '';

  static makeStatus(temp: number, mode: number, unit: string): NotifyData {
    const d = new NotifyData();
    d.kind = 'status';
    d.temp = temp;
    d.mode = mode;
    d.unit = unit;
    d.stateText = modeText(mode);
    return d;
  }

  static makeTarget(target: number): NotifyData {
    const d = new NotifyData();
    d.kind = 'target';
    d.target = target;
    return d;
  }

  static makeHistory(segment: number, samples: number[], histKind: string): NotifyData {
    const d = new NotifyData();
    d.kind = 'history';
    d.segment = segment;
    d.history = samples;
    d.histKind = histKind;
    return d;
  }
}

/**
 * 解析设备通知包 (公式与安卓原版 smali 完全一致):
 *  3001 MODE UNIT T_LO T_HI [状态...] -> 当前温度=(byte5*256+byte4)/10
 *      安卓: substring(10,12)+substring(8,10) = byte5+byte4, /10
 *      UNIT: 0=℃ 1=℉ (用户实测: byte3=1 时安卓显示华氏)
 *  3101 LO HI -> 目标原始值 = (byte3*256+byte2)/10, 显示换算由 UI 按当前单位做:
 *      ℃档: 原始-64; ℉档: 2*原始-36
 *  30 03/30 02 SEG [采样...] -> 历史: 每采样2字节, 后字节为高, 取低12位/10, 每段8个采样
 */
export function parseNotify(buf: Uint8Array): NotifyData | null {
  if (buf.length < 2) {
    return null;
  }
  if (buf[0] === 0x30 && buf[1] === 0x01 && buf.length >= 6) {
    // 3001 MODE UNIT T_LO T_HI [状态...]
    const mode: number = buf[2];
    const unit: number = buf[3]; // 0=℃ 1=℉
    const tLo: number = buf[4];
    const tHi: number = buf.length >= 6 ? buf[5] : 0;
    const temp: number = (tHi * 256 + tLo) / 10;
    return NotifyData.makeStatus(temp, mode, unit === 1 ? 'F' : 'C');
  }
  if (buf[0] === 0x31 && buf[1] === 0x01 && buf.length >= 4) {
    const lo: number = buf[2];
    const hi: number = buf[3];
    return NotifyData.makeTarget((hi * 256 + lo) / 10);
  }
  if (buf[0] === 0x30 && (buf[1] === 0x03 || buf[1] === 0x02) && buf.length >= 4) {
    const segment: number = buf[2];
    // 0x03=小时历史(24小时=3段x8点), 0x02=分钟历史(8段x8点)
    const histKind: string = buf[1] === 0x03 ? 'hour' : 'minute';
    const samples: number[] = [];
    let idx = 3;
    while (idx + 1 < buf.length) {
      // 安卓: substring(10,12)+substring(8,10) 后字节为高字节
      const raw: number = (buf[idx + 1] << 8) | buf[idx];
      samples.push((raw & 0x0FFF) / 10);
      idx += 2;
    }
    return NotifyData.makeHistory(segment, samples, histKind);
  }
  return null;
}

/** 将字节数组转为十六进制字符串 (日志用) */
export function bytesToHex(buf: Uint8Array): string {
  let s = '';
  for (let i = 0; i < buf.length; i++) {
    s += ('0' + buf[i].toString(16)).slice(-2).toUpperCase() + ' ';
  }
  return s.trim();
}
