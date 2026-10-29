# -*- coding: utf-8 -*-
"""Parse resources.arsc global string pool manually."""
import struct

with open(r'F:\开发\蓝牙设备\sicn_extract\resources.arsc', 'rb') as f:
    data = f.read()

# Resource table header: type(2) headerSize(2) size(4) packageCount(4) stringPoolStart(4)...
# 0x0002 = RES_TABLE_TYPE
res_table = struct.unpack_from('<HHIIIII', data, 0)
print('res_table type=%x hdrSize=%x size=%x pkgCount=%d' % (res_table[0], res_table[1], res_table[2], res_table[3]))

# The string pool is the first chunk right after the 12-byte table header
sp_start = 12
# String pool: type(2)=0x0001, headerSize(2), size(4), stringCount(4), styleCount(4),
# flags(4) (UTF8=256), stringsStart(4), stylesStart(4)
stype, shdr, ssize, scount, stycount, sflags, sstart, sty_start = struct.unpack_from('<HHIIIIII', data, sp_start)
print('stringpool: type=%x hdr=%x size=%x count=%d styles=%d flags=%x start=%d' % (stype, shdr, ssize, scount, stycount, sflags, sstart))

off = sp_start + sstart
strings = []
for i in range(scount):
    # offset table right after header
    str_off = struct.unpack_from('<I', data, sp_start + shdr + i*4)[0]
    abs_off = sp_start + sstart + str_off
    if sflags & 0x100:  # UTF-8: u8len (1-2), u16len (1-2), data
        pos = abs_off
        ln = data[pos]; pos += 1
        if ln & 0x80:
            ln = ((ln & 0x7F) << 8) | data[pos]; pos += 1
        ln16 = data[pos]; pos += 1
        if ln16 & 0x80:
            ln16 = ((ln16 & 0x7F) << 8) | data[pos]; pos += 1
        s = data[pos:pos+ln].decode('utf-8', errors='replace')
    else:  # UTF-16
        ln = struct.unpack_from('<H', data, abs_off)[0]
        pos = abs_off + 2
        raw = data[pos:pos+ln*2]
        s = raw.decode('utf-16-le', errors='replace')
    strings.append(s)

out = r'F:\开发\蓝牙设备\analysis\arsc_strings.txt'
with open(out, 'w', encoding='utf-8') as f:
    for i, s in enumerate(strings):
        f.write('%d\t%s\n' % (i, s))
print('dumped', len(strings))
