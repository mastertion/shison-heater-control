/**
 * 设备与状态数据模型
 */

export class DeviceItem {
  deviceId: string;
  deviceName: string;
  rssi: number;
  isHeater: boolean;

  constructor(deviceId: string, deviceName: string, rssi: number, isHeater: boolean) {
    this.deviceId = deviceId;
    this.deviceName = deviceName;
    this.rssi = rssi;
    this.isHeater = isHeater;
  }
}

/** 加热器工作模式文案 (与 Python 版一致) */
export function modeText(mode: number): string {
  switch (mode) {
    case 0:
      return '探头故障';
    case 1:
      return '离水断电';
    case 2:
      return '超温';
    case 3:
      return '加热';
    case 4:
      return '恒温';
    case 5:
      return '降温';
    default:
      return '未知(' + mode + ')';
  }
}
