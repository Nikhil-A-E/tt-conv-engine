# SPDX-FileCopyrightText: © 2026 Nikhil
# SPDX-License-Identifier: Apache-2.0
#
# cocotb tests for tt_um_nikhil_a_e_conv (8-tap MAC-based FIR engine).
# Drives the chip only through the TT pins, the same way the RP2040 on the
# demo board would, so the same tests run on RTL and on the gate-level netlist.

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

K = 8
VEC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")

# uio bit positions
MODE, VALID_IN, VALID_OUT, START, DONE = 0, 1, 2, 3, 4


# ---------------------------------------------------------------------------
# Golden model (same bit-exact rules as golden_model/golden_conv.py)
# ---------------------------------------------------------------------------
def golden(kernel, samples):
    shreg = [0] * K
    out = []
    for x in samples:
        shreg = [x] + shreg[:-1]
        acc = 0
        for k in range(K):
            acc = max(-(1 << 19), min((1 << 19) - 1, acc + kernel[k] * shreg[k]))
        out.append(max(-128, min(127, acc >> 12)))
    return out


def to_s8(v):
    v &= 0xFF
    return v - 256 if v & 0x80 else v


def read_hex(name):
    with open(os.path.join(VEC_DIR, name)) as f:
        return [to_s8(int(line, 16)) for line in f if line.strip()]


# ---------------------------------------------------------------------------
# Pin-level driver
# ---------------------------------------------------------------------------
class Host:
    def __init__(self, dut):
        self.dut = dut
        self.uio = 0

    def _drive(self):
        self.dut.uio_in.value = self.uio

    def bit(self, sig, n):
        return (int(sig.value) >> n) & 1

    async def reset(self):
        self.dut.ena.value = 1
        self.dut.ui_in.value = 0
        self.uio = 0
        self._drive()
        self.dut.rst_n.value = 0
        await ClockCycles(self.dut.clk, 10)
        self.dut.rst_n.value = 1
        await ClockCycles(self.dut.clk, 5)

    async def send_byte(self, value, mode, start, hold=3, gap=3):
        """Set data/mode/start first, then pulse valid_in for `hold` cycles."""
        self.dut.ui_in.value = value & 0xFF
        self.uio = (mode << MODE) | (start << START)
        self._drive()
        await ClockCycles(self.dut.clk, 1)
        self.uio |= 1 << VALID_IN
        self._drive()
        await ClockCycles(self.dut.clk, hold)
        self.uio &= ~(1 << VALID_IN)
        self._drive()
        await ClockCycles(self.dut.clk, gap)

    async def load_kernel(self, kernel, hold=3):
        for h in kernel:
            await self.send_byte(h, mode=0, start=0, hold=hold)

    async def wait_done(self, level, timeout):
        for _ in range(timeout):
            if self.bit(self.dut.uio_out, DONE) == level:
                return
            await ClockCycles(self.dut.clk, 1)
        raise AssertionError(f"timeout waiting for DONE={level}")

    async def stream(self, sample, hold=3, timeout=300):
        """Send one sample and wait for a NEW result; return it.

        DONE from the previous result clears a few cycles after VALID_IN
        rises, so wait for it to drop first, then for it to rise again
        (same rule a real host must follow).
        """
        await self.send_byte(sample, mode=1, start=1, hold=hold, gap=0)
        await self.wait_done(0, timeout)
        await self.wait_done(1, timeout)
        return to_s8(int(self.dut.uo_out.value))


async def setup(dut):
    clock = Clock(dut.clk, 100, unit="ns")  # 10 MHz
    cocotb.start_soon(clock.start())
    host = Host(dut)
    await host.reset()
    return host


async def run_vectors(dut, name, n=None):
    host = await setup(dut)
    kernel = read_hex(f"{name}_kernel.hex")
    samples = read_hex(f"{name}_samples.hex")
    expected = read_hex(f"{name}_outputs.hex")
    if n is not None:
        samples, expected = samples[:n], expected[:n]

    # The checked-in vectors must agree with the golden model
    assert golden(kernel, samples) == expected, f"{name}: vector files disagree with golden model"

    await host.load_kernel(kernel)
    fails = 0
    for i, (x, exp) in enumerate(zip(samples, expected)):
        got = await host.stream(x)
        if got != exp:
            fails += 1
            dut._log.error(f"{name}[{i}] in={x} got={got} exp={exp}")
    assert fails == 0, f"{name}: {fails}/{len(samples)} mismatches"
    dut._log.info(f"{name}: {len(samples)}/{len(samples)} passed")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_pin_directions(dut):
    host = await setup(dut)
    assert int(dut.uio_oe.value) == 0b0001_0100, "uio_oe must be uio[2], uio[4] = outputs"
    assert int(dut.uo_out.value) == 0, "uo_out must be 0 after reset"
    assert host.bit(dut.uio_out, DONE) == 0, "DONE must be 0 after reset"


@cocotb.test()
async def test_zero_kernel(dut):
    await run_vectors(dut, "zero_kernel")


@cocotb.test()
async def test_impulse_kernel(dut):
    await run_vectors(dut, "impulse_kernel")


@cocotb.test()
async def test_random_kernel(dut):
    await run_vectors(dut, "random_kernel")  # all 256 samples


@cocotb.test()
async def test_overflow_maxpos(dut):
    await run_vectors(dut, "overflow_maxpos")


@cocotb.test()
async def test_overflow_minneg(dut):
    await run_vectors(dut, "overflow_minneg")


@cocotb.test()
async def test_accumulator_extremes(dut):
    """Largest possible |acc|: (-128)*(-128)*8 = +131072 and 127*(-128)*8."""
    host = await setup(dut)
    for kernel, x in [([-128] * K, -128), ([-128] * K, 127), ([127] * K, -128), ([127] * K, 127)]:
        await host.load_kernel(kernel)
        samples = [x] * K
        exp = golden(kernel, samples)
        for i, s in enumerate(samples):
            got = await host.stream(s)
            assert got == exp[i], f"extreme k={kernel[0]} x={x} [{i}] got={got} exp={exp[i]}"
    assert golden([-128] * K, [-128] * K)[-1] == 32


@cocotb.test()
async def test_long_valid_pulse(dut):
    """valid_in held for 20 cycles must still count as ONE byte."""
    host = await setup(dut)
    kernel = [64, 32, 16, 8, -8, -16, -32, -64]
    samples = [127, -128, 100, -100, 50, -50, 25, -25, 0, 127, 127, 127]
    await host.load_kernel(kernel, hold=20)
    exp = golden(kernel, samples)
    for x, e in zip(samples, exp):
        got = await host.stream(x, hold=20)
        assert got == e, f"long pulse: in={x} got={got} exp={e}"


@cocotb.test()
async def test_kernel_reload_clears_samples(dut):
    """Reloading the kernel must reset the sample history to zero."""
    host = await setup(dut)
    await host.load_kernel([127] * K)
    for x in [127] * K:
        await host.stream(x)
    kernel2 = [64, 64, 64, 64, 64, 64, 64, 64]
    await host.load_kernel(kernel2)
    got = await host.stream(100)
    exp = golden(kernel2, [100])[0]
    assert got == exp, f"after reload got={got} exp={exp} (old samples leaked)"


@cocotb.test()
async def test_done_and_valid_out(dut):
    """DONE is sticky until the next valid_in; VALID_OUT is a 1-cycle strobe."""
    host = await setup(dut)
    await host.load_kernel([64] + [0] * (K - 1))
    await host.send_byte(127, mode=1, start=1, gap=0)
    strobes = 0
    for _ in range(200):
        await ClockCycles(dut.clk, 1)
        strobes += host.bit(dut.uio_out, VALID_OUT)
    assert strobes == 1, f"VALID_OUT pulsed {strobes} times, expected 1"
    assert host.bit(dut.uio_out, DONE) == 1, "DONE should stay high"
    assert to_s8(int(dut.uo_out.value)) == golden([64] + [0] * 7, [127])[0]

    # Next valid_in clears DONE
    await host.send_byte(0, mode=1, start=1, hold=3, gap=2)
    assert host.bit(dut.uio_out, DONE) == 0, "DONE should clear on next valid_in"


@cocotb.test()
async def test_stream_without_start_is_ignored(dut):
    """mode=1 with start=0 must not push a sample."""
    host = await setup(dut)
    kernel = [64] + [0] * (K - 1)
    await host.load_kernel(kernel)
    await host.send_byte(100, mode=1, start=0)   # ignored
    await ClockCycles(dut.clk, 150)
    assert host.bit(dut.uio_out, DONE) == 0, "no result expected without START"
    got = await host.stream(-100)
    assert got == golden(kernel, [-100])[0]
