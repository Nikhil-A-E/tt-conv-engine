## How it works

This is an 8-tap FIR filter / 1D convolution engine. It computes

```
y[n] = sum_{k=0}^{7} h[k] * x[n-k]
```

where `h[k]` are 8 reloadable signed 8-bit coefficients and `x` is a stream of signed 8-bit samples.

To fit in a single tile, there is no array multiplier. One shift-add MAC unit processes one coefficient bit per clock: it adds `x << i` for each set bit `i` of `h[k]`, and subtracts it for the sign bit. So each tap takes 8 cycles and each output 64 MAC cycles, about 72 clock cycles from `VALID_IN` to `DONE` (7.2 us at 10 MHz). The result is bit-exact with a normal multiply.

- **Coefficient RAM:** 8 x 8-bit, written in load mode.
- **Sample shift register:** holds the last 8 samples (index 0 = newest). It is cleared whenever a new kernel is loaded.
- **Accumulator:** 20-bit signed. The worst case, 8 x 128 x 128 = 131072, fits with headroom, so it can never overflow.
- **Output:** the accumulator is arithmetic-shifted right by 10 (truncation), then saturated to int8. Full-scale inputs give -127..+127; the only case that clamps is all eight products being (-128)x(-128), which gives +128 and is clamped to +127.

`VALID_IN` passes through a 2-flop synchronizer and is rising-edge detected. One pulse loads exactly one byte, however long it is held high, so the chip can be driven safely from slow, unsynchronized software on the RP2040. Data, MODE and START are sampled only on that edge, so they must already be stable when `VALID_IN` rises.

To fit a single tile, the coefficient storage has no reset. After reset its contents are undefined until a kernel is loaded.

## How to test

Pins: `ui_in` = data in, `uo_out` = signed result, `uio[0]` = MODE, `uio[1]` = VALID_IN, `uio[2]` = VALID_OUT (1-cycle strobe), `uio[3]` = START, `uio[4]` = DONE (sticky).

For every byte, set `ui_in`, MODE and START **first**, then raise VALID_IN, hold it for at least 3 clock cycles, and lower it again. Keep `ui_in`, MODE and START unchanged until VALID_IN is low.

1. **Reset:** hold `rst_n` low for a few clock cycles, with the clock running. Always load a kernel after reset.
2. **Load the kernel:** with MODE = 0, send the 8 coefficients `h[0]` .. `h[7]` (one VALID_IN pulse each). This also clears the sample history.
3. **Stream samples:** with MODE = 1 and START = 1, send one sample with a VALID_IN pulse.
4. **Read the result:** DONE (`uio[4]`) from the previous result drops within a few clocks of VALID_IN rising. Wait for it to go low, then high again, then read the signed result on `uo_out`. The result stays on `uo_out` until the next one. DONE clears on the next VALID_IN.
5. **Repeat** step 3 for each new sample. To change the filter, repeat step 2.

Example: kernel `[64, 0, 0, 0, 0, 0, 0, 0]`, sample `127` gives `(127*64) >> 10 = 7`.

A ready-made MicroPython driver for the TT demo board is in `host/conv_engine.py` in the project repository. Copy it to the board and run `ConvEngine().self_test()` to check the chip against the golden model.

Any clock up to 50 MHz works. 10 MHz is a good default.

## External hardware

None. Everything is driven from the TT demo board (RP2040) or any microcontroller connected to the pins.

## Credits

We gratefully acknowledge the Center of Excellence (CoE) in Integrated Circuits and Systems (ICAS) and the Department of Electronics and Communication Engineering (ECE) for providing the necessary resources and guidance.

Special thanks to Dr. H V Ravish Aradhya (HoD - ECE), Dr. K R Usha Rani (Associate Dean - PG), Dr. K. S. Geetha (Vice Principal) and Dr. K. N. Subramanya (Principal) for their constant encouragement and support in facilitating this Tiny Tapeout SKY26E submission.
