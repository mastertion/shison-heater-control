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
      return '超温保护';
    case 3:
      return '加热中';
    case 4:
      return '保温';
    case 5:
      return '待机';
    default:
      return '未知(' + mode + ')';
  }
}
