#!/usr/bin/env python3
"""FDS sound: reference model (NESdev wiki: FDS audio) for cores/nrom/fds_snd.v,
plus the stimulus/compare harness for cores/tb/tb_fds_snd.v.

  python fds_audio.py gen  STIM.hex      write the test program (one bus cycle
                                          per line: rw addr data, hex)
  python fds_audio.py check STIM.hex OUT.txt
                                          run the model on the same cycles and
                                          compare with the testbench's output
                                          (per cycle: pre-filter level, filtered
                                          level, read data)

One call of cycle() = one CPU cycle; all new values are computed from the
state at the start of the cycle (the core updates on falling M2), register
writes override what the tick computed in the same cycle.
"""
import sys


def wave_pitch(freq, mcnt, mgain):
    """the wiki's pseudocode, as written (C int semantics = Python ints)"""
    counter = mcnt - 128 if mcnt & 0x40 else mcnt
    temp = counter * mgain
    if (temp & 0x0F) and not (temp & 0x800):
        temp += 0x20
    temp += 0x400
    temp = (temp >> 4) & 0xFF
    return (freq * temp) & 0xFFFFF


DELTA = {0: 0, 1: 1, 2: 2, 3: 4, 5: -4, 6: -2, 7: -1}
MMUL = (32, 21, 16, 13)          # master volume 1, 2/3, 2/4, 2/5 (x/32)


class FDSAudio:
    def __init__(self):
        self.wram = [0] * 64
        self.mtab = [0] * 32
        self.s_en = 0
        self.vol_dis = self.vol_dir = self.vol_spd = self.vol_gain = self.vol_cnt = 0
        self.mod_dis = self.mod_dir = self.mod_spd = self.mod_gain = self.mod_cnt6 = 0
        self.freq = self.mfreq = 0
        self.wave_halt = self.env_halt = self.mod_halt = self.mod_force = 0
        self.wave_wr = 0
        self.mvol = 0
        self.env_m = 0
        self.ep = 0
        self.wacc = 0
        self.macc = 0
        self.mcnt = 0
        self.out_gain = 0
        self.div = 0
        self.lvl = 0
        self.y = 0

    def read(self, addr):
        """data the core drives for a read of addr, None if it does not answer"""
        if 0x4040 <= addr <= 0x407F:
            v = self.wram[addr & 0x3F] if self.wave_wr else self.wram[self.wacc >> 18]
            return 0x40 | v
        r = addr - 0x4080
        if 0x10 <= r <= 0x17:
            return {0x10: 0x40 | self.vol_gain, 0x11: (self.wacc >> 12) & 0xFF,
                    0x12: 0x40 | self.mod_gain, 0x13: (self.macc >> 5) & 0x7F,
                    0x17: self.mcnt}.get(r, 0x40)
        return None

    def cycle(self, rw, addr, data):
        o = dict(self.__dict__)              # the state at the start of the cycle
        o_wram = list(self.wram)
        o_mtab = list(self.mtab)
        self.div = (o["div"] + 1) & 15

        # envelopes
        m = o["env_m"]
        if m == 0:
            self.ep = 0
        elif o["ep"] == 0:
            self.ep = m * 8 + 7
        else:
            self.ep = o["ep"] - 1
        env_tick = m != 0 and o["ep"] == 0
        if env_tick and not o["vol_dis"] and not o["env_halt"]:
            if o["vol_cnt"] == o["vol_spd"]:
                self.vol_cnt = 0
                if o["vol_dir"] and o["vol_gain"] < 32:
                    self.vol_gain = o["vol_gain"] + 1
                elif not o["vol_dir"] and o["vol_gain"]:
                    self.vol_gain = o["vol_gain"] - 1
            else:
                self.vol_cnt = (o["vol_cnt"] + 1) & 63
        if env_tick and not o["mod_dis"] and not o["env_halt"]:
            if o["mod_cnt6"] == o["mod_spd"]:
                self.mod_cnt6 = 0
                if o["mod_dir"] and o["mod_gain"] < 32:
                    self.mod_gain = o["mod_gain"] + 1
                elif not o["mod_dir"] and o["mod_gain"]:
                    self.mod_gain = o["mod_gain"] - 1
            else:
                self.mod_cnt6 = (o["mod_cnt6"] + 1) & 63

        # wave, mod, output every 16 cycles
        if o["div"] == 15:
            waddr = o["wacc"] >> 18
            g = min(o["out_gain"], 32)
            mixed = o_wram[waddr] * g * MMUL[o["mvol"]]
            if o["wave_halt"]:
                self.wacc = 0
            else:
                self.wacc = (o["wacc"] + wave_pitch(o["freq"], o["mcnt"], o["mod_gain"])) & 0xFFFFFF
            if waddr == 0:
                self.out_gain = o["vol_gain"]
            if not o["wave_wr"]:
                self.lvl = (mixed >> 5) & 0x7FF
            self.y = (o["y"] + ((o["lvl"] * 32 - o["y"]) >> 3)) & 0xFFFF
            if not o["mod_halt"] and (o["mfreq"] or o["mod_force"]):
                msum = (o["macc"] & 0xFFF) + o["mfreq"]
                carry = (msum >> 12) or o["mod_force"]
                hi = o["macc"] >> 12
                if carry:
                    hi = (hi + 1) & 0x3F
                    ent = o_mtab[(o["macc"] >> 13) & 31]
                    self.mcnt = 0 if ent == 4 else (o["mcnt"] + DELTA[ent]) & 0x7F
                self.macc = (hi << 12) | (msum & 0xFFF)

        # register writes
        if rw == 0:
            d = data
            if addr == 0x4023:
                self.s_en = (d >> 1) & 1
                if not d & 2:
                    self.vol_gain = 0
                    self.out_gain = 0
                    self.wacc = 0
                    self.mcnt = 0
            if 0x4040 <= addr <= 0x407F and o["wave_wr"]:
                self.wram[addr & 0x3F] = d & 0x3F
            r = addr - 0x4080
            if r == 0:
                self.vol_dis, self.vol_dir, self.vol_spd, self.vol_cnt = d >> 7, (d >> 6) & 1, d & 63, 0
                if d & 0x80:
                    self.vol_gain = d & 63
                    if d & 63 == 0:
                        self.out_gain = 0
            elif r == 2:
                self.freq = (o["freq"] & 0xF00) | d
            elif r == 3:
                self.freq = (o["freq"] & 0xFF) | ((d & 15) << 8)
                self.env_halt, self.wave_halt = (d >> 6) & 1, d >> 7
                if d & 0x80:
                    self.wacc = 0
                if d & 0x40:
                    self.vol_cnt = 0
                    self.mod_cnt6 = 0
            elif r == 4:
                self.mod_dis, self.mod_dir, self.mod_spd, self.mod_cnt6 = d >> 7, (d >> 6) & 1, d & 63, 0
                if d & 0x80:
                    self.mod_gain = d & 63
            elif r == 5:
                self.mcnt = d & 0x7F
            elif r == 6:
                self.mfreq = (o["mfreq"] & 0xF00) | d
            elif r == 7:
                self.mfreq = (o["mfreq"] & 0xFF) | ((d & 15) << 8)
                self.mod_force, self.mod_halt = (d >> 6) & 1, d >> 7
                if d & 0x80:
                    self.macc = self.macc & ~0x1FFF & 0x3FFFF
            elif r == 8:
                if o["mod_halt"]:
                    a = (o["macc"] >> 13) & 31
                    self.mtab[a] = d & 7
                    self.macc = (self.macc & 0x1FFF) | (((a + 1) & 31) << 13)
            elif r == 9:
                self.wave_wr, self.mvol = d >> 7, d & 3
            elif r == 0x0A:
                self.env_m = d

    def level(self):
        return self.y >> 5


def program():
    """bus cycles (rw, addr, data): writes, reads and idle stretches"""
    out = []

    def w(a, d):
        out.append((0, a, d))
        out.append((1, 0, 0))

    def rd(a):
        out.append((1, a, 0))

    def idle(n):
        out.extend([(1, 0, 0)] * n)

    w(0x4023, 0x83)
    w(0x4089, 0x80)                              # wave RAM writable
    for i in range(64):                          # a lopsided triangle-ish wave
        w(0x4040 + i, (i * 3) & 63 if i < 21 else (63 - i) & 63)
    for i in range(0, 64, 9):
        rd(0x4040 + i)                           # write-enabled: stored samples
    w(0x4089, 0x00)
    w(0x408A, 0xE8)
    w(0x4080, 0x80 | 32)                         # gain 32 directly
    w(0x4082, 0x40)
    w(0x4083, 0x03)                              # pitch $340
    w(0x4087, 0x80)                              # mod halted: table writable
    for i in range(32):
        w(0x4088, (0, 1, 2, 3, 4, 5, 6, 7, 7, 6, 5, 3, 2, 1, 1, 0)[i % 16])
    w(0x4084, 0x80 | 20)
    w(0x4085, 0x00)
    w(0x4086, 0x50)
    w(0x4087, 0x00)                              # mod pitch $050, running
    idle(30000)
    for a in (0x4090, 0x4091, 0x4092, 0x4093, 0x4097, 0x4050, 0x4040):
        rd(a)                                    # write disabled: current sample
    for i in range(0, 64, 5):
        w(0x4040 + i, 0x3F)                      # write disabled: ignored
    idle(4000)
    w(0x4085, 0x3C)                              # counter near the top (wraps)
    w(0x4084, 0x80 | 63)                         # large mod gain: big products
    idle(20000)
    w(0x4085, 0x41)                              # negative counter
    idle(20000)
    w(0x4080, 0x05)                              # volume envelope, down, speed 5
    idle(40000)
    w(0x4080, 0x45)                              # up
    w(0x4084, 0x02)                              # mod envelope down, speed 2
    idle(40000)
    w(0x4089, 0x01)                              # master 2/3
    idle(8000)
    w(0x4089, 0x02)
    idle(8000)
    w(0x4089, 0x03)
    idle(8000)
    w(0x4083, 0x83)                              # wave halt
    idle(3000)
    w(0x4083, 0x43)                              # running again, envelopes halted
    idle(8000)
    w(0x4087, 0x40)                              # force carry
    idle(8000)
    w(0x4089, 0x80)                              # output held while writable
    idle(3000)
    w(0x4089, 0x00)
    w(0x4080, 0x80)                              # mute at once
    idle(2000)
    w(0x4080, 0x80 | 40)                         # above 32: capped
    idle(6000)
    w(0x4023, 0x81)                              # sound off: reset
    idle(2000)
    w(0x4023, 0x83)
    w(0x4080, 0x80 | 16)
    idle(10000)
    return out


def main():
    if sys.argv[1] == "gen":
        with open(sys.argv[2], "w") as f:
            for rw, a, d in program():
                f.write("%d%04X%02X\n" % (rw, a, d))
        print("%d cycles" % len(program()))
        return
    stim = [l.strip() for l in open(sys.argv[2]) if l.strip()]
    got = [l.split() for l in open(sys.argv[3]) if l.strip()]
    model = FDSAudio()
    bad = 0
    nonzero = 0
    for n, line in enumerate(stim):
        rw, a, d = int(line[0]), int(line[1:5], 16), int(line[5:7], 16)
        r = model.read(a) if rw else None
        model.cycle(rw, a, d)
        want = (model.lvl, model.level(), r if r is not None else 0)
        have = tuple(int(x, 16) for x in got[n])
        nonzero += want[0] != 0
        if have != want:
            bad += 1
            if bad <= 10:
                print("cycle %d (%s): core lvl %d level %d rd %02X, model lvl %d level %d rd %02X" % (
                    n, line, have[0], have[1], have[2], want[0], want[1], want[2]))
    print("compared %d cycles (%d with sound), mismatches: %d" % (len(stim), nonzero, bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
