/**
 * SHISON 加热器 BLE 协议 (与 Windows 版 sicn_control.py 逆向结论一致)
 *
 * 服务: 0000FFF0-...  特征: 0000FFF1-...(写+通知)
 * 连接时序: 连接 -> 使能通知 -> 延时1s -> 写 [01 03] 触发设备推送状态
 */

import { modeText } from '../model/HeaterModels';

export const SERVICE_UUID: string = '0000fff0-0000-1000-8000-00805f9b34fb';
export const CHAR_UUID: string = '0000fff1-0000-1000-8000-00805f9b34fb';

/** 写指令: 状态同步握手 (连接后使能通知, 延时1s, 写此指令) */
export function makeSyncCmd(): Uint8Array {
  return new Uint8Array([0x01, 0x03]);
}

/** 设目标温度: 值 = round(温度*10), 小端. 例 26.0C -> 260 -> 04 01 */
export function makeTempCmd(temp: number): Uint8Array {
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
  target: number = 0;
  segment: number = 0;
  history: number[] = [];

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

  static makeHistory(segment: number, samples: number[]): NotifyData {
    const d = new NotifyData();
    d.kind = 'history';
    d.segment = segment;
    d.history = samples;
    return d;
  }
}

/**
 * 解析设备通知包.
 *  3001 MODE UNIT T_LO ?? T_HI ??  -> 当前温度 = (T_HI*256+T_LO)/10, UNIT 0=℉ 1=℃
 *  3101 LO HI                      -> 目标温度 = (HI*256+LO)/10
 *  30 03/30 02 SEG [采样...]       -> 历史: 采样2字节取低12位/10, 每段8个采样
 */
export function parseNotify(buf: Uint8Array): NotifyData | null {
  if (buf.length < 2) {
    return null;
  }
  if (buf[0] === 0x30 && buf[1] === 0x01 && buf.length >= 7) {
    // 3001 MODE UNIT T_LO ?? T_HI ??
    const mode: number = buf[2];
    const unit: number = buf[3]; // 0=℉ 1=℃
    const tLo: number = buf[4];
    const tHi: number = buf[6];
    const temp: number = (tHi * 256 + tLo) / 10;
    return NotifyData.makeStatus(temp, mode, unit === 1 ? 'C' : 'F');
  }
  if (buf[0] === 0x31 && buf[1] === 0x01 && buf.length >= 4) {
    const lo: number = buf[2];
    const hi: number = buf[3];
    return NotifyData.makeTarget((hi * 256 + lo) / 10);
  }
  if (buf[0] === 0x30 && (buf[1] === 0x03 || buf[1] === 0x02) && buf.length >= 4) {
    const segment: number = buf[2];
    const samples: number[] = [];
    let idx = 3;
    while (idx + 1 < buf.length) {
      const raw: number = (buf[idx] << 8) | buf[idx + 1];
      samples.push((raw & 0x0FFF) / 10);
      idx += 2;
    }
    return NotifyData.makeHistory(segment, samples);
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
