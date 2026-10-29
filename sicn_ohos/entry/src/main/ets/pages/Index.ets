/**
 * SHISON 加热器 蓝牙控制面板 (鸿蒙)
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ble } from '@kit.ConnectivityKit';
import { BleService } from '../common/BleService';
import {
  SERVICE_UUID,
  CHAR_UUID,
  makeSyncCmd,
  makeTempCmd,
  makeUnitCmd,
  makeHourHistoryCmd,
  makeMinuteHistoryCmd,
  parseNotify,
  bytesToHex,
  NotifyData
} from '../common/Protocol';
import { DeviceItem } from '../model/HeaterModels';

const TAG = 'SICN-UI';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

/**
 * 在广播原始数据里查找 16bit 服务号 0xFFF0.
 * AD 结构: len(1) + type(1) + data(len-1).
 * type 0x02/0x03 = 不完整/完整 16bit 服务 UUID 列表, 小端存放.
 */
function hasFff0Service(raw: ArrayBuffer): boolean {
  if (!raw) {
    return false;
  }
  const b = new Uint8Array(raw);
  let i = 0;
  while (i < b.length) {
    const len = b[i];
    if (len === 0 || i + len >= b.length) {
      break;
    }
    const type = b[i + 1];
    if (type === 0x02 || type === 0x03) {
      for (let j = i + 2; j + 1 <= i + len; j += 2) {
        const uuid16 = b[j] | (b[j + 1] << 8);
        if (uuid16 === 0xFFF0) {
          return true;
        }
      }
    }
    i += len + 1;
  }
  return false;
}

@Entry
@Component
struct Index {
  @State scanning: boolean = false;
  @State devices: DeviceItem[] = [];
  @State connected: boolean = false;
  @State connAddr: string = '';
  @State stateText: string = '未连接';
  @State stateColor: string = '#999999';
  @State currentTemp: string = '--';
  @State targetTemp: string = '--';
  @State unitText: string = '℃';
  @State tempInput: string = '26';
  @State logText: string = '启动完成。点击"扫描设备"开始搜索加热器。';
  @State connectBusy: boolean = false;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private seenIds: Set<string> = new Set<string>();
  private scroller: Scroller = new Scroller();
  private permissionOk: boolean = false;
  private scanGotAny: boolean = false;
  private gotNotify: boolean = false;

  aboutToDisappear(): void {
    if (this.scanning) {
      this.stopScan();
    }
    if (this.connected) {
      BleService.disconnect();
    }
  }

  onPageShow(): void {
    this.appendLog('检查蓝牙权限...');
    BleService.requestPermission(this.context).then((ok: boolean) => {
      this.permissionOk = ok;
      if (!ok) {
        this.appendLog('蓝牙权限未授权。点\"扫描设备\"时若失败, 请到 设置-应用-权限管理 开启蓝牙权限。');
        return;
      }
      BleService.isBluetoothOn().then((on: boolean) => {
        if (on) {
          this.appendLog('蓝牙已开启。');
        } else {
          this.appendLog('警告: 蓝牙未开启, 请打开系统蓝牙。');
        }
      });
    });
  }

  appendLog(s: string): void {
    this.logText = s + '\n' + this.logText;
    if (this.logText.length > 3000) {
      this.logText = this.logText.substring(0, 3000);
    }
    try {
      this.scroller.scrollEdge(Edge.Bottom);
    } catch (e) {
      // 布局未完成时忽略
    }
  }

  // ---------- 扫描 ----------
  startScan(): void {
    if (this.scanning) {
      return;
    }
    if (!this.permissionOk) {
      this.appendLog('提示: 蓝牙权限未授权, 请在 设置-应用-权限管理 开启蓝牙权限后重试。');
      promptAction.showToast({ message: '请先授权蓝牙权限 (设置-应用-权限管理)' });
      return;
    }
    this.seenIds.clear();
    this.devices = [];
    this.scanning = true;
    this.scanGotAny = false;
    this.appendLog('开始扫描...');
    promptAction.showToast({ message: '正在扫描蓝牙设备...' });
    BleService.startScan((found: Array<ble.ScanResult>) => {
      this.scanGotAny = true;
      for (const d of found) {
        if (this.seenIds.has(d.deviceId)) {
          continue;
        }
        this.seenIds.add(d.deviceId);
        const nm: string = d.deviceName ?? '';
        // 服务号从广播原始数据中查找 FFF0; 名称含 sicn/heater 也标记
        const isHeater: boolean = nm.toLowerCase().includes('sicn') ||
          nm.toLowerCase().includes('heater') ||
          hasFff0Service(d.data);
        this.devices.push(new DeviceItem(d.deviceId, nm, d.rssi, isHeater));
      }
      if (this.devices.length > 0) {
        this.appendLog('已发现 ' + this.devices.length + ' 台设备...');
      }
    }, (msg: string) => {
      this.scanning = false;
      this.appendLog(msg);
      promptAction.showToast({ message: msg });
    });
    // 3 秒无回报检测: 帮助区分"没设备广播"与"API/权限异常"
    setTimeout(() => {
      if (this.scanning && !this.scanGotAny) {
        this.appendLog('扫描已启动但 3 秒内无设备回报。请确认: 1)加热器通电开机 2)蓝牙已开启 3)若持续如此, 截图本日志区文字反馈。');
      }
    }, 3000);
    // 15 秒后自动停止
    setTimeout(() => {
      if (this.scanning) {
        this.stopScan();
      }
    }, 15000);
  }

  stopScan(): void {
    this.scanning = false;
    BleService.stopScan();
    const n: number = this.devices.length;
    this.appendLog('扫描停止, 共发现 ' + n + ' 台设备。');
    promptAction.showToast({ message: n > 0 ? ('发现 ' + n + ' 台设备') : '未发现设备' });
  }

  // ---------- 连接 ----------
  async connectDevice(dev: DeviceItem): Promise<void> {
    if (this.connectBusy) {
      return;
    }
    this.connectBusy = true;
    try {
      this.appendLog('正在连接 ' + (dev.deviceName || dev.deviceId) + ' (' + dev.rssi + ' dBm)...');
      await BleService.connect(dev.deviceId);
      this.appendLog('已连接, 使能通知...');
      await BleService.enableNotify((value: Uint8Array) => {
        this.onNotify(value);
      });
      this.connected = true;
      this.connAddr = dev.deviceId;
      this.stateText = '连接中...';
      this.stateColor = '#3A86FF';
      this.appendLog('握手同步 (01 03)...');
      await sleep(1000);
      await BleService.write(makeSyncCmd());
      this.appendLog('等待设备推送状态...');
      // 5 秒无数据检测: 帮助区分"设备没回"与"通知事件/写类型问题"
      this.gotNotify = false;
      setTimeout(() => {
        if (this.connected && !this.gotNotify) {
          this.appendLog('5 秒内未收到设备推送。可能原因: 写类型不匹配 / 通知事件未生效 / 设备休眠。已自动再次请求状态。');
          BleService.write(makeSyncCmd()).then(() => {
            this.appendLog('已重发 01 03。');
          }).catch((e: Error) => {
            this.appendLog('重发失败: ' + JSON.stringify(e));
          });
        }
      }, 5000);
    } catch (e) {
      hilog.error(0x0000, TAG, 'connect failed: %{public}s', JSON.stringify(e));
      this.connected = false;
      this.stateText = '连接失败';
      this.stateColor = '#E5484D';
      this.appendLog('连接失败: 设备可能没有 FFF0 服务或已休眠。');
      promptAction.showToast({ message: '连接失败, 请确认设备为 SHISON 加热器' });
    }
    this.connectBusy = false;
  }

  onNotify(value: Uint8Array): void {
    this.gotNotify = true;
    this.appendLog('收: ' + bytesToHex(value));
    const data: NotifyData | null = parseNotify(value);
    if (!data) {
      return;
    }
    if (data.kind === 'status') {
      this.currentTemp = data.temp.toFixed(1);
      this.stateText = data.stateText;
      this.stateColor = data.mode === 3 ? '#FF7A00' : (data.mode <= 2 ? '#E5484D' : '#22A06B');
      this.unitText = data.unit === 'C' ? '℃' : '℉';
    } else if (data.kind === 'target') {
      this.targetTemp = data.target.toFixed(1);
      this.appendLog('目标温度回显: ' + data.target.toFixed(1) + (this.unitText === '℉' ? ' ℉' : ' ℃'));
    } else if (data.kind === 'history') {
      const s = data.history.join(', ');
      this.appendLog('第 ' + data.segment + ' 段历史: ' + s);
    }
  }

  // ---------- 控制 ----------
  async setTemp(): Promise<void> {
    if (!this.connected) {
      return;
    }
    const v = Number.parseFloat(this.tempInput);
    if (Number.isNaN(v) || v < 0) {
      promptAction.showToast({ message: '请输入有效温度' });
      return;
    }
    try {
      await BleService.write(makeTempCmd(v));
      this.appendLog('设温度 -> ' + bytesToHex(makeTempCmd(v)) + ' (' + v + ')');
    } catch (e) {
      this.appendLog('设置失败: ' + JSON.stringify(e));
    }
  }

  async switchUnit(): Promise<void> {
    if (!this.connected) {
      return;
    }
    try {
      await BleService.write(makeUnitCmd());
      this.appendLog('切换单位 (31 02)');
    } catch (e) {
      this.appendLog('切换失败: ' + JSON.stringify(e));
    }
  }

  async refreshStatus(): Promise<void> {
    if (!this.connected) {
      return;
    }
    try {
      await BleService.write(makeSyncCmd());
      this.appendLog('刷新状态 (01 03)');
    } catch (e) {
      this.appendLog('刷新失败: ' + JSON.stringify(e));
    }
  }

  async hourHistory(): Promise<void> {
    if (!this.connected) {
      return;
    }
    try {
      await BleService.write(makeHourHistoryCmd());
      this.appendLog('请求小时历史 (31 04)');
    } catch (e) {
      this.appendLog('请求失败: ' + JSON.stringify(e));
    }
  }

  async minuteHistory(): Promise<void> {
    if (!this.connected) {
      return;
    }
    try {
      await BleService.write(makeMinuteHistoryCmd());
      this.appendLog('请求分钟历史 (31 03)');
    } catch (e) {
      this.appendLog('请求失败: ' + JSON.stringify(e));
    }
  }

  async disconnect(): Promise<void> {
    if (this.scanning) {
      this.stopScan();
    }
    await BleService.disconnect();
    this.connected = false;
    this.stateText = '已断开';
    this.stateColor = '#999999';
    this.currentTemp = '--';
    this.targetTemp = '--';
    this.appendLog('已断开连接。');
  }

  // ---------- UI ----------
  build() {
    Column({ space: 10 }) {
      // 标题
      Row() {
        Text('SHISON 加热器')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
        Blank()
        Text(this.connected ? '● 已连接' : '○ 未连接')
          .fontSize(13)
          .fontColor(this.connected ? '#22A06B' : '#999999')
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10 })

      // 状态大字
      Column({ space: 4 }) {
        Row() {
          Text(this.currentTemp)
            .fontSize(52)
            .fontWeight(FontWeight.Bold)
            .fontColor('#222222')
          Text(this.unitText)
            .fontSize(22)
            .fontColor('#666666')
            .margin({ top: 18 })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        Text('当前温度')
          .fontSize(13)
          .fontColor('#888888')
        Row({ space: 8 }) {
          Text('目标: ' + this.targetTemp + this.unitText)
            .fontSize(15)
            .fontColor('#333333')
          Text(this.stateText)
            .fontSize(15)
            .fontColor(this.stateColor)
            .fontWeight(FontWeight.Medium)
        }
        .margin({ top: 4 })
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })
      .backgroundColor('#F5F5F5')
      .borderRadius(14)

      // 扫描区
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Button(this.scanning ? '停止扫描' : '扫描设备')
            .onClick(() => {
              if (this.scanning) {
                this.stopScan();
              } else {
                this.startScan();
              }
            })
          Button('断开')
            .enabled(this.connected)
            .backgroundColor('#E5484D')
            .onClick(() => {
              this.disconnect();
            })
        }
        .width('100%')

        List({ space: 4 }) {
          ForEach(this.devices, (dev: DeviceItem) => {
            ListItem() {
              Row({ space: 6 }) {
                Text(dev.isHeater ? '★' : ' ')
                  .fontSize(16)
                  .fontColor('#FF7A00')
                Column({ space: 2 }) {
                  Text(dev.deviceName === '' ? '(无名称)' : dev.deviceName)
                    .fontSize(15)
                    .fontWeight(dev.isHeater ? FontWeight.Bold : FontWeight.Normal)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(dev.deviceId + '  ' + dev.rssi + ' dBm' + (dev.isHeater ? '  [FFF0 加热器]' : ''))
                    .fontSize(11)
                    .fontColor('#999999')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding(8)
              .backgroundColor('#FAFAFA')
              .borderRadius(8)
              .onClick(() => {
                this.connectDevice(dev);
              })
            }
          }, (dev: DeviceItem) => dev.deviceId)
        }
        .width('100%')
        .height(170)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#FFFFFF')
      .borderRadius(14)

      // 控制区
      Row({ space: 8 }) {
        TextInput({ text: this.tempInput, placeholder: '目标温度' })
          .type(InputType.Number)
          .onChange((v: string) => {
            this.tempInput = v;
          })
          .layoutWeight(1)
        Button('设温度')
          .enabled(this.connected)
          .onClick(() => {
            this.setTemp();
          })
        Button('切单位')
          .enabled(this.connected)
          .backgroundColor('#6B7280')
          .onClick(() => {
            this.switchUnit();
          })
        Button('刷新')
          .enabled(this.connected)
          .backgroundColor('#3A86FF')
          .onClick(() => {
            this.refreshStatus();
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Button('小时历史')
          .enabled(this.connected)
          .layoutWeight(1)
          .onClick(() => {
            this.hourHistory();
          })
        Button('分钟历史')
          .enabled(this.connected)
          .layoutWeight(1)
          .onClick(() => {
            this.minuteHistory();
          })
      }
      .width('100%')

      // 日志
      Column() {
        Text('日志')
          .fontSize(13)
          .fontColor('#888888')
          .width('100%')
        Scroll(this.scroller) {
          Text(this.logText)
            .fontSize(11)
            .fontColor('#555555')
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.On)
      }
      .width('100%')
      .layoutWeight(1)
      .padding(8)
      .backgroundColor('#F0F0F0')
      .borderRadius(10)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, bottom: 12 })
    .backgroundColor('#FFFFFF')
  }
}
