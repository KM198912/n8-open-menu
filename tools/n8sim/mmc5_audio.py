#!/usr/bin/env python3
"""MMC5 sound: reference model (NESdev wiki: MMC5 audio, APU Pulse) for
cores/nrom/mmc5_snd.v, plus the stimulus/compare harness for
cores/tb/tb_mmc5_snd.v.

  python mmc5_audio.py gen  STIM.hex      write the test program (one bus cycle
                                           per line: rw addr data, hex)
  python mmc5_audio.py check STIM.hex OUT.txt
                                           run the model on the same cycles and
                                           compare with the testbench's output
                                           (per cycle: level, read data, IRQ)

One call of cycle() = one CPU cycle; new values are computed from the state
at the start of the cycle (the core updates on falling M2), register writes
override what the cycle computed. Addresses are CPU addresses ($8000-$FFFF
= /ROMSEL low).
"""
import sys

FRAME = 7423
LEN = (10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14,
       12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30)


def duty_bit(d, s):
    if d == 0:
        return s == 1
    if d == 1:
        return s in (1, 2)
    if d == 2:
        return 1 <= s <= 4
    return s not in (1, 2)


class Pulse:
    def __init__(self):
        self.duty = self.halt = self.cvol = self.vol = 0
        self.period = self.tmr = self.seq = self.len = 0
        self.estart = self.ediv = self.decay = 0

    def out(self):
        if self.len and duty_bit(self.duty, self.seq):
            return self.vol if self.cvol else self.decay
        return 0


class MMC5Audio:
    def __init__(self):
        self.p = [Pulse(), Pulse()]
        self.en = 0
        self.apu = 0
        self.fdiv = 0
        self.pcm_mode = self.pcm_ien = self.pcm_flag = 0
        self.dac = 0

    def read(self, addr):
        """data the core drives for a read of addr, None if it does not answer"""
        if addr == 0x5010:
            return self.pcm_flag << 7
        if addr == 0x5015:
            return (1 if self.p[1].len else 0) << 1 | (1 if self.p[0].len else 0)
        return None

    def level(self):
        return self.p[0].out() * 32 + self.p[1].out() * 32 + self.dac * 4

    def irq(self):
        return self.pcm_flag & self.pcm_ien

    def cycle(self, rw, addr, data):
        import copy
        o = copy.deepcopy(self.p)                # pulse state at the start of the cycle
        frame = self.fdiv == FRAME
        apu = self.apu
        self.apu ^= 1
        self.fdiv = 0 if frame else self.fdiv + 1
        for k in range(2):
            n, q = self.p[k], o[k]
            if apu:
                if q.tmr == 0:
                    n.tmr = q.period
                    n.seq = (q.seq - 1) & 7
                else:
                    n.tmr = q.tmr - 1
            if frame:
                if q.estart:
                    n.estart = 0
                    n.decay = 15
                    n.ediv = q.vol
                elif q.ediv == 0:
                    n.ediv = q.vol
                    if q.decay:
                        n.decay = q.decay - 1
                    elif q.halt:
                        n.decay = 15
                else:
                    n.ediv = q.ediv - 1
                if not q.halt and q.len:
                    n.len = q.len - 1

        if rw and 0x8000 <= addr <= 0xBFFF and self.pcm_mode:
            if data == 0:
                self.pcm_flag = 1
            else:
                self.dac = data
        if rw and addr == 0x5010:
            self.pcm_flag = 0

        if not rw and 0x5000 <= addr <= 0x501F:
            r = addr & 0x1F
            if r < 8:
                n = self.p[r >> 2]
                if r & 3 == 0:
                    n.duty, n.halt, n.cvol, n.vol = data >> 6, (data >> 5) & 1, (data >> 4) & 1, data & 15
                elif r & 3 == 2:
                    n.period = (n.period & 0x700) | data
                elif r & 3 == 3:
                    n.period = (n.period & 0xFF) | ((data & 7) << 8)
                    if self.en >> (r >> 2) & 1:
                        n.len = LEN[data >> 3]
                    n.seq = 0
                    n.estart = 1
            if r == 0x10:
                self.pcm_ien, self.pcm_mode = data >> 7, data & 1
            if r == 0x11 and not self.pcm_mode:
                if data == 0:
                    self.pcm_flag = 1
                else:
                    self.dac = data
            if r == 0x15:
                self.en = data & 3
                if not data & 1:
                    self.p[0].len = 0
                if not data & 2:
                    self.p[1].len = 0


def program():
    """bus cycles (rw, addr, data): writes, reads and idle stretches"""
    out = []

    def w(a, d):
        out.append((0, a, d))
        out.append((1, 0, 0))

    def rd(a, d=0):
        out.append((1, a, d))

    def idle(n):
        out.extend([(1, 0, 0)] * n)

    w(0x5003, 0x08)                              # disabled: no length load
    rd(0x5015)
    w(0x5015, 0x03)
    w(0x5000, 0xBF)                              # duty 2, halt, constant volume 15
    w(0x5002, 0x40)
    w(0x5003, 0x01)                              # period $140, length index 0
    w(0x5004, 0x48)                              # duty 1, envelope, period 8
    w(0x5006, 0x05)                              # period 5 (< 8: not muted)
    w(0x5007, 0x18)                              # length index 3 = 2
    for _ in range(6):
        rd(0x5015)
        idle(3000)
    w(0x5001, 0xFF)                              # sweep register: nothing
    idle(3000)
    w(0x5004, 0x60)                              # duty 1, loop, envelope period 0
    w(0x5007, 0xF8)                              # length index $1F
    idle(150000)                                 # 15 steps down, then it loops
    w(0x5000, 0x0F)                              # duty 0, no halt: length counts
    w(0x5003, 0x10)                              # length index 2 = 20
    for _ in range(8):
        rd(0x5015)
        idle(20000)
    w(0x5000, 0xD5)                              # duty 3, constant volume 5
    w(0x5003, 0xF9)
    idle(4000)
    w(0x5015, 0x02)                              # pulse 1 off: length cleared
    rd(0x5015)
    idle(2000)
    w(0x5015, 0x03)
    w(0x5003, 0xF9)
    w(0x5002, 0x00)                              # period 0: ultrasonic, not muted
    w(0x5003, 0xF8)
    idle(2000)
    # PCM
    w(0x5011, 0x80)
    idle(200)
    w(0x5011, 0xFF)
    idle(200)
    w(0x5011, 0x00)                              # $00: flag, DAC kept
    rd(0x5010)                                   # flag set (IRQ disabled)
    rd(0x5010)                                   # cleared by the read
    w(0x5010, 0x80)                              # IRQ enable, write mode
    w(0x5011, 0x00)                              # IRQ
    idle(50)
    rd(0x5010)                                   # acknowledge
    w(0x5010, 0x81)                              # read mode
    w(0x5011, 0x22)                              # ignored in read mode
    rd(0x8123, 0x44)                             # $8000-$BFFF reads go to the DAC
    idle(20)
    rd(0xBFFF, 0x91)
    rd(0xC000, 0x13)                             # $C000: not
    idle(20)
    rd(0x9000, 0x00)                             # $00: IRQ
    idle(20)
    rd(0x5010)
    w(0x5010, 0x00)
    w(0x5011, 0x10)
    idle(30000)
    return out


def main():
    if sys.argv[1] == "gen":
        prog = program()
        with open(sys.argv[2], "w") as f:
            for rw, a, d in prog:
                f.write("%d%04X%02X\n" % (rw, a, d))
        print("%d cycles" % len(prog))
        return
    stim = [l.strip() for l in open(sys.argv[2]) if l.strip()]
    got = [l.split() for l in open(sys.argv[3]) if l.strip()]
    model = MMC5Audio()
    bad = 0
    nonzero = 0
    for n, line in enumerate(stim):
        rw, a, d = int(line[0]), int(line[1:5], 16), int(line[5:7], 16)
        r = model.read(a) if rw else None
        model.cycle(rw, a, d)
        want = (model.level(), r if r is not None else 0, model.irq())
        have = tuple(int(x, 16) for x in got[n])
        nonzero += want[0] != 0
        if have != want:
            bad += 1
            if bad <= 10:
                print("cycle %d (%s): core level %d rd %02X irq %d, model level %d rd %02X irq %d" % (
                    n, line, have[0], have[1], have[2], want[0], want[1], want[2]))
    print("compared %d cycles (%d with sound), mismatches: %d" % (len(stim), nonzero, bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
