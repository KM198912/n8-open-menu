"""6502 CPU core for the n8-open simulator (NES 2A03: no decimal mode).

Official opcodes only. Cycle counts are the base counts (page-cross and
branch penalties are ignored), which is enough for frame pacing.

The bus object needs read(addr) -> int and write(addr, value).
"""

C, Z, I, D, B, U, V, N = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80


class CPU:
    def __init__(self, bus):
        self.bus = bus
        self.a = self.x = self.y = 0
        self.sp = 0xFD
        self.p = I | U
        self.pc = 0
        self.cycles = 0
        self.nmi_pending = False
        self.irq_line = None        # callable: True while /IRQ is low (level-triggered)
        self.halted = False         # set on an unknown opcode
        self.last_opcode_pc = 0
        self._build()

    # ------------------------------------------------------------ helpers
    def r(self, a):
        return self.bus.read(a & 0xFFFF)

    def w(self, a, v):
        self.bus.write(a & 0xFFFF, v & 0xFF)

    def r16(self, a):
        return self.r(a) | (self.r(a + 1) << 8)

    def r16_zp(self, a):
        return self.r(a & 0xFF) | (self.r((a + 1) & 0xFF) << 8)

    def push(self, v):
        self.w(0x100 | self.sp, v)
        self.sp = (self.sp - 1) & 0xFF

    def pull(self):
        self.sp = (self.sp + 1) & 0xFF
        return self.r(0x100 | self.sp)

    def nz(self, v):
        v &= 0xFF
        self.p = (self.p & ~(N | Z)) | (v & N) | (Z if v == 0 else 0)
        return v

    def fetch(self):
        v = self.r(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def fetch16(self):
        lo = self.fetch()
        return lo | (self.fetch() << 8)

    # ------------------------------------------------------------ addressing
    # each returns an effective address (or None for implied/accumulator)
    def am_imm(self):
        a = self.pc
        self.pc = (self.pc + 1) & 0xFFFF
        return a

    def am_zp(self):
        return self.fetch()

    def am_zpx(self):
        return (self.fetch() + self.x) & 0xFF

    def am_zpy(self):
        return (self.fetch() + self.y) & 0xFF

    def am_abs(self):
        return self.fetch16()

    def am_abx(self):
        return (self.fetch16() + self.x) & 0xFFFF

    def am_aby(self):
        return (self.fetch16() + self.y) & 0xFFFF

    def am_izx(self):
        return self.r16_zp(self.fetch() + self.x)

    def am_izy(self):
        return (self.r16_zp(self.fetch()) + self.y) & 0xFFFF

    def am_ind(self):
        a = self.fetch16()
        # 6502 page-wrap bug
        return self.r(a) | (self.r((a & 0xFF00) | ((a + 1) & 0xFF)) << 8)

    # ------------------------------------------------------------ operations
    def adc(self, v):
        s = self.a + v + (self.p & C)
        self.p = (self.p & ~(C | V)) | (C if s > 0xFF else 0) | \
                 (V if (~(self.a ^ v) & (self.a ^ s) & 0x80) else 0)
        self.a = self.nz(s)

    def cmp(self, reg, v):
        t = reg - v
        self.p = (self.p & ~C) | (C if reg >= v else 0)
        self.nz(t)

    def branch(self, cond):
        off = self.fetch()
        if cond:
            self.pc = (self.pc + (off - 256 if off & 0x80 else off)) & 0xFFFF
            self.cycles += 1

    def _build(self):
        t = {}
        am = {'imm': self.am_imm, 'zp': self.am_zp, 'zpx': self.am_zpx, 'zpy': self.am_zpy,
              'abs': self.am_abs, 'abx': self.am_abx, 'aby': self.am_aby,
              'izx': self.am_izx, 'izy': self.am_izy}

        def load(reg, mode, cyc):
            def f():
                v = self.r(am[mode]())
                setattr(self, reg, self.nz(v))
            return f, cyc

        def store(reg, mode, cyc):
            def f():
                self.w(am[mode](), getattr(self, reg))
            return f, cyc

        def alu(op, mode, cyc):
            def f():
                v = self.r(am[mode]())
                if op == 'ORA':
                    self.a = self.nz(self.a | v)
                elif op == 'AND':
                    self.a = self.nz(self.a & v)
                elif op == 'EOR':
                    self.a = self.nz(self.a ^ v)
                elif op == 'ADC':
                    self.adc(v)
                elif op == 'SBC':
                    self.adc(v ^ 0xFF)
                elif op == 'CMP':
                    self.cmp(self.a, v)
                elif op == 'CPX':
                    self.cmp(self.x, v)
                elif op == 'CPY':
                    self.cmp(self.y, v)
                elif op == 'BIT':
                    self.p = (self.p & ~(N | V | Z)) | (v & (N | V)) | (Z if (self.a & v) == 0 else 0)
            return f, cyc

        def rmw(op, mode, cyc):
            def calc(v):
                if op == 'ASL':
                    self.p = (self.p & ~C) | (C if v & 0x80 else 0)
                    v = (v << 1) & 0xFF
                elif op == 'LSR':
                    self.p = (self.p & ~C) | (v & 1)
                    v >>= 1
                elif op == 'ROL':
                    c = self.p & C
                    self.p = (self.p & ~C) | (C if v & 0x80 else 0)
                    v = ((v << 1) | c) & 0xFF
                elif op == 'ROR':
                    c = self.p & C
                    self.p = (self.p & ~C) | (v & 1)
                    v = (v >> 1) | (0x80 if c else 0)
                elif op == 'INC':
                    v = (v + 1) & 0xFF
                elif op == 'DEC':
                    v = (v - 1) & 0xFF
                return self.nz(v)

            if mode == 'acc':
                def f():
                    self.a = calc(self.a)
            else:
                def f():
                    a = am[mode]()
                    self.w(a, calc(self.r(a)))
            return f, cyc

        groups = {
            'ORA': {0x09: 'imm', 0x05: 'zp', 0x15: 'zpx', 0x0D: 'abs', 0x1D: 'abx', 0x19: 'aby', 0x01: 'izx', 0x11: 'izy'},
            'AND': {0x29: 'imm', 0x25: 'zp', 0x35: 'zpx', 0x2D: 'abs', 0x3D: 'abx', 0x39: 'aby', 0x21: 'izx', 0x31: 'izy'},
            'EOR': {0x49: 'imm', 0x45: 'zp', 0x55: 'zpx', 0x4D: 'abs', 0x5D: 'abx', 0x59: 'aby', 0x41: 'izx', 0x51: 'izy'},
            'ADC': {0x69: 'imm', 0x65: 'zp', 0x75: 'zpx', 0x6D: 'abs', 0x7D: 'abx', 0x79: 'aby', 0x61: 'izx', 0x71: 'izy'},
            'SBC': {0xE9: 'imm', 0xE5: 'zp', 0xF5: 'zpx', 0xED: 'abs', 0xFD: 'abx', 0xF9: 'aby', 0xE1: 'izx', 0xF1: 'izy'},
            'CMP': {0xC9: 'imm', 0xC5: 'zp', 0xD5: 'zpx', 0xCD: 'abs', 0xDD: 'abx', 0xD9: 'aby', 0xC1: 'izx', 0xD1: 'izy'},
            'CPX': {0xE0: 'imm', 0xE4: 'zp', 0xEC: 'abs'},
            'CPY': {0xC0: 'imm', 0xC4: 'zp', 0xCC: 'abs'},
            'BIT': {0x24: 'zp', 0x2C: 'abs'},
        }
        cyc = {'imm': 2, 'zp': 3, 'zpx': 4, 'zpy': 4, 'abs': 4, 'abx': 4, 'aby': 4, 'izx': 6, 'izy': 5}
        for op, modes in groups.items():
            for code, mode in modes.items():
                t[code] = alu(op, mode, cyc[mode])

        for code, (reg, mode) in {
                0xA9: ('a', 'imm'), 0xA5: ('a', 'zp'), 0xB5: ('a', 'zpx'), 0xAD: ('a', 'abs'),
                0xBD: ('a', 'abx'), 0xB9: ('a', 'aby'), 0xA1: ('a', 'izx'), 0xB1: ('a', 'izy'),
                0xA2: ('x', 'imm'), 0xA6: ('x', 'zp'), 0xB6: ('x', 'zpy'), 0xAE: ('x', 'abs'), 0xBE: ('x', 'aby'),
                0xA0: ('y', 'imm'), 0xA4: ('y', 'zp'), 0xB4: ('y', 'zpx'), 0xAC: ('y', 'abs'), 0xBC: ('y', 'abx')}.items():
            t[code] = load(reg, mode, cyc[mode])

        for code, (reg, mode, c) in {
                0x85: ('a', 'zp', 3), 0x95: ('a', 'zpx', 4), 0x8D: ('a', 'abs', 4), 0x9D: ('a', 'abx', 5),
                0x99: ('a', 'aby', 5), 0x81: ('a', 'izx', 6), 0x91: ('a', 'izy', 6),
                0x86: ('x', 'zp', 3), 0x96: ('x', 'zpy', 4), 0x8E: ('x', 'abs', 4),
                0x84: ('y', 'zp', 3), 0x94: ('y', 'zpx', 4), 0x8C: ('y', 'abs', 4)}.items():
            t[code] = store(reg, mode, c)

        for op, base in (('ASL', 0x00), ('ROL', 0x20), ('LSR', 0x40), ('ROR', 0x60)):
            t[base + 0x0A] = rmw(op, 'acc', 2)
            t[base + 0x06] = rmw(op, 'zp', 5)
            t[base + 0x16] = rmw(op, 'zpx', 6)
            t[base + 0x0E] = rmw(op, 'abs', 6)
            t[base + 0x1E] = rmw(op, 'abx', 7)
        for op, base in (('DEC', 0xC0), ('INC', 0xE0)):
            t[base + 0x06] = rmw(op, 'zp', 5)
            t[base + 0x16] = rmw(op, 'zpx', 6)
            t[base + 0x0E] = rmw(op, 'abs', 6)
            t[base + 0x1E] = rmw(op, 'abx', 7)

        def simple(fn, c):
            return fn, c

        def setreg(reg, src):
            def f():
                setattr(self, reg, self.nz(getattr(self, src)))
            return f

        def incdec(reg, d):
            def f():
                setattr(self, reg, self.nz(getattr(self, reg) + d))
            return f

        def flag(mask, on):
            def f():
                self.p = (self.p | mask) if on else (self.p & ~mask)
            return f

        t[0xAA] = simple(setreg('x', 'a'), 2)
        t[0xA8] = simple(setreg('y', 'a'), 2)
        t[0x8A] = simple(setreg('a', 'x'), 2)
        t[0x98] = simple(setreg('a', 'y'), 2)
        t[0xBA] = simple(setreg('x', 'sp'), 2)

        def txs():
            self.sp = self.x
        t[0x9A] = simple(txs, 2)
        t[0xE8] = simple(incdec('x', 1), 2)
        t[0xCA] = simple(incdec('x', -1), 2)
        t[0xC8] = simple(incdec('y', 1), 2)
        t[0x88] = simple(incdec('y', -1), 2)
        t[0x18] = simple(flag(C, False), 2)
        t[0x38] = simple(flag(C, True), 2)
        t[0x58] = simple(flag(I, False), 2)
        t[0x78] = simple(flag(I, True), 2)
        t[0xB8] = simple(flag(V, False), 2)
        t[0xD8] = simple(flag(D, False), 2)
        t[0xF8] = simple(flag(D, True), 2)
        t[0xEA] = simple(lambda: None, 2)

        def pha():
            self.push(self.a)

        def php():
            self.push(self.p | B | U)

        def pla():
            self.a = self.nz(self.pull())

        def plp():
            self.p = (self.pull() & ~B) | U
        t[0x48] = simple(pha, 3)
        t[0x08] = simple(php, 3)
        t[0x68] = simple(pla, 4)
        t[0x28] = simple(plp, 4)

        for code, (mask, val) in {0x10: (N, 0), 0x30: (N, 1), 0x50: (V, 0), 0x70: (V, 1),
                                  0x90: (C, 0), 0xB0: (C, 1), 0xD0: (Z, 0), 0xF0: (Z, 1)}.items():
            def mk(mask=mask, val=val):
                return lambda: self.branch(bool(self.p & mask) == bool(val))
            t[code] = simple(mk(), 2)

        def jmp_abs():
            self.pc = self.fetch16()

        def jmp_ind():
            self.pc = self.am_ind()

        def jsr():
            target = self.fetch16()
            ret = (self.pc - 1) & 0xFFFF
            self.push(ret >> 8)
            self.push(ret & 0xFF)
            self.pc = target

        def rts():
            lo = self.pull()
            self.pc = ((self.pull() << 8) | lo) + 1 & 0xFFFF

        def rti():
            self.p = (self.pull() & ~B) | U
            lo = self.pull()
            self.pc = (self.pull() << 8) | lo

        def brk():
            self.pc = (self.pc + 1) & 0xFFFF
            self.push(self.pc >> 8)
            self.push(self.pc & 0xFF)
            self.push(self.p | B | U)
            self.p |= I
            self.pc = self.r16(0xFFFE)
        t[0x4C] = simple(jmp_abs, 3)
        t[0x6C] = simple(jmp_ind, 5)
        t[0x20] = simple(jsr, 6)
        t[0x60] = simple(rts, 6)
        t[0x40] = simple(rti, 6)
        t[0x00] = simple(brk, 7)
        self.table = t

    # ------------------------------------------------------------ run
    def reset(self):
        self.sp = 0xFD
        self.p = I | U
        self.pc = self.r16(0xFFFC)

    def nmi(self):
        self.push(self.pc >> 8)
        self.push(self.pc & 0xFF)
        self.push((self.p & ~B) | U)
        self.p |= I
        self.pc = self.r16(0xFFFA)
        self.cycles += 7

    def irq(self):
        self.push(self.pc >> 8)
        self.push(self.pc & 0xFF)
        self.push((self.p & ~B) | U)
        self.p |= I
        self.pc = self.r16(0xFFFE)
        self.cycles += 7

    def step(self):
        if self.nmi_pending:
            self.nmi_pending = False
            self.nmi()
        elif self.irq_line is not None and not (self.p & I) and self.irq_line():
            self.irq()
        self.last_opcode_pc = self.pc
        op = self.fetch()
        ent = self.table.get(op)
        if ent is None:
            self.halted = True
            self.pc = self.last_opcode_pc
            return 0
        fn, c = ent
        fn()
        self.cycles += c
        return c
