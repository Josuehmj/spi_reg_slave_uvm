# Specification

Version 1.0 · RTL: `spi_reg_slave.sv`

## 1. Overview

`spi_reg_slave` is a small SPI slave (mode 0) whose only job is to expose an
8-bit register file **through the SPI bus itself**. There is no other bus: every
register access is an SPI frame. The register file contains a mix of access
types (RW, RO, W1C, self-clearing write-only, volatile) so that a UVM RAL model
has something meaningful to model.

```
            +-------------------------------------------+
 sclk  ---->|                                           |
 cs_n  ---->|  2FF sync -> SPI frame FSM -> Register    |----> irq_o
 mosi  ---->|                              file         |
 miso  <----|                                           |
 clk   ---->|                                           |
 rst_n ---->+-------------------------------------------+
```

## 2. Ports

| Port    | Dir | Width | Description                                              |
|---------|-----|-------|----------------------------------------------------------|
| `clk`   | in  | 1     | System clock. All SPI inputs are synchronized to it.     |
| `rst_n` | in  | 1     | Asynchronous, active-low reset.                          |
| `sclk`  | in  | 1     | SPI clock, idle low (CPOL=0).                            |
| `cs_n`  | in  | 1     | SPI chip select, active low.                             |
| `mosi`  | in  | 1     | Master-out / slave-in.                                   |
| `miso`  | out | 1     | Master-in / slave-out. Driven `0` when idle (never `Z`). |
| `irq_o` | out | 1     | Level interrupt, see section 6.                          |

## 3. SPI protocol

### 3.1 Mode and frame

- SPI mode 0 (CPOL=0, CPHA=0): the slave samples `mosi` on the SCLK **rising**
  edge; `miso` changes after the SCLK **falling** edge.
- One transaction = one frame = **16 SCLK cycles** while `cs_n` is low, MSB first.

```
bit index :   0     1 .. 7        8 .. 15
MOSI      :   RW    ADDR[6:0]     WDATA[7:0]   (ignored on reads)
MISO      :   0     0             RDATA[7:0]   on reads, 0 on writes
```

- `RW` = 1 → write, `RW` = 0 → read.
- A read returns the register value **as it was before the frame** (registers
  only change at the end of a frame, section 5).
- On write frames `miso` is `0` for the whole frame.

### 3.2 Frame validity

| Condition                                    | Behavior                                                                 |
|----------------------------------------------|--------------------------------------------------------------------------|
| Exactly 16 SCLK rising edges while `cs_n` low | Valid frame. Commits when `cs_n` rises.                                  |
| Fewer than 16 rising edges                   | **Aborted frame.** No register, counter or status change. `miso` stays 0 in the unreached bits. |
| More than 16 rising edges                    | The first 16 bits are used, extra edges are ignored, `miso` = 0 after bit 15. Frame commits normally. |

### 3.3 Timing constraints (in `clk` cycles)

The slave oversamples SCLK with `clk`, so the SPI clock must be slow relative
to `clk`.

| Parameter                                  | Limit          |
|--------------------------------------------|----------------|
| SCLK high time and low time                | ≥ 5 clk each   |
| `cs_n` falling → first SCLK rising edge    | ≥ 4 clk        |
| Last SCLK falling edge → `cs_n` rising     | ≥ 4 clk        |
| `cs_n` high time between frames            | ≥ 4 clk        |
| `mosi` stable around SCLK rising edge      | change only on SCLK falling edge |
| `miso` valid after SCLK falling edge       | ≤ 3 clk        |

Behavior outside these limits is undefined and out of scope.

## 4. Register map

Address is 7 bits, data is 8 bits. Reset is asynchronous (`rst_n` low).

| Addr   | Name        | Reset | Description                          |
|--------|-------------|-------|--------------------------------------|
| `0x00` | `ID`        | `0xA5`| Constant identification value.       |
| `0x01` | `CTRL`      | `0x00`| Control.                             |
| `0x02` | `THRESH`    | `0x10`| Frame-count threshold.               |
| `0x03` | `STATUS`    | `0x00`| Sticky status flags.                 |
| `0x04` | `FRAME_CNT` | `0x00`| Number of counted frames.            |
| `0x05` | `SCRATCH`   | `0x00`| General purpose read/write register. |

### 4.1 Fields

| Register    | Bits  | Field       | Access            | Reset | Description |
|-------------|-------|-------------|-------------------|-------|-------------|
| `ID`        | [7:0] | `VALUE`     | RO                | `0xA5`| Constant. Writes are ignored and set `STATUS.ERR`. |
| `CTRL`      | [0]   | `EN`        | RW                | 0     | Enables `FRAME_CNT` counting. |
|             | [1]   | `CNT_CLR`   | Write-only, self-clearing | 0 | Writing 1 clears `FRAME_CNT`. Always reads 0. |
|             | [2]   | `IRQ_EN`    | RW                | 0     | Enables `irq_o`. |
|             | [7:3] | `RSVD`      | RO (reads 0)      | 0     | Writes ignored, no error. |
| `THRESH`    | [7:0] | `VALUE`     | RW                | `0x10`| Threshold compared against the counter. `0x00` never matches. |
| `STATUS`    | [0]   | `THRESH_HIT`| W1C               | 0     | Set when `FRAME_CNT` reaches `THRESH`. Write 1 to clear, write 0 has no effect. |
|             | [1]   | `ERR`       | W1C               | 0     | Set on an illegal access (section 5.3). Write 1 to clear. |
|             | [7:2] | `RSVD`      | RO (reads 0)      | 0     | Writes ignored, no error. |
| `FRAME_CNT` | [7:0] | `VALUE`     | RO, **volatile**  | 0     | Changes without a write from the bus. Saturates at `0xFF`. Writes are ignored and set `STATUS.ERR`. |
| `SCRATCH`   | [7:0] | `VALUE`     | RW                | `0x00`| No side effects. |

## 5. Behavior

### 5.1 When things happen

All state changes happen **once per frame, when `cs_n` rises**, and only for a
valid frame (section 3.2). Reads have no side effects. Within a single frame
end the order is:

1. Decode the access (R/W, address, data).
2. Apply the write: `CTRL`, `THRESH` and `SCRATCH` take the new value, W1C bits
   in `STATUS` are marked for clearing, `CNT_CLR` is evaluated.
3. Update `FRAME_CNT` (section 5.2).
4. Update `STATUS` (section 5.2 and 5.3). **Set wins over clear** if both
   target the same bit in the same frame.

### 5.2 Frame counter and threshold

- Every valid frame counts as one frame, **regardless of address or R/W**.
- A frame increments `FRAME_CNT` only if `CTRL.EN` was 1 **before** this
  frame's write, and `FRAME_CNT` is not `0xFF`.
  - The frame that writes `EN=1` is therefore not counted; the frame that
    writes `EN=0` is counted.
- If the frame writes `CTRL.CNT_CLR=1`, `FRAME_CNT` becomes `0x00` and the
  increment is suppressed (**clear wins**).
- `STATUS.THRESH_HIT` is set when the frame increments `FRAME_CNT` and the new
  value equals the `THRESH` value that was in effect **before** this frame's
  write.
- Because a read returns pre-frame values, reading `FRAME_CNT` returns the
  number of frames counted **before** the read frame itself.

### 5.3 Illegal accesses

`STATUS.ERR` is set (and the access otherwise has no effect) when a valid
frame:

- writes to `ID` or `FRAME_CNT`, or
- reads or writes an address greater than `0x05`.

Reads from an undefined address return `0x00`.
Writes to reserved bits of a valid register are ignored and do **not** set `ERR`.

## 6. Interrupt

```
irq_o = CTRL.IRQ_EN & STATUS.THRESH_HIT
```

Level-sensitive, combinational from the registers. It drops when software
clears `THRESH_HIT` (W1C) or `IRQ_EN`. `STATUS.ERR` does not drive `irq_o`.

## 7. Reset

`rst_n` low asynchronously resets every register to the value in section 4,
clears the frame state and drives `miso` and `irq_o` to 0. An in-flight frame
is discarded.

## 8. Backdoor HDL paths

Relative to the DUT instance. Useful for `uvm_reg` backdoor access and
`add_hdl_path_slice()`.

| Register / field     | Signal                |
|----------------------|-----------------------|
| `CTRL.EN`            | `r_ctrl_en`           |
| `CTRL.IRQ_EN`        | `r_ctrl_irq_en`       |
| `THRESH`             | `r_thresh`            |
| `STATUS.THRESH_HIT`  | `r_st_thresh_hit`     |
| `STATUS.ERR`         | `r_st_err`            |
| `FRAME_CNT`          | `r_frame_cnt`         |
| `SCRATCH`            | `r_scratch`           |

`ID` is a constant (`ID_VALUE` localparam) and has no backing register.
`CTRL.CNT_CLR` has no storage (it is a pulse). `CTRL` and `STATUS` are each
split across several signals, so their backdoor needs one slice per field.

## 9. Known simplifications

- `miso` is driven `0` when idle instead of tri-stating; multi-slave bus
  contention is out of scope.
- SPI mode 0 only, fixed 16-bit frame, no burst or auto-increment.
- Single clock domain for the register file; SPI pins are 2-FF synchronized.
- No parity/CRC, no FIFOs, no DMA.
