/**
 * 报警页 (对应安卓 AlarmActivity)
 *
 * 设备上报三类报警时进入此页 (MODE 数值越大故障越严重):
 *   3001 MODE 3 = 超温     -> 本页显示「超温保护」(安卓 AlarmActivity 专用文案)
 *   3001 MODE 4 = 离水断电
 *   3001 MODE 5 = 探头故障
 * 播放脉冲报警动画 + 震动, 用户点"我知道了"返回主界面(router.back)。
 *
 * 通过 router 参数传入: { mode:number, temp:number, unit:string }
 */
import { router } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';

const MODE_TEXT: Record<number, string> = {
  3: '超温保护',
  4: '离水断电',
  5: '探头故障'
};
const MODE_COLOR: Record<number, string> = {
  3: '#E5484D',
  4: '#FF9F0A',
  5: '#E5484D'
};
const MODE_TIP: Record<number, string> = {
  3: '水温超过安全阈值, 已触发超温保护, 请立即远离并断电检查。',
  4: '检测到离水, 已自动断电保护, 请将设备放回水中后恢复。',
  5: '水温探头异常, 请检查探头连接或更换探头后再使用。'
};

function asInt(v: Object | undefined, def: number): number {
  if (typeof v === 'number') {
    return v;
  }
  if (typeof v === 'string') {
    const n = Number.parseInt(v, 10);
    if (!Number.isNaN(n)) {
      return n;
    }
  }
  return def;
}

function asStr(v: Object | undefined, def: string): string {
  if (typeof v === 'string') {
    return v;
  }
  return def;
}

@Entry
@Component
struct AlarmPage {
  @State mode: number = 0;
  @State temp: number = 0;
  @State unit: string = '℃';
  @State big: boolean = false;
  private timer: number = 0;

  aboutToAppear(): void {
    const p = router.getParams() as Record<string, Object>;
    this.mode = asInt(p['mode'], 0);
    this.temp = asInt(p['temp'], 0);
    this.unit = asStr(p['unit'], '℃');
    this.startVibrate();
    // 脉冲动画: 每 600ms 在大小态间切换
    this.big = false;
    this.timer = setInterval(() => {
      this.big = !this.big;
    }, 600);
  }

  aboutToDisappear(): void {
    if (this.timer !== 0) {
      clearInterval(this.timer);
      this.timer = 0;
    }
  }

  /** 震动告警(对应安卓 Vibrator.vibrate) */
  private startVibrate(): void {
    try {
      const attr: vibrator.VibrateAttribute = {
        id: 0,
        usage: 'alarm'
      };
      vibrator.startVibration({
        type: 'time',
        duration: 1000
      }, attr).catch((e: Error) => {
        // 忽略: 部分设备/权限下震动不可用, 不影响报警展示
      });
    } catch (e) {
      // 忽略
    }
  }

  build() {
    Column({ space: 20 }) {
      Stack() {
        Circle()
          .width(this.big ? 150 : 120)
          .height(this.big ? 150 : 120)
          .fill(MODE_COLOR[this.mode] ?? '#E5484D')
          .opacity(0.22)
          .animation({ duration: 600, curve: Curve.EaseInOut })
        Circle()
          .width(92)
          .height(92)
          .fill(MODE_COLOR[this.mode] ?? '#E5484D')
        Text('!')
          .fontSize(46)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Bold)
      }
      .width(170)
      .height(170)
      .margin({ top: 50 })

      Text(MODE_TEXT[this.mode] ?? '报警')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(MODE_COLOR[this.mode] ?? '#E5484D')

      Text('当前温度: ' + this.temp.toFixed(1) + this.unit)
        .fontSize(16)
        .fontColor('#1D1D1F')

      Text(MODE_TIP[this.mode] ?? '')
        .fontSize(15)
        .fontColor('#5A5F66')
        .textAlign(TextAlign.Center)
        .width('82%')

      Button('我知道了')
        .width('60%')
        .height(48)
        .backgroundColor(MODE_COLOR[this.mode] ?? '#E5484D')
        .fontColor('#FFFFFF')
        .margin({ top: 12 })
        .onClick(() => {
          router.back();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .justifyContent(FlexAlign.Center)
  }
}
