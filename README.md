![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg)

# Reconfigurable MAC-Based Convolution Engine

An 8-tap FIR filter / 1D convolution accelerator for the **Tiny Tapeout SKY26E** shuttle (SkyWater SKY130, one 1x1 tile).

```
y[n] = sum_{k=0}^{7} h[k] * x[n-k]
```

The 8 coefficients `h[k]` are loaded at run time, so the same chip can implement any 8-tap filter: low-pass, high-pass, differentiator or matched filter. Samples, coefficients and outputs are all signed 8-bit. This structure is the building block behind FIR filtering, correlation and radar pulse compression.

**Authors:** Nikhil A E, Monisha S, Navya K J, Poornachandra B R and Shylashree N, RV College of Engineering.

- Full datasheet: [docs/info.md](docs/info.md)
- RTL: [src/](src)
- Tests: [test/](test)
- Demo-board driver: [host/conv_engine.py](host/conv_engine.py)

## Architecture

| Block | File | Function |
|---|---|---|
| Top level | `src/project.v` | `tt_um_nikhil_a_e_conv`: TT pin wrapper, `VALID_IN` synchronizer and edge detect, sticky `DONE` flag |
| Pin bridge | `src/conv_top.v`, `src/serial_io.v` | Maps the `uio` control pins, drives the result and `VALID_OUT` |
| Core | `src/conv_core.v` | Connects the blocks below |
| Control FSM | `src/fsm.v` | IDLE -> LOAD_KERNEL / STREAM_SAMPLE -> MAC_CLEAR -> MAC_ITERATE -> OUTPUT |
| Coefficient RAM | `src/coeff_ram.v` | 8 x 8-bit, written in load mode |
| Sample shift register | `src/sample_shreg.v` | Last 8 samples; cleared on every kernel load |
| MAC unit | `src/mac_unit.v` | Signed shift-add multiply-accumulate, 20-bit accumulator, `>>> 10` and int8 saturation |

To fit in a single tile, there is no array multiplier. One shift-add MAC processes **one coefficient bit per clock**, so each output takes 64 MAC cycles, about 72 clocks from `VALID_IN` to `DONE` (7.2 us at 10 MHz). The result is bit-exact with a normal multiply; this was checked exhaustively for all 65,536 sample/coefficient pairs.

## Pinout

| Pin | Dir | Function |
|---|---|---|
| `ui_in[7:0]` | in | Data: coefficient (MODE=0) or sample (MODE=1) |
| `uo_out[7:0]` | out | Signed result, held until the next result |
| `uio[0]` | in | MODE: 0 = load kernel, 1 = stream samples |
| `uio[1]` | in | VALID_IN: rising edge takes the byte on `ui_in` |
| `uio[2]` | out | VALID_OUT: 1-cycle strobe when `uo_out` updates |
| `uio[3]` | in | START: must be 1 with MODE=1 to process a sample |
| `uio[4]` | out | DONE: sticky "result ready" flag, cleared by the next VALID_IN |

## How to use

1. **Reset** (`rst_n` low for a few clocks), then always load a kernel.
2. **Load the kernel:** with MODE=0, send `h[0]` .. `h[7]`, one VALID_IN pulse each.
3. **Stream samples:** with MODE=1 and START=1, send a sample with a VALID_IN pulse.
4. **Read the result:** wait for DONE to go low, then high again, then read `uo_out`.

For every byte, set data, MODE and START first, raise VALID_IN for at least 3 clocks, then lower it. Keep data, MODE and START stable until VALID_IN is low.

Example: kernel `[64, 0, 0, 0, 0, 0, 0, 0]` with sample `127` gives `(127*64) >> 10 = 7`.

On the Tiny Tapeout demo board:

```python
from conv_engine import ConvEngine
eng = ConvEngine()                 # enables the project, 10 MHz clock, reset
eng.self_test()                    # checks the chip against the golden model
eng.load_kernel([64, 0, 0, 0, 0, 0, 0, 0])
print(eng.filter(127))             # -> 7
```

## Verification

- **cocotb, 14 tests** (`test/test.py`), run on both the RTL and the post-layout gate-level netlist:
  - golden vectors: zero, impulse, 256-sample random, overflow cases
  - accumulator extremes, including the +128 -> +127 clamp
  - 12 random kernels with reloads
  - long VALID_IN pulses
  - VALID_IN while busy, START missing, reset mid-computation
  - DONE / VALID_OUT behaviour
- **Signoff (LibreLane):** DRC, LVS and antenna clean, TT precheck passed, no setup or hold violations at any corner. Utilisation is about 69% of a 1x1 tile.

## Credits

We gratefully acknowledge the Center of Excellence (CoE) in Integrated Circuits and Systems (ICAS) and the Department of Electronics and Communication Engineering (ECE), RV College of Engineering, for providing the necessary resources and guidance.

Special thanks to Dr. H V Ravish Aradhya (HoD - ECE), Dr. K R Usha Rani (Associate Dean - PG), Dr. K. S. Geetha (Vice Principal) and Dr. K. N. Subramanya (Principal) for their constant encouragement and support in facilitating this Tiny Tapeout SKY26E submission.

## About Tiny Tapeout

[Tiny Tapeout](https://tinytapeout.com) is an educational project that makes it easier and cheaper to get digital and analog designs manufactured on a real chip.
