/**
 * SHISON 加热器 蓝牙控制面板 (鸿蒙)
 */
import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ble } from '@kit.ConnectivityKit';
import { fileIo } from '@kit.CoreFileKit';
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
import { DeviceStore, SavedDevice } from '../common/DeviceStore';

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

/**
 * 扫描结果弹窗: 对齐安卓原版 showScanDialog, 扫描到的设备实时列出, 点击即连
 */
@CustomDialog
struct ScanDialog {
  controller: CustomDialogController;
  @Link devices: DeviceItem[];
  @Link scanning: boolean;
  @Link savedDevices: SavedDevice[];
  connect: (dev: DeviceItem) => void = () => {
  };
  stopScan: () => void = () => {
  };
  restartScan: () => void = () => {
  };
  /** 从已保存设备库直接连接 */
  connectSaved: (dev: SavedDevice) => void = () => {
  };
  /** 切换设备的自动连接标记 */
  toggleAuto: (dev: SavedDevice) => void = () => {
  };
  /** 弹窗关闭(取消/点外部/连接后)时回调, 用于统一停止扫描 */
  onDismiss: () => void = () => {
  };

  aboutToDisappear(): void {
    this.onDismiss();
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('选择设备')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1D1D1F')
        Blank()
        Text(this.scanning ? '扫描中...' : '扫描已停止')
          .fontSize(12)
          .fontColor(this.scanning ? '#3A86FF' : '#8A8F98')
      }
      .width('100%')

      if (this.savedDevices.length > 0) {
        Scroll() {
          Column({ space: 4 }) {
            Text('已保存设备 (开启"自动"后下次自动连接)')
              .fontSize(12)
              .fontColor('#8A8F98')
              .width('100%')
            ForEach(this.savedDevices, (d: SavedDevice) => {
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text(d.name === '' ? '(无名称)' : d.name)
                    .fontSize(14)
                    .fontColor('#1D1D1F')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(d.address)
                    .fontSize(11)
                    .fontColor('#8A8F98')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Button('连接')
                  .height(32)
                  .fontSize(13)
                  .backgroundColor('#3A86FF')
                  .onClick(() => {
                    this.connectSaved(d);
                  })
                Toggle({ type: ToggleType.Switch, isOn: d.autoConnect })
                  .width(44)
                  .height(28)
                  .onChange(() => {
                    this.toggleAuto(d);
                  })
              }
              .width('100%')
              .padding(8)
              .backgroundColor('#EAF1FB')
              .borderRadius(8)
            }, (d: SavedDevice) => d.address)
          }
          .width('100%')
        }
        .width('100%')
        .height(120)
        .scrollBar(BarState.Auto)
      }

      if (this.devices.length === 0) {
        Column({ space: 6 }) {
          Text(this.scanning ? '正在搜索蓝牙设备...' : '未发现设备')
            .fontSize(14)
            .fontColor('#8A8F98')
          Text('确认加热器已通电开机、靠近手机(1米内)')
            .fontSize(11)
            .fontColor('#A0A4AB')
        }
        .width('100%')
        .height(200)
        .justifyContent(FlexAlign.Center)
      } else {
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
                    .fontColor('#1D1D1F')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(dev.deviceId + '  ' + dev.rssi + ' dBm' +
                    (dev.isHeater ? '  [FFF0 加热器]' : ''))
                    .fontSize(11)
                    .fontColor('#8A8F98')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding(10)
              .backgroundColor('#F5F7FA')
              .borderRadius(8)
              .shadow({ radius: 6, color: '#203A86FF', offsetY: 2 })
              .onClick(() => {
                this.connect(dev);
              })
            }
          }, (dev: DeviceItem) => dev.deviceId)
        }
        .width('100%')
        .height(200)
        .scrollBar(BarState.Auto)
      }

      Row({ space: 8 }) {
        Button(this.scanning ? '停止扫描' : '重新扫描')
          .layoutWeight(1)
          .backgroundColor('#3A86FF')
          .shadow({ radius: 12, color: '#403A86FF', offsetY: 3 })
          .onClick(() => {
            if (this.scanning) {
              this.stopScan();
            } else {
              this.restartScan();
            }
          })
        Button('取消')
          .layoutWeight(1)
          .backgroundColor('#E5484D')
          .shadow({ radius: 12, color: '#40E5484D', offsetY: 3 })
          .onClick(() => {
            this.controller.close();
          })
      }
      .width('100%')
    }
    .width('92%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .shadow({ radius: 24, color: '#403A86FF', offsetY: 8 })
  }
}

@Entry
@Component
struct Index {
  @State scanning: boolean = false;
  @State devices: DeviceItem[] = [];
  @State connected: boolean = false;
  @State connAddr: string = '';
  @State connName: string = '';
  @State stateText: string = '未连接';
  @State stateColor: string = '#999999';
  @State currentTemp: string = '--';
  @State targetTemp: string = '--';
  @State unitText: string = '℃';
  @State tempInput: string = '26';
  /** 目标温度滑块值 (与 tempInput 同步) */
  @State sliderVal: number = 26;
  /** 设备侧目标温度原始值/10 (单位无关, 安卓 3101 公式的输入) */
  @State rawTarget: number = 0;
  /** 设备实际档位 (3001 推送, 'C'/'F'/''未知); 写入与回显换算以此为准, 避免 APP 与设备单位脱钩 */
  @State deviceUnit: string = '';
  /** 本次启动是否已尝试过自动重连 (只尝试一次) */
  private autoReconnectTried: boolean = false;
  /** 切单位过渡标记: 设备 31 02 后目标会被重置为默认(28℃/83℉), 需重写目标并忽略期间回显 */
  private unitSwitchPending: boolean = false;
  /** 切单位过渡期截止时间戳: 期间(3秒)忽略设备默认目标回显, 防止 28°/83° 闪烁 */
  private unitSwitchIgnoreUntil: number = 0;
  @State historyStats: string = '';
  @State lastMode: number = -1;
  /** 历史温度采样点 (累积 24小时/60分钟曲线) */
  @State histSamples: number[] = [];
  /** 每个采样点的横轴标签: 小时历史 "HH:00", 分钟历史 分钟序号 */
  @State histLabels: string[] = [];
  /** 当前历史类型: 'hour' | 'minute' */
  @State histKind: string = 'hour';
  /** 小时历史起始时点 (请求时取当前小时+1, 安卓原版行为) */
  private hourBase: number = 0;
  private histCtx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  @State logText: string = 'SICN v26.43 (build 2026-10-31) 启动。连接已加自动重试(3次)。点击"扫描设备"开始搜索加热器。';
  @State connectBusy: boolean = false;
  /** 已保存设备库(对应安卓 DeviceRecord, 多设备记忆 + 自动连接) */
  @State savedDevices: SavedDevice[] = [];
  /** 报警页是否已弹出(同一报警只弹一次, onPageShow 复位) */
  @State alarmShown: boolean = false;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private seenIds: Set<string> = new Set<string>();
  private scroller: Scroller = new Scroller();
  private permissionOk: boolean = false;
  private scanGotAny: boolean = false;
  private gotNotify: boolean = false;
  /** 扫描设备弹窗 (对齐安卓 showScanDialog) */
  private dialogCtrl: CustomDialogController = new CustomDialogController({
    builder: ScanDialog({
      devices: $devices,
      scanning: $scanning,
      savedDevices: $savedDevices,
      connect: (dev: DeviceItem) => {
        this.dialogCtrl.close();
        this.connectDevice(dev);
      },
      stopScan: () => {
        this.stopScan();
      },
      restartScan: () => {
        this.restartScan();
      },
      connectSaved: (dev: SavedDevice) => {
        this.connectSaved(dev);
      },
      toggleAuto: (dev: SavedDevice) => {
        this.toggleAuto(dev);
      },
      onDismiss: () => {
        this.stopScan();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  aboutToDisappear(): void {
    if (this.scanning) {
      this.stopScan();
    }
    if (this.connected) {
      BleService.disconnect();
    }
  }

  onPageShow(): void {
    this.alarmShown = false;
    BleService.diagListener = (s: string): void => {
      this.appendLog(s);
    };
    this.appendLog('检查蓝牙权限...');
    BleService.requestPermission(this.context).then((ok: boolean) => {
      this.permissionOk = ok;
      if (!ok) {
        this.appendLog('蓝牙权限未授权。点\"扫描设备\"时若失败, 请到 设置-应用-权限管理 开启蓝牙权限。');
      } else {
        this.appendLog('蓝牙权限已授权。');
      }
      // 用系统接口复核权限真实授予状态 (诊断用)
      BleService.checkPermission(this.context).then((grant: string) => {
        this.appendLog('权限系统状态: ' + grant);
      });
      BleService.isBluetoothOn().then((on: boolean) => {
        if (on) {
          this.appendLog('蓝牙已开启。');
        } else {
          this.appendLog('警告: 蓝牙未开启, 请打开系统蓝牙。');
        }
      });
      // 加载已保存设备库
      DeviceStore.load(this.context).then((list: SavedDevice[]) => {
        this.savedDevices = list;
      });
      // 自动重连上次连接的设备
      this.tryAutoReconnect();
    });
  }

  /** 自动重连: 优先连接设备库里标记 autoConnect 的设备, 否则回退旧版 last_addr */
  private async tryAutoReconnect(): Promise<void> {
    if (this.autoReconnectTried) {
      return;
    }
    this.autoReconnectTried = true;
    try {
      // 优先: 设备库里开启自动连接的设备(取 lastSeen 最新的一台)
      const auto: SavedDevice | null = await DeviceStore.getAutoConnect(this.context);
      if (auto !== null) {
        this.appendLog('发现已开启自动连接的设备 ' + (auto.name || auto.address) + ', 自动重连...');
        await this.connectDevice(new DeviceItem(auto.address, auto.name, 0, true), true);
        return;
      }
      // 回退: 旧版 last_addr
      const last: SavedDevice | null = await DeviceStore.getLastConnected(this.context);
      if (last === null || last.address === '') {
        this.appendLog('无上次连接记录, 跳过自动重连。');
        return;
      }
      this.appendLog('发现上次连接设备 ' + (last.name || last.address) + ', 自动重连...');
      await this.connectDevice(new DeviceItem(last.address, last.name, 0, true), true);
    } catch (e) {
      this.appendLog('自动重连失败: ' + JSON.stringify(e));
    }
  }

  /** 保存上次连接设备 (供下次启动自动重连) */
  private async saveLastDevice(addr: string, name: string): Promise<void> {
    try {
      const pref = await preferences.getPreferences(this.context, 'sicn_pref');
      await pref.put('last_addr', addr);
      await pref.put('last_name', name);
      await pref.flush();
      this.appendLog('已记住设备 ' + (name || addr) + ', 下次启动自动连接。');
    } catch (e) {
      this.appendLog('保存设备记录失败: ' + JSON.stringify(e));
    }
  }

  /** 从已保存设备库直接连接 */
  private connectSaved(dev: SavedDevice): void {
    this.dialogCtrl.close();
    this.connectDevice(new DeviceItem(dev.address, dev.name, 0, true));
  }

  /** 切换设备的自动连接标记 (对应安卓 auto_connect) */
  private toggleAuto(dev: SavedDevice): void {
    const next: boolean = !dev.autoConnect;
    DeviceStore.setAutoConnect(this.context, dev.address, next).then((list: SavedDevice[]) => {
      this.savedDevices = list;
      this.appendLog('已' + (next ? '开启' : '关闭') + ' ' + (dev.name || dev.address) + ' 的自动连接。');
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
    this.fileLog(s);
  }

  /** 写文件日志 (鸿蒙7 hilog 对普通 App 封闭, 文件日志供 hdc 直读) */
  fileLog(s: string): void {
    try {
      const dir = this.context.filesDir;
      const p = dir + '/sicn_log.txt';
      const f = fileIo.openSync(p, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.APPEND);
      fileIo.writeSync(f.fd, '[' + new Date().toISOString() + '] ' + s + '\n');
      fileIo.closeSync(f);
    } catch (e) {
      // 文件日志失败不影响主流程
    }
  }

  // ---------- 扫描 ----------
  startScan(): void {
    if (this.scanning) {
      return;
    }
    this.seenIds.clear();
    this.devices = [];
    this.scanning = true;
    this.scanGotAny = false;
    this.appendLog('开始扫描...');
    promptAction.showToast({ message: '正在扫描蓝牙设备...' });
    // 打开设备选择弹窗
    try {
      this.dialogCtrl.open();
    } catch (e) {
      // 弹窗打开失败不阻断扫描
      this.appendLog('弹窗打开失败: ' + JSON.stringify(e));
    }
    // 扫描前先查权限真实状态 (诊断 + 自愈)
    BleService.checkPermission(this.context).then((grant: string) => {
      this.appendLog('扫描前权限系统状态: ' + grant);
      if (grant !== 'granted') {
        this.appendLog('权限未授予, 尝试重新申请...');
        BleService.requestPermission(this.context).then((ok2: boolean) => {
          this.permissionOk = ok2;
          this.appendLog(ok2 ? '重新申请成功。' : '重新申请仍失败, 请到 设置-应用-权限管理 手动开启蓝牙权限。');
        });
      } else {
        this.permissionOk = true;
      }
    });
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
      this.appendLog('若报错含 401/201: 请到 设置→应用→SICN加热器→权限, 手动开启"附近设备/蓝牙"权限后重试。');
      promptAction.showToast({ message: msg });
    }, (info: string) => {
      this.appendLog(info);
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

  async stopScan(): Promise<void> {
    this.scanning = false;
    await BleService.stopScan();
    const n: number = this.devices.length;
    this.appendLog('扫描停止, 共发现 ' + n + ' 台设备。');
    promptAction.showToast({ message: n > 0 ? ('发现 ' + n + ' 台设备') : '未发现设备' });
  }

  /** 重新扫描: 先关闭当前弹窗(触发停扫), 再重新开始扫描并重新打开弹窗 */
  restartScan(): void {
    try {
      this.dialogCtrl.close();
    } catch (e) {
      // 弹窗可能未打开, 忽略
    }
    this.startScan();
  }

  // ---------- 连接 ----------

  /**
   * 连接前预扫描: 确认目标地址是否真的在附近, 并把附近"疑似加热器"的名称/地址/RSSI 写入日志。
   *
   * 连接超时有两种完全不同的原因, 必须区分:
   *   a) 设备不在范围/没通电 -> 扫描根本发现不了它
   *   b) 设备已被别的手机或旧连接占用 -> 扫描能发现, 但 connect 被拒/超时
   * 旧版只记录"发现 N 台设备", 名称不落日志, 现场无法判断是哪一种。
   *
   * @returns 目标地址是否在本次预扫描中出现
   */
  private probeNearby(address: string): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let found: boolean = false;
      const seenAddr: Set<string> = new Set<string>();
      let total: number = 0;
      this.appendLog('连接前预扫描 5 秒, 确认设备是否在附近...');
      BleService.startScan((list: Array<ble.ScanResult>) => {
        for (const d of list) {
          total++;
          const nm: string = d.deviceName ?? '';
          const cand: boolean = nm.toLowerCase().includes('sicn') ||
            nm.toLowerCase().includes('heater') || hasFff0Service(d.data);
          if (cand && !seenAddr.has(d.deviceId)) {
            seenAddr.add(d.deviceId);
            this.appendLog('附近候选: ' + (nm === '' ? '(无名)' : nm) + ' ' + d.deviceId +
              ' rssi=' + d.rssi + (hasFff0Service(d.data) ? ' [含FFF0]' : ''));
          }
          if (d.deviceId.toUpperCase() === address.toUpperCase()) {
            found = true;
            if (!seenAddr.has('__target__')) {
              seenAddr.add('__target__');
              this.appendLog('目标设备已出现: ' + (nm === '' ? '(无名)' : nm) + ' rssi=' + d.rssi);
            }
          }
        }
      }, (msg: string) => {
        this.appendLog('预扫描失败: ' + msg);
      }, (info: string) => {
        this.appendLog(info);
      });
      setTimeout(() => {
        BleService.stopScan().then(() => {
          this.appendLog('预扫描结束: 共 ' + total + ' 条广播, 候选 ' + seenAddr.size +
            ' 台, 目标' + (found ? '在附近' : '未出现'));
          resolve(found);
        });
      }, 5000);
    });
  }

  async connectDevice(dev: DeviceItem, silent: boolean = false): Promise<void> {
    if (this.connectBusy) {
      return;
    }
    this.connectBusy = true;
    try {
      // 连接前必须停扫并等蓝牙栈真正释放: 扫描占着 stack 会导致 connect 被拒或超时
      this.scanning = false;
      await BleService.stopScan();
      // 预扫描: 判断"不在范围"还是"被占用", 顺带记录附近加热器的名称/RSSI
      const nearby: boolean = await this.probeNearby(dev.deviceId);
      if (!nearby) {
        this.appendLog('!! 目标设备未在预扫描中出现: 多半是加热器未通电/不在范围内。');
        this.appendLog('提示: 通电后屏幕应亮起; 也有可能已被其他手机或旧版 App 占着连接。');
      }
      this.appendLog('开始连接 ' + (dev.deviceName || dev.deviceId) +
        ' (' + dev.rssi + ' dBm), 最多尝试 ' + (nearby ? '3' : '1') + ' 次...');
      await BleService.connect(dev.deviceId, nearby ? 3 : 1);
      this.appendLog('已连接, 使能通知...');
      await BleService.enableNotify((value: Uint8Array) => {
        this.onNotify(value);
      });
      this.connected = true;
      this.connAddr = dev.deviceId;
      this.connName = dev.deviceName || '';
      this.stateText = '已连接, 等待设备数据...';
      this.stateColor = '#22A06B';
      this.appendLog('特征: ' + BleService.describeChar());
      // 记住该设备, 下次启动自动重连
      this.saveLastDevice(dev.deviceId, dev.deviceName || '');
      // 记录进设备库(多设备记忆, 支持自动连接)
      DeviceStore.upsert(this.context, dev.deviceId, dev.deviceName || '').then((list: SavedDevice[]) => {
        this.savedDevices = list;
      });
      // UI 释放, 握手在后台进行, 不再卡"连接中"
      this.connectBusy = false;
      this.gotNotify = false;
      // 对齐 Android 原版时序: 通知使能(含写CCCD) 后 ~1.5s 写 01 03
      this.syncLoop(1500);
      this.syncLoop(6500);
      this.syncLoop(11500);
    } catch (e) {
      const detail: string = BleService.describeError(e);
      hilog.error(0x0000, TAG, 'connect failed: %{public}s', detail);
      this.connected = false;
      this.stateText = '连接失败';
      this.stateColor = '#E5484D';
      this.appendLog('连接失败: ' + detail);
      this.appendLog('原因: ' + BleService.hintFor(e));
      if (silent) {
        this.appendLog('自动重连失败, 请点"扫描设备"手动连接。');
      }
      if (!silent) {
        promptAction.showToast({ message: '连接失败, 请靠近设备重试' });
      }
      BleService.disconnect();
      this.connectBusy = false;
    }
  }

  /** 握手: 延迟 ms 毫秒后写 01 03; 若已收到数据则跳过 */
  private syncLoop(delayMs: number): void {
    setTimeout(() => {
      if (!this.connected || this.gotNotify) {
        return;
      }
      this.appendLog(delayMs === 1500 ? '握手同步 (01 03)...' :
        (delayMs === 6500 ? '6.5 秒未收到推送, 重发 01 03 (1/2)...' : '11.5 秒未收到推送, 重发 01 03 (2/2)...'));
      BleService.write(makeSyncCmd()).then(() => {
        this.appendLog('已发送 01 03。');
        // 首次握手后额外主动读一次 FFF1 (通知可能没使能, 读通道兜底)
        if (delayMs === 1500) {
          BleService.readOnce();
          this.appendLog('已尝试主动读取 FFF1...');
        }
      }).catch((e: Error) => {
        this.appendLog('握手写失败: ' + JSON.stringify(e));
      });
    }, delayMs);
  }

  onNotify(value: Uint8Array): void {
    this.gotNotify = true;
    this.appendLog('收(' + value.length + 'B): ' + bytesToHex(value));
    const data: NotifyData | null = parseNotify(value);
    if (!data) {
      this.appendLog('!! 无法解析, 头部=' + (value.length > 1 ?
        ('0x' + value[0].toString(16) + ' 0x' + value[1].toString(16)) : '太短'));
      return;
    }
    this.appendLog('解析: kind=' + data.kind + ' temp=' + data.temp +
      ' mode=' + data.mode + ' unit=' + data.unit +
      ' target=' + data.target + ' seg=' + data.segment +
      ' hist=' + data.history.length);
    if (data.kind === 'status') {
      // 记录设备实际档位 (写入/回显换算的权威依据)
      this.deviceUnit = data.unit;
      // 当前温度: 3001 编码值按设备档位单位, 需换算成 APP 显示档位
      let cur: number = data.temp;
      if (data.unit === 'F' && this.unitText === '℃') {
        cur = (cur - 32) / 1.8;
      } else if (data.unit === 'C' && this.unitText === '℉') {
        cur = cur * 1.8 + 32;
      }
      this.currentTemp = cur.toFixed(1);
      this.stateText = data.stateText;
      // 颜色: 加热(3)橙、故障/保护(0~2)红、恒温(4)/降温(5)绿
      this.stateColor = data.mode === 3 ? '#FF7A00' : (data.mode <= 2 ? '#E5484D' : '#22A06B');
      // 单位映射(安卓实测): byte3=1->℉, byte3=0->℃
      const oldUnit: string = this.unitText;
      this.unitText = data.unit === 'C' ? '℃' : '℉';
      // 设备单位变化时, 目标温度按物理换算四舍五入刷新显示 (设备 3101 编码在切单位瞬间不可靠)
      if (oldUnit !== this.unitText) {
        const cur: number = Number.parseFloat(this.tempInput);
        if (!Number.isNaN(cur) && cur > 0) {
          let next: number;
          if (this.unitText === '℉') {
            next = Math.round(cur * 1.8 + 32);
          } else {
            next = Math.round((cur - 32) / 1.8 * 2) / 2;
          }
          const lo: number = this.tempMin();
          const hi: number = this.tempMax();
          if (next < lo) {
            next = lo;
          } else if (next > hi) {
            next = hi;
          }
          this.updateTempInput(next.toFixed(1));
          this.targetTemp = next.toFixed(1);
        }
        this.appendLog('设备确认单位 ' + this.unitText + ', 目标 ' + this.tempInput + this.unitText);
      }
      // 警报提示 (对齐安卓 AlarmActivity: 0探头故障/1离水断电/2超温; 报警页显示「超温保护」)
      if (data.mode >= 0 && data.mode <= 2 && this.lastMode !== data.mode) {
        promptAction.showToast({ message: '警报: ' + data.stateText });
        // 进入独立报警页(脉冲动画+震动), 同一报警只弹一次, 返回后由 onPageShow 复位
        if (!this.alarmShown) {
          this.alarmShown = true;
          router.pushUrl({
            url: 'pages/AlarmPage',
            params: {
              mode: data.mode,
              temp: data.temp,
              unit: data.unit === 'F' ? '℉' : '℃'
            }
          }).catch((e: Error) => {
            this.appendLog('打开报警页失败: ' + JSON.stringify(e));
          });
        }
      }
      this.lastMode = data.mode;
      // 切单位过渡: 设备目标已被重置为默认, 用当前换算目标重写设备
      if (this.unitSwitchPending) {
        this.writeTargetAfterUnitSwitch();
      }
    } else if (data.kind === 'target') {
      // 切单位过渡期(3秒): 设备会回推默认目标(28℃/83℉), 不是真实目标, 一律忽略防止闪烁
      if (Date.now() < this.unitSwitchIgnoreUntil) {
        this.appendLog('!! 切单位过渡中, 忽略设备默认目标回显 ' + data.target.toFixed(1) +
          this.unitText + ' (等待重写)');
        return;
      }
      // 无偏移协议: raw 即温度
      this.rawTarget = data.target;
      const shown: number = this.rawToDisplay(this.rawTarget);
      // 范围校验: 设备切单位/异常状态下可能推无效编码(负值/超界), 忽略以免污染输入框
      if (this.tempValid(shown)) {
        // 差异校验: 回显与本地目标差异过大时视为设备异常目标(如切单位后推默认值), 不覆盖用户设置
        const local: number = Number.parseFloat(this.tempInput);
        if (!Number.isNaN(local) && Math.abs(shown - local) > 5) {
          this.appendLog('!! 目标回显(' + shown.toFixed(1) + this.unitText +
            ')与本地(' + local.toFixed(1) + ')差异过大, 保持本地目标');
        } else {
          this.targetTemp = shown.toFixed(1);
          this.updateTempInput(shown.toFixed(1));
          this.appendLog('目标温度回显: ' + shown.toFixed(1) + this.unitText +
            ' (原始 ' + data.target.toFixed(1) + ')');
        }
      } else {
        this.appendLog('!! 目标回显超出合理范围(' + shown.toFixed(1) + this.unitText +
          '), 保持当前目标 ' + this.tempInput + this.unitText);
      }
    } else if (data.kind === 'history') {
      const vals: number[] = data.history;
      const seg: number = data.segment;
      // 段号 1 或类型切换 = 新一轮请求, 清空重来 (安卓: 段号==1 时 clear)
      if (seg === 1 || data.histKind !== this.histKind) {
        this.histSamples = [];
        this.histLabels = [];
        this.histKind = data.histKind;
      }
      // 追加采样点 + 横轴标签
      for (let i = 0; i < vals.length; i++) {
        this.histSamples = [...this.histSamples, vals[i]];
        if (data.histKind === 'hour') {
          // 安卓: 时点 = mHour + i + (段号-1)*8, 取模 24; mHour = 请求时当前小时+1
          const hh: number = ((this.hourBase + i + (seg - 1) * 8) % 24 + 24) % 24;
          this.histLabels = [...this.histLabels, (hh < 10 ? '0' : '') + hh + ':00'];
        } else {
          // 分钟历史: 标签 = 分钟序号 (段号-1)*8 + i + 1
          this.histLabels = [...this.histLabels, String((seg - 1) * 8 + i + 1)];
        }
      }
      // 上限保护
      if (this.histSamples.length > 240) {
        this.histSamples = this.histSamples.slice(this.histSamples.length - 240);
        this.histLabels = this.histLabels.slice(this.histLabels.length - 240);
      }
      // 全段统计 (对齐安卓 HistoryDialog min/max/avg)
      if (this.histSamples.length > 0) {
        let mn: number = this.histSamples[0];
        let mx: number = this.histSamples[0];
        let sum: number = 0;
        for (const v of this.histSamples) {
          if (v < mn) {
            mn = v;
          }
          if (v > mx) {
            mx = v;
          }
          sum += v;
        }
        const avg: number = sum / this.histSamples.length;
        this.historyStats = (data.histKind === 'hour' ? '24小时' : '60分钟') +
          ' 第' + seg + '段: ' + this.histSamples.length + '点  最低' +
          mn.toFixed(1) + ' 最高' + mx.toFixed(1) + ' 平均' + avg.toFixed(1);
      }
      this.appendLog('第 ' + seg + ' 段' + (data.histKind === 'hour' ? '小时' : '分钟') +
        '历史(' + vals.length + '点): ' + vals.join(', '));
      // 重绘曲线
      this.drawHist();
    }
  }

  /** 绘制历史温度曲线 (Canvas 折线图, 无第三方依赖) */
  private drawHist(): void {
    const c: CanvasRenderingContext2D = this.histCtx;
    const w: number = c.width;
    const h: number = c.height;
    if (w <= 0 || h <= 0 || this.histSamples.length < 2) {
      return;
    }
    c.clearRect(0, 0, w, h);
    const pts: number[] = this.histSamples;
    let mn: number = pts[0];
    let mx: number = pts[0];
    for (const v of pts) {
      if (v < mn) {
        mn = v;
      }
      if (v > mx) {
        mx = v;
      }
    }
    if (mx - mn < 0.5) {
      mn -= 0.5;
      mx += 0.5;
    }
    const pad: number = 26;
    const x0: number = pad;
    const x1: number = w - 4;
    const y0: number = h - 14;
    const y1: number = 8;
    // 网格 + Y 轴刻度 (4 条)
    c.strokeStyle = '#EDF0F4';
    c.lineWidth = 1;
    for (let g = 0; g <= 3; g++) {
      const gy: number = y0 + (g / 3) * (y1 - y0);
      c.beginPath();
      c.moveTo(x0, gy);
      c.lineTo(x1, gy);
      c.stroke();
      const tick: number = mx - (g / 3) * (mx - mn);
      c.fillStyle = '#8A8F98';
      c.font = '9vp sans-serif';
      c.textAlign = 'right';
      c.fillText(tick.toFixed(1), x0 - 3, gy + 3);
    }
    // 折线
    c.strokeStyle = '#3A86FF';
    c.lineWidth = 2;
    c.beginPath();
    const n: number = pts.length;
    for (let i = 0; i < n; i++) {
      const px: number = x0 + (i / (n - 1)) * (x1 - x0);
      const py: number = y0 - ((pts[i] - mn) / (mx - mn)) * (y0 - y1);
      if (i === 0) {
        c.moveTo(px, py);
      } else {
        c.lineTo(px, py);
      }
    }
    c.stroke();
    // 数据点 (密集时只画小点)
    c.fillStyle = '#FF7A00';
    const dotR: number = n > 40 ? 1.6 : 2.5;
    for (let i = 0; i < n; i++) {
      const px: number = x0 + (i / (n - 1)) * (x1 - x0);
      const py: number = y0 - ((pts[i] - mn) / (mx - mn)) * (y0 - y1);
      c.beginPath();
      c.arc(px, py, dotR, 0, Math.PI * 2);
      c.fill();
    }
    // 底部横轴标签 (首/25%/50%/75%/尾)
    c.fillStyle = '#8A8F98';
    c.font = '9vp sans-serif';
    c.textAlign = 'center';
    const labelIdx: number[] = [0, Math.floor(n / 4), Math.floor(n / 2), Math.floor(3 * n / 4), n - 1];
    for (const li of labelIdx) {
      const px: number = x0 + (li / (n - 1)) * (x1 - x0);
      const lb: string = li < this.histLabels.length ? this.histLabels[li] : '';
      c.fillText(lb, px, h - 3);
    }
  }

  // ---------- 控制 ----------
  /** 设备原始目标值(raw) -> 显示值: 无偏移协议, raw 即温度 (与 3001 一致, 2026-10-30 实测修正) */
  private rawToDisplay(raw: number): number {
    return raw;
  }

  /** raw/10 -> 显示字符串 (一位小数) */
  private displayFromRaw(raw: number): string {
    return this.rawToDisplay(raw).toFixed(1);
  }

  /** 目标温度合理范围: ℃ [18,34], ℉ [64,93] (用户指定; 超出视为设备异常回显/输入, 防污染防溢出) */
  private tempMin(): number {
    return this.unitText === '℉' ? 64 : 18;
  }

  private tempMax(): number {
    return this.unitText === '℉' ? 93 : 34;
  }

  /** 校验显示值是否合理 */
  private tempValid(t: number): boolean {
    return t >= this.tempMin() && t <= this.tempMax();
  }

  /** 更新目标温度显示值 (同步滑块) */
  private updateTempInput(v: string): void {
    this.tempInput = v;
    const n: number = Number.parseFloat(v);
    if (!Number.isNaN(n)) {
      this.sliderVal = n;
    }
  }

  /** 快捷档位 (对齐 18-34℃ 范围) */
  private presets(): number[] {
    return this.unitText === '℉' ? [68, 75, 82, 90, 93] : [20, 24, 28, 32, 34];
  }

  /** 快捷档位直接设置并写入 */
  async setPresetTemp(t: number): Promise<void> {
    if (!this.connected) {
      return;
    }
    this.updateTempInput(t.toFixed(1));
    await this.setTemp();
  }

  async setTemp(): Promise<void> {
    if (!this.connected) {
      return;
    }
    const v = Number.parseFloat(this.tempInput);
    if (Number.isNaN(v)) {
      promptAction.showToast({ message: '请输入有效温度' });
      return;
    }
    // 范围钳制: 防止回显污染/溢出截断导致的温度爆炸 (安卓 SeekBar 范围)
    const minT: number = this.tempMin();
    const maxT: number = this.tempMax();
    if (v < minT || v > maxT) {
      promptAction.showToast({ message: '目标范围 ' + minT + '~' + maxT + this.unitText });
      return;
    }
    try {
      // 无偏移协议: 编码 = 温度×10, 设备 LCD 直接显示该温度 (2026-10-30 修正, 解决差 64)
      const cmd: Uint8Array = makeTempCmd(v, this.unitText === '℉');
      await BleService.write(cmd);
      // 记录设备侧目标值并同步显示 (不等回显, 回显会再覆盖一次, 值一致)
      this.rawTarget = v;
      this.targetTemp = v.toFixed(1);
      this.updateTempInput(v.toFixed(1));
      this.appendLog('设温度 -> ' + bytesToHex(cmd) + ' (' + v + this.unitText +
        ', 编码 ' + Math.round(v * 10) + ', 原始 ' + this.rawTarget.toFixed(1) + ')');
    } catch (e) {
      this.appendLog('设置失败: ' + JSON.stringify(e));
    }
  }

  /** 步进调节: 摄氏度 ±0.5, 华氏度 ±1 (用户要求); 然后按无偏移公式写入 */
  async stepTemp(delta: number): Promise<void> {
    if (!this.connected) {
      return;
    }
    let v = Number.parseFloat(this.tempInput);
    if (Number.isNaN(v)) {
      v = 0;
    }
    v = Math.round((v + delta) * 10) / 10;
    const minT: number = this.tempMin();
    const maxT: number = this.tempMax();
    if (v < minT || v > maxT) {
      promptAction.showToast({ message: '目标范围 ' + minT + '~' + maxT + this.unitText });
      return;
    }
    this.updateTempInput(v.toFixed(1));
    await this.setTemp();
  }

  async switchUnit(): Promise<void> {
    if (!this.connected) {
      return;
    }
    try {
      await BleService.write(makeUnitCmd());
      // 本地立即切换显示单位, 目标温度按物理换算四舍五入 (对齐设备固件: ℃ 取 0.5, ℉ 取整)
      const cur: number = Number.parseFloat(this.tempInput);
      const nowF: boolean = this.unitText !== '℉';
      this.unitText = nowF ? '℉' : '℃';
      if (!Number.isNaN(cur) && cur > 0) {
        let next: number;
        if (nowF) {
          // ℃ -> ℉: 四舍五入到整数 (℉ 步进 1)
          next = Math.round(cur * 1.8 + 32);
        } else {
          // ℉ -> ℃: 四舍五入到 0.5 (℃ 步进 0.5)
          next = Math.round((cur - 32) / 1.8 * 2) / 2;
        }
        // 范围钳制, 防止换算后越界
        const lo: number = this.tempMin();
        const hi: number = this.tempMax();
        if (next < lo) {
          next = lo;
        } else if (next > hi) {
          next = hi;
        }
        this.updateTempInput(next.toFixed(1));
        this.targetTemp = next.toFixed(1);
        this.appendLog('目标按当前温度换算: ' + cur.toFixed(1) +
          (nowF ? '℃' : '℉') + ' -> ' + next.toFixed(1) + this.unitText);
      }
      // 标记切单位过渡: 设备 31 02 后目标被重置, 待设备确认单位后重写目标; 3 秒内忽略设备默认回显
      this.unitSwitchPending = true;
      this.unitSwitchIgnoreUntil = Date.now() + 3000;
      this.appendLog('切换单位 -> ' + this.unitText + ' (31 02), 目标 ' +
        (this.tempInput.length > 0 ? this.tempInput + this.unitText : '(待确认)') +
        ', 设备档位=' + (this.deviceUnit === 'F' ? '℉' : (this.deviceUnit === 'C' ? '℃' : '未知')));
    } catch (e) {
      this.appendLog('切换失败: ' + JSON.stringify(e));
    }
  }

  /** 切单位过渡完成: 用当前显示目标重写设备 (设备 31 02 后目标被重置为默认 28℃/83℉) */
  private async writeTargetAfterUnitSwitch(): Promise<void> {
    if (!this.unitSwitchPending) {
      return;
    }
    this.unitSwitchPending = false; // 先清标记, 防止 3001 连续推送重复触发
    const v: number = Number.parseFloat(this.tempInput);
    if (Number.isNaN(v) || !this.connected) {
      return;
    }
    try {
      await this.setTemp();
      this.appendLog('切单位后目标已重写: ' + this.tempInput + this.unitText);
    } catch (e) {
      this.appendLog('切单位重写目标失败: ' + JSON.stringify(e));
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
      // 安卓: mHour = 当前小时+1, 曲线从该时点回看 24 小时 (3 段 x 8 点)
      const now: Date = new Date();
      this.hourBase = now.getHours() + 1;
      this.histSamples = [];
      this.histLabels = [];
      this.histKind = 'hour';
      this.drawHist();
      await BleService.write(makeHourHistoryCmd());
      this.appendLog('请求小时历史 (31 04), 等待 3 段(24小时)数据...');
    } catch (e) {
      this.appendLog('请求失败: ' + JSON.stringify(e));
    }
  }

  async minuteHistory(): Promise<void> {
    if (!this.connected) {
      return;
    }
    try {
      this.histSamples = [];
      this.histLabels = [];
      this.histKind = 'minute';
      this.drawHist();
      await BleService.write(makeMinuteHistoryCmd());
      this.appendLog('请求分钟历史 (31 03), 等待 8 段(60分钟)数据...');
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
    this.connAddr = '';
    this.connName = '';
    this.stateText = '已断开';
    this.stateColor = '#999999';
    this.currentTemp = '--';
    this.targetTemp = '--';
    this.histSamples = [];
    this.historyStats = '';
    this.drawHist();
    this.appendLog('已断开连接。');
  }

  // ---------- UI ----------
  build() {
    Column({ space: 10 }) {
      // ===== 顶栏: 连接状态 + 设备名 + 单位切换 =====
      Row() {
        Text(this.connected ? '● 已连接' : '● 未连接')
          .fontSize(13)
          .fontColor(this.connected ? '#22A06B' : '#E5484D')
        Blank()
        Column({ space: 0 }) {
          Text('诗彦加热棒')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1D1D1F')
          Text('SHISON HEATER')
            .fontSize(10)
            .fontColor('#8A8F98')
        }
        Blank()
        Button('℃⇄')
          .fontSize(13)
          .backgroundColor('#FFFFFF')
          .fontColor('#3A86FF')
          .borderRadius(18)
          .shadow({ radius: 10, color: '#333A86FF', offsetY: 3 })
          .onClick(() => {
            this.switchUnit();
          })
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 4 })

      // ===== 中部: 温度刻度标尺 + 当前温度 + 当前模式 (光感卡片) =====
      Row({ space: 8 }) {
        // 左刻度
        Column({ space: 6 }) {
          ForEach([36, 30, 26, 22, 18], (t: number) => {
            Text(t + '℃').fontSize(12).fontColor('#8A8F98')
          }, (t: number) => 'L' + t.toString())
        }
        // 中间: 当前温度大字 + 模式
        Column({ space: 2 }) {
          Text('当前温度').fontSize(13).fontColor('#8A8F98')
          Row({ space: 2 }) {
            Text(this.currentTemp)
              .fontSize(46)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1D1D1F')
            Text(this.unitText)
              .fontSize(16)
              .fontColor('#3A86FF')
              .margin({ top: 18 })
          }
          .justifyContent(FlexAlign.Center)
          Text('当前模式').fontSize(13).fontColor('#8A8F98').margin({ top: 10 })
          Text(this.stateText)
            .fontSize(16)
            .fontColor(this.stateColor)
            .fontWeight(FontWeight.Medium)
        }
        .layoutWeight(1)
        // 右刻度
        Column({ space: 6 }) {
          ForEach([34, 32, 28, 24, 20], (t: number) => {
            Text(t + '℃').fontSize(12).fontColor('#8A8F98')
          }, (t: number) => 'R' + t.toString())
        }
      }
      .width('100%')
      .padding({ top: 12, bottom: 12, left: 8, right: 8 })
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .shadow({ radius: 16, color: '#263A86FF', offsetY: 4 })

      // ===== 目标温度: 显示 + 滑块 + 步进 + 快捷档位 =====
      Column({ space: 8 }) {
        Row() {
          Text('设置目标温度').fontSize(13).fontColor('#8A8F98')
          Blank()
          Text(this.tempInput + this.unitText)
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor('#3A86FF')
        }
        .width('100%')

        Row({ space: 10 }) {
          Button('-')
            .enabled(this.connected)
            .width(40)
            .height(40)
            .backgroundColor('#F5F7FA')
            .fontColor('#1D1D1F')
            .borderRadius(20)
            .shadow({ radius: 8, color: '#263A86FF', offsetY: 3 })
            .onClick(() => {
              this.stepTemp(this.unitText === '℉' ? -1 : -0.5);
            })
          Slider({
            value: this.sliderVal,
            min: this.tempMin(),
            max: this.tempMax(),
            step: this.unitText === '℉' ? 1 : 0.5,
            style: SliderStyle.OutSet
          })
            .layoutWeight(1)
            .selectedColor('#3A86FF')
            .trackColor('#E4E9F0')
            .blockColor('#3A86FF')
            .onChange((v: number, mode: SliderChangeMode) => {
              this.tempInput = v.toFixed(1);
              this.sliderVal = v;
              if (mode === SliderChangeMode.End) {
                this.setTemp();
              }
            })
          Button('+')
            .enabled(this.connected)
            .width(40)
            .height(40)
            .backgroundColor('#F5F7FA')
            .fontColor('#1D1D1F')
            .borderRadius(20)
            .shadow({ radius: 8, color: '#263A86FF', offsetY: 3 })
            .onClick(() => {
              this.stepTemp(this.unitText === '℉' ? 1 : 0.5);
            })
        }
        .width('100%')

        // 快捷档位
        Row({ space: 6 }) {
          ForEach(this.presets(), (t: number) => {
            Button(t.toFixed(0) + (this.unitText === '℉' ? '℉' : '℃'))
              .enabled(this.connected)
              .fontSize(12)
              .backgroundColor('#E8F0FE')
              .fontColor('#3A86FF')
              .shadow({ radius: 6, color: '#263A86FF', offsetY: 2 })
              .onClick(() => {
                this.setPresetTemp(t);
              })
          }, (t: number) => t.toFixed(0))
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .shadow({ radius: 16, color: '#263A86FF', offsetY: 4 })

      // ===== 功能按钮: 刷新 / 小时历史 / 分钟历史 / 断开 =====
      Row({ space: 8 }) {
        Button('刷新')
          .enabled(this.connected)
          .layoutWeight(1)
          .backgroundColor('#F5F7FA')
          .fontColor('#1D1D1F')
          .shadow({ radius: 8, color: '#263A86FF', offsetY: 3 })
          .onClick(() => {
            this.refreshStatus();
          })
        Button('小时历史')
          .enabled(this.connected)
          .layoutWeight(1)
          .backgroundColor('#E8F0FE')
          .fontColor('#3A86FF')
          .shadow({ radius: 8, color: '#263A86FF', offsetY: 3 })
          .onClick(() => {
            this.hourHistory();
          })
        Button('分钟历史')
          .enabled(this.connected)
          .layoutWeight(1)
          .backgroundColor('#E8F0FE')
          .fontColor('#3A86FF')
          .shadow({ radius: 8, color: '#263A86FF', offsetY: 3 })
          .onClick(() => {
            this.minuteHistory();
          })
      }
      .width('100%')

      // ===== 历史温度曲线 (曲线 + 统计合并一张卡) =====
      Column({ space: 4 }) {
        Row() {
          Text(this.histKind === 'hour' ? '24小时温度曲线' : '60分钟温度曲线')
            .fontSize(12)
            .fontColor('#8A8F98')
          Blank()
          Text(this.histSamples.length + ' 点  ' + this.unitText)
            .fontSize(11)
            .fontColor('#A0A4AB')
        }
        .width('100%')
        Canvas(this.histCtx)
          .width('100%')
          .height(110)
          .onReady(() => {
            this.drawHist();
          })
        // 历史统计
        Row() {
          Text(this.historyStats === '' ? '历史: 点上方按钮请求' : '历史 ' + this.historyStats)
            .fontSize(12)
            .fontColor('#8A8F98')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
      }
      .width('100%')
      .padding(10)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
      .shadow({ radius: 12, color: '#263A86FF', offsetY: 3 })

      // ===== 扫描设备 (主操作) + 断开 =====
      Row({ space: 8 }) {
        Button(this.scanning ? '扫描中...' : '扫描设备')
          .enabled(!this.scanning)
          .layoutWeight(1)
          .backgroundColor('#3A86FF')
          .shadow({ radius: 16, color: '#553A86FF', offsetY: 4 })
          .onClick(() => {
            this.startScan();
          })
        Button('断开')
          .enabled(this.connected)
          .backgroundColor('#F5F7FA')
          .fontColor(this.connected ? '#E5484D' : '#C0C4CC')
          .shadow({ radius: 8, color: '#263A86FF', offsetY: 3 })
          .onClick(() => {
            this.disconnect();
          })
      }
      .width('100%')

      // ===== 状态行 =====
      Row() {
        Text(this.connected
          ? ('已连接: ' + (this.connName === '' ? this.connAddr : this.connName))
          : '未连接, 点击"扫描设备"搜索加热器')
          .fontSize(12)
          .fontColor('#A0A4AB')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 4, right: 4 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, bottom: 12 })
    .backgroundColor('#F5F7FA')
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [['#FFFFFF', 0.0], ['#F0F5FB', 1.0]]
    })
  }
}
