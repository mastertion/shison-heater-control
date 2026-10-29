// 逐行复刻 sicn_ohos Protocol.ets 核心逻辑 (与 ArkTS 源码一一对应)
// 用例与 Python 版 9 项一致

function makeSyncCmd() { return Uint8Array.from([0x01, 0x03]); }
function makeTempCmd(temp) {
  const value = Math.round(temp * 10);
  return Uint8Array.from([0x31, 0x01, value & 0xFF, (value >> 8) & 0xFF]);
}
function makeUnitCmd() { return Uint8Array.from([0x31, 0x02]); }
function makeHourHistoryCmd() { return Uint8Array.from([0x31, 0x04]); }
function makeMinuteHistoryCmd() { return Uint8Array.from([0x31, 0x03]); }

function modeText(mode) {
  switch (mode) {
    case 0: return '探头故障';
    case 1: return '离水断电';
    case 2: return '超温保护';
    case 3: return '加热中';
    case 4: return '保温';
    case 5: return '待机';
    default: return '未知(' + mode + ')';
  }
}

function parseNotify(buf) {
  if (buf.length < 2) return null;
  if (buf[0] === 0x30 && buf[1] === 0x01 && buf.length >= 7) {
    const mode = buf[2];
    const unit = buf[3];
    const tLo = buf[4];
    const tHi = buf[6];
    const temp = (tHi * 256 + tLo) / 10;
    return { kind: 'status', temp: temp, mode: mode, unit: unit === 1 ? 'C' : 'F',
      stateText: modeText(mode) };
  }
  if (buf[0] === 0x31 && buf[1] === 0x01 && buf.length >= 4) {
    const lo = buf[2];
    const hi = buf[3];
    return { kind: 'target', target: (hi * 256 + lo) / 10 };
  }
  if (buf[0] === 0x30 && (buf[1] === 0x03 || buf[1] === 0x02) && buf.length >= 4) {
    const segment = buf[2];
    const samples = [];
    let idx = 3;
    while (idx + 1 < buf.length) {
      const raw = (buf[idx] << 8) | buf[idx + 1];
      samples.push((raw & 0x0FFF) / 10);
      idx += 2;
    }
    return { kind: 'history', segment: segment, history: samples };
  }
  return null;
}

function bytesToHex(buf) {
  let s = '';
  for (let i = 0; i < buf.length; i++) {
    s += ('0' + buf[i].toString(16)).slice(-2).toUpperCase() + ' ';
  }
  return s.trim();
}

const assert = require('assert');

// 1. 温度指令
assert.strictEqual(Buffer.from(makeTempCmd(26)).toString('hex'), '31010401');
assert.strictEqual(Buffer.from(makeTempCmd(78)).toString('hex'), '31010c03');
assert.strictEqual(Buffer.from(makeTempCmd(25.5)).toString('hex'), '3101ff00');
assert.strictEqual(Buffer.from(makeSyncCmd()).toString('hex'), '0103');
assert.strictEqual(Buffer.from(makeUnitCmd()).toString('hex'), '3102');
assert.strictEqual(Buffer.from(makeHourHistoryCmd()).toString('hex'), '3104');
assert.strictEqual(Buffer.from(makeMinuteHistoryCmd()).toString('hex'), '3103');

// 2. 状态 3001: mode=3 加热中, unit=1 C, t=(0*256+0xFA)/10=25.0
let s = parseNotify(Uint8Array.from([0x30, 0x01, 0x03, 0x01, 0xfa, 0x00, 0x00, 0x00]));
assert.strictEqual(s.kind, 'status');
assert.strictEqual(s.temp, 25.0);
assert.strictEqual(s.mode, 3);
assert.strictEqual(s.unit, 'C');
assert.strictEqual(s.stateText, '加热中');

// 3. 状态 F: unit=0, T_LO=0x14, T_HI=0x01 -> (0x0114)/10=27.6
s = parseNotify(Uint8Array.from([0x30, 0x01, 0x05, 0x00, 0x14, 0x01, 0x01, 0x00]));
assert.strictEqual(s.temp, 27.6);
assert.strictEqual(s.unit, 'F');
assert.strictEqual(s.stateText, '待机');

// 4. 目标回显 3101 04 01 -> 26.0
s = parseNotify(Uint8Array.from([0x31, 0x01, 0x04, 0x01]));
assert.strictEqual(s.kind, 'target');
assert.strictEqual(s.target, 26.0);

// 5. 小时历史 (大端, 低12位): 30 03 01 + [0001->0.1, 00ff->25.5, 0002->0.2, 1003->0.3, 2004->0.4]
s = parseNotify(Uint8Array.from([0x30, 0x03, 0x01, 0x00, 0x01, 0x00, 0xff, 0x00, 0x02, 0x10, 0x03, 0x20, 0x04]));
assert.strictEqual(s.kind, 'history');
assert.strictEqual(s.segment, 1);
assert.deepStrictEqual(s.history, [0.1, 25.5, 0.2, 0.3, 0.4]);

// 6. 分钟历史
s = parseNotify(Uint8Array.from([0x30, 0x02, 0x01, 0x00, 0xff]));
assert.strictEqual(s.kind, 'history');
assert.deepStrictEqual(s.history, [25.5]);

// 7. 非匹配包
assert.strictEqual(parseNotify(Uint8Array.from([0x01, 0x03])), null);
assert.strictEqual(parseNotify(Uint8Array.from([0x31, 0x01, 0x04, 0x01])).kind, 'target'); // 不误判 status

// 8. bytesToHex
assert.strictEqual(bytesToHex(Uint8Array.from([0x31, 0x01, 0x04, 0x01])), '31 01 04 01');

console.log('ALL PASS (15 checks)');
