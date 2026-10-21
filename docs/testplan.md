# Testplan

Spec: `docs/spi_reg_slave_spec.md` · Feature IDs (F-01 to F-12) refer to section 9 of the spec.

## 1. Scope and goals

- **DUT:** `spi_reg_slave`, an SPI mode 0 slave exposing a register file over SPI.
- **Verified:** register map behavior, access types (RW, RO, W1C, self-clearing write-only, volatile), frame counter and threshold, illegal accesses, frame validity, `irq_o`, SPI timing limits.
- **Out of scope:** see section 9 of the spec (tri-stating `miso`, other SPI modes, burst access, multi-slave contention).

## 2. Environment summary

| Component | Role |
|---|---|
| SPI agent | Drives and monitors SPI frames. Also the RAL bus agent. |
| RAL block + adapter | Register model; `reg2bus`/`bus2reg` convert register operations into 16-bit SPI frames. |
| Predictor | _TBD: explicit (monitor-driven) or auto-predict. See section 6._ |
| Scoreboard | SPI-level checks (`miso` shape, frame validity), reference frame counter, `irq_o`. |
| Coverage | Functional coverage collector plus RAL built-in coverage. |

## 3. Feature → test matrix

| Feature | Test | Stimulus | Checking | Coverage | Pri | Status |
|---|---|---|---|---|---|---|
| F-01 reset values | `spi_reg_hw_reset_test` | `uvm_reg_hw_reset_seq` after reset, then reset mid-run and repeat | RAL mirror vs read, `irq_o` = 0 | reset covered per register | P0 | |
| F-02 RW fields, reserved bits | `spi_reg_bit_bash_test` | `uvm_reg_bit_bash_seq` plus directed writes of 1s to reserved bits | RAL read-back | each RW field written 0 and 1 | P0 | |
| F-03 RO writes | `spi_illegal_access_test` | write `ID` and `FRAME_CNT` | value unchanged, `ERR` = 1 | write-to-RO bin per register | P0 | |
| F-04 undefined addresses | `spi_illegal_access_test` | read and write 0x06 to 0x7F | read = 0x00, `ERR` = 1 | address bins (valid, boundary 0x06, 0x7F) | P1 | |
| F-05 W1C | `spi_w1c_test` | write 0, write 1, set and clear in the same frame | `STATUS` bit-level | W1C write value × current bit state | P0 | |
| F-06 `CNT_CLR` | `spi_counter_test` | write `CTRL.CNT_CLR` while `EN`=1 and `EN`=0 | counter = 0, `CNT_CLR` reads 0 | `CNT_CLR` × `EN` cross | P0 | |
| F-07 counting rules | `spi_counter_test` | `EN` timing, mixed R/W frames, run to 0xFF | scoreboard reference counter | counter bins: 0, mid, 0xFE, 0xFF | P0 | |
| F-08 threshold | `spi_counter_test` | `THRESH` = 0x00, 0x01, 0xFF, plus a change mid-count | `THRESH_HIT` timing | `THRESH` edge-value bins | P1 | |
| F-09 irq | `spi_irq_test` | `IRQ_EN` × `THRESH_HIT` combinations | `irq_o` = `IRQ_EN` & `THRESH_HIT` at every frame end | 2×2 cross | P1 | |
| F-10 abort / long frames | `spi_frame_len_test` | 1–15 and 17–24 SCLK cycles | no state change (aborted) / first 16 bits used (long) | length bins | P1 | |
| F-11 `miso` shape | any read test | n/a | monitor/scoreboard: `miso` = 0 in the command phase and on write frames | covered by all reads | P0 | |
| F-12 timing limits | `spi_timing_test` | min SCLK high/low, min `cs_n` high | same checks as above | timing config bins | P2 | |

## 4. Coverage plan

- **Functional:** register address × R/W, address × data type (0x00, 0xFF, random), plus the crosses listed in the matrix.
- **RAL:** the register model's built-in coverage (`UVM_CVR_REG_BITS`, `UVM_CVR_ADDR_MAP`).
- **Code:** line/toggle coverage as a sanity check only.

## 5. Priorities and exit criteria

- All P0 tests pass with no scoreboard or RAL mismatches.
- Functional coverage for P0 features is at 100%; any holes are explained.
- A short list of bugs or spec ambiguities found during verification.

## 6. Decisions to document

- **Volatile and write-only fields:** record how each is modeled in RAL and why.
  - `FRAME_CNT`: volatile.
  - `CTRL.CNT_CLR`: `WO`, or `RW` + volatile (choose and justify).
  - Exclude `FRAME_CNT` from the built-in sequences that would break on it, using the `NO_REG_BIT_BASH_TEST` and `NO_REG_HW_RESET_TEST` resource attributes as needed, and cover it with directed tests instead.
  - Check how the built-in sequences treat WO/volatile fields against the UVM reference for the simulator version in use.
- **Predictor choice:** explicit predictor fed by the monitor, or auto-predict. The model's mirror of `FRAME_CNT` needs a defined update rule: every valid frame counts, with `EN` taken from before the frame.
- **Backdoor:** list which tests use backdoor access (`peek`/`poke`) and which are frontdoor only. HDL paths are in section 8 of the spec.
