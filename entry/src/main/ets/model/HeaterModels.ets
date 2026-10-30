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

/**
 * 加热器工作模式文案 (对齐安卓原版 APK, 2026-10-31 由资源名实证)
 *
 * 安卓 MainFragment.notice() 的 6 个 if-eq 分支按跳转偏移从近到远依次为
 * mode 5,4,3,2,1,0, 对应资源名:
 *   0 Cooling               -> 降温
 *   1 KeepTemperature       -> 恒温
 *   2 Heating               -> 加热
 *   3 OverTemperature       -> 超温
 *   4 LeavingWaterPowerOff  -> 离水断电
 *   5 ProbeFailure          -> 探头故障
 * 数值越大故障等级越高, 报警为 3/4/5。真机实测 byte2 只出现 1(恒温)/2(加热),
 * 与"设备在设定温度附近反复加热-恒温"的行为一致, 可反向印证此映射。
 */
export function modeText(mode: number): string {
  switch (mode) {
    case 0:
      return '降温';
    case 1:
      return '恒温';
    case 2:
      return '加热';
    case 3:
      return '超温';
    case 4:
      return '离水断电';
    case 5:
      return '探头故障';
    default:
      return '未知(' + mode + ')';
  }
}

/** 是否为故障/保护报警模式 (超温 3 / 离水断电 4 / 探头故障 5) */
export function isAlarmMode(mode: number): boolean {
  return mode >= 3 && mode <= 5;
}
