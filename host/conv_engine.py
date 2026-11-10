# SPDX-FileCopyrightText: © 2026 Nikhil A E
# SPDX-License-Identifier: Apache-2.0
#
# MicroPython driver for tt_um_nikhil_a_e_conv on the Tiny Tapeout demo board
# (RP2040/RP2350 running the tt-micropython-firmware "ttboard" SDK).
#
# Usage on the board (e.g. via mpremote / Thonny REPL):
#
#   from conv_engine import ConvEngine
#   eng = ConvEngine()                 # enables the project, 10 MHz clock, reset
#   eng.self_test()                    # optional: checks the chip against the golden model
#   eng.load_kernel([64, 0, 0, 0, 0, 0, 0, 0])
#   print(eng.filter(127))             # -> 7
#   print(eng.filter_many([1, 2, 3]))
#
# Pin protocol (see docs/info.md):
#   ui_in[7:0] data in      uo_out[7:0] signed result
#   uio[0] MODE (in)        uio[1] VALID_IN (in)    uio[2] VALID_OUT (out)
#   uio[3] START (in)       uio[4] DONE (out, sticky)
# Set data/MODE/START first, raise VALID_IN, hold it, lower it.
# For a result: wait for DONE to drop, then rise, then read uo_out.

import time

try:
    from ttboard.demoboard import DemoBoard
except ImportError:  # allows importing on a PC for the mock test
    DemoBoard = None

PROJECT = "tt_um_nikhil_a_e_conv"
K = 8
SHIFT = 10

MODE, VALID_IN, VALID_OUT, START, DONE = 0, 1, 2, 3, 4
# The RP2 may ONLY drive the chip's input bidirectionals. uio[2] and uio[4]
# are driven by the chip; driving them from the RP2 would short two outputs.
PICO_OE = (1 << MODE) | (1 << VALID_IN) | (1 << START)   # 0b0000_1011


def to_s8(v):
    v &= 0xFF
    return v - 256 if v & 0x80 else v


def golden(kernel, samples, history=None):
    """Bit-exact reference model (same as test/test.py)."""
    shreg = list(history) if history else [0] * K
    out = []
    for x in samples:
        shreg = [x] + shreg[:-1]
        acc = 0
        for k in range(K):
            acc += kernel[k] * shreg[k]
        out.append(max(-128, min(127, acc >> SHIFT)))
    return out


class ConvEngine:
    def __init__(self, tt=None, clock_hz=10_000_000, timeout_ms=100):
        self.tt = tt if tt is not None else DemoBoard.get()
        self.timeout_ms = timeout_ms
        self.kernel = None
        getattr(self.tt.shuttle, PROJECT).enable()
        self.tt.uio_oe_pico.value = PICO_OE
        self.tt.uio_in.value = 0
        self.tt.ui_in.value = 0
        self.tt.clock_project_PWM(clock_hz)
        self.reset()

    # ------------------------------------------------------------------
    # Low-level pin helpers
    # ------------------------------------------------------------------
    def _set_ctrl(self, mode, start, valid):
        # Only bits 0, 1, 3 are ever set; bits 2 and 4 stay 0 (and are not
        # driven anyway because PICO_OE excludes them).
        self.tt.uio_in.value = (mode << MODE) | (valid << VALID_IN) | (start << START)

    def _done(self):
        return (int(self.tt.uio_out.value) >> DONE) & 1

    def _wait_done(self, level):
        t0 = time.ticks_ms()
        while self._done() != level:
            if time.ticks_diff(time.ticks_ms(), t0) > self.timeout_ms:
                raise RuntimeError("timeout waiting for DONE=%d" % level)

    def _send_byte(self, value, mode, start):
        self.tt.ui_in.value = value & 0xFF      # 1. data
        self._set_ctrl(mode, start, 0)          # 2. MODE / START
        time.sleep_us(2)
        self._set_ctrl(mode, start, 1)          # 3. VALID_IN high (>= 3 clocks)
        time.sleep_us(2)
        self._set_ctrl(mode, start, 0)          # 4. VALID_IN low
        time.sleep_us(2)                        #    data stays stable until here

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    def reset(self):
        self.tt.reset_project(True)
        time.sleep_ms(1)                        # many clocks at any sane freq
        self.tt.reset_project(False)
        time.sleep_ms(1)
        self.kernel = None                      # must reload after reset

    def load_kernel(self, kernel):
        if len(kernel) != K or not all(-128 <= h <= 127 for h in kernel):
            raise ValueError("kernel must be 8 ints in -128..127")
        for h in kernel:
            self._send_byte(h, mode=0, start=0)
        self.kernel = list(kernel)

    def filter(self, sample):
        """Push one sample, return the signed int8 filter output."""
        if self.kernel is None:
            raise RuntimeError("load_kernel() first (required after reset)")
        if not -128 <= sample <= 127:
            raise ValueError("sample must be in -128..127")
        self._send_byte(sample, mode=1, start=1)
        self._wait_done(0)                      # old DONE clears ...
        self._wait_done(1)                      # ... then the new result is ready
        return to_s8(int(self.tt.uo_out.value))

    def filter_many(self, samples):
        return [self.filter(x) for x in samples]

    def self_test(self, seed=1, n_kernels=4, n_samples=32, verbose=True):
        """Compare the chip against the golden model; returns True if all match."""
        # Small LCG so it behaves the same in MicroPython and CPython
        state = [seed & 0x7FFFFFFF]

        def rnd():
            state[0] = (1103515245 * state[0] + 12345) & 0x7FFFFFFF
            return (state[0] >> 16) % 256 - 128

        cases = [([64, 0, 0, 0, 0, 0, 0, 0], [127, -128, 100, -100, 1, -1, 0, 50]),
                 ([-128] * K, [-128] * K)]          # +128 -> clamped to 127
        for _ in range(n_kernels):
            cases.append(([rnd() for _ in range(K)], [rnd() for _ in range(n_samples)]))

        fails = 0
        for kernel, samples in cases:
            self.load_kernel(kernel)
            exp = golden(kernel, samples)
            got = self.filter_many(samples)
            bad = [i for i in range(len(samples)) if got[i] != exp[i]]
            fails += len(bad)
            if verbose:
                print("kernel", kernel, "->", "OK" if not bad else "%d mismatches" % len(bad))
                for i in bad[:5]:
                    print("   x=%d got=%d exp=%d" % (samples[i], got[i], exp[i]))
        if verbose:
            print("SELF-TEST", "PASSED" if fails == 0 else "FAILED (%d)" % fails)
        return fails == 0
