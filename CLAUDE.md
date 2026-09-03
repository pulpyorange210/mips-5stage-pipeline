# CLAUDE.md

Context for Claude Code working in this repository.

## Project

A 5-stage pipelined MIPS processor in Verilog-2005 with a forwarding unit and a hazard detection unit. Supports five instructions: `lw`, `sw`, `j`, `xor`, `ori`.

This started as a university assignment. It is being turned into a portfolio artifact: fixed, verified, and published. **The value of this repo is verification rigour, not instruction count.** Do not propose adding instructions, branches, caches, or new features.

**Hard deadline: 10 September.** Prefer a small correct change over a large ambitious one.

## Toolchain

| Tool | Version | Purpose |
|---|---|---|
| `iverilog` | ≥ 11.0 | Simulation (4-state, models `X`/`Z`) |
| `verilator` | ≥ 5.0 | **Lint only** — `--lint-only`. Do not build a C++ sim harness |
| `gtkwave` | ≥ 3.3 | VCD viewing (manual, not in CI) |
| `make` | any | All entry points |
| `yosys` | ≥ 0.36 | Optional gate count for the README |

Install: `sudo apt install -y iverilog verilator gtkwave make git yosys`

Everything runs in WSL Ubuntu 22.04. Its `iverilog` is 11.0, which is what apt carries on
jammy and is fine here: the RTL is compiled `-g2005`, and nothing in the test suite depends
on a 12.x feature. Do not spend time building 12.x from source.

Never introduce a tool outside this list without asking. No commercial EDA, no cocotb, no Python dependencies.

## Commands

```bash
make lint     # verilator --lint-only -Wall -Wno-DECLFILENAME on all rtl/
make test     # build + run every testbench, print PASS/FAIL, exit non-zero on failure
make wave     # run the default TB and open the VCD in GTKWave
make synth    # optional: yosys generic synth, print cell count
make clean
```

`make test` must exit non-zero when a test fails. Icarus `vvp` returns 0 even after `$display("TEST FAILED")`, so the Makefile greps the log:

```make
test: $(SIMS)
	@for s in $(SIMS); do \
	  ./$$s | tee $$s.log; \
	  grep -q "TEST PASSED" $$s.log || { echo "FAIL: $$s"; exit 1; }; \
	done
```

## Layout

```
rtl/                    one module per file, filename == module name
  processor.v           top level, stage wiring, forwarding muxes, PC logic
  instruction_memory.v
  register_file.v
  data_memory.v
  control_unit.v
  alu.v
  sign_extend.v
  if_id.v  id_ex.v  ex_mem.v  mem_wb.v
  forwarding_unit.v
  hazard_detection_unit.v
tb/
  tb_processor.v        self-checking, top-level
  programs/*.hex        assembled test programs
docs/
  design.md             datapath diagram, control table, hazard derivations
.github/workflows/ci.yml
```

One module per file matters: Verilator's `DECLFILENAME` check expects it, and the current submission has multiple modules per file plus a duplicate `IF_ID`.

## Coding Conventions

- **Verilog-2005.** `iverilog -g2005`. No SystemVerilog constructs in `rtl/` — no `logic`, no `always_ff`, no interfaces. The testbench may use `-g2012` if needed.
- Sequential logic: `always @(posedge CLK)` with **non-blocking** assignments (`<=`).
- Combinational logic: `always @(*)` with **blocking** assignments (`=`), or `assign`.
- Never mix blocking and non-blocking in the same `always` block.
- Every `always @(*)` must assign every output on every path — default-assign at the top of the block. Missing assignments infer latches.
- Explicit bit widths on all literals: `32'd0`, not `0`.
- Named port connections on all instantiations: `.CLK(CLK)`, never positional.
- Lowercase `endmodule`. Verilog is case-sensitive and the original has `Endmodule` in three places.
- Active-high synchronous reset named `reset`, clock named `CLK`.
- Comment the *why*, not the *what*. `// EX hazard takes priority over MEM hazard` is useful; `// assign the result` is not.

## Known Bugs — Fix in This Order

**1. Compile blockers.** Trailing comma in `processor` port list (`input wire reset,);`); `Endmodule` capitalised in `data_memory`, `EX_MEM`, and one `IF_ID`; `IF_ID` defined twice — delete the duplicate.

**2. Register file lacks write-first forwarding. This is the important one.**
The register file writes on `posedge` and reads combinationally, so a producer in WB and a consumer in ID on the same edge causes ID/EX to latch stale data. The forwarding unit cannot fix it — by the next cycle the producer has left MEM/WB. Fix:

```verilog
assign rs_data = (rs_addr == 5'd0)                      ? 32'd0 :
                 (reg_write && (write_addr == rs_addr)) ? write_data :
                                                          registers[rs_addr];
```

**Write the failing regression test before the fix**, confirm it fails, then fix it and confirm it passes. Do not fix and test in one commit — the failing run is the evidence.

**3. Hazard unit stalls spuriously.** It fires whenever `id_ex_rt` matches, ignoring whether the consumer actually reads that register. Add a per-opcode read mask (`lw` and `ori` read rs only; `sw` and `xor` read both; `j` reads neither) and guard on `id_ex_rt != 0`.

**4. Dead nets.** Remove `alu_zero` and `id_ex_pc_plus4` — Verilator flags these two as unused.

Do **not** remove `ex_mem_mem_read`. An earlier draft of this list had it, wrongly. It drives
`dmem.mem_read`, and the testbench's read/write invariant reads it; Verilator does not flag it.

**5. Instruction memory uses `initial`, not reset.** The assignment specified reset-time initialisation. Note the deviation in the README; changing it is optional.

## Testbench Requirements

Every testbench must:
- Generate a 10ns-period clock, assert `reset` for 2 cycles
- Run a fixed number of cycles, then **compare** final register and memory state against hardcoded expected values
- Increment an `errors` counter per mismatch, and print `TEST PASSED` or `TEST FAILED` — those exact strings, since the Makefile greps for them
- `$dumpfile`/`$dumpvars` for VCD
- Have a timeout that calls `$finish` so CI can't hang

Required test programs, one per hazard class:

| Test | What it proves |
|---|---|
| `original.hex` | The assignment program, 12 cycles, CPI 2 |
| `raw_dist1.hex` | EX→EX forwarding (`ForwardRs = 01`) |
| `raw_dist2.hex` | MEM→EX forwarding (`ForwardRs = 10`) |
| `raw_dist3.hex` | **Write-first forwarding — fails before the fix** |
| `load_use.hex` | One-cycle interlock stall |
| `r0_write.hex` | Writes to `r0` are discarded |
| `jump_flush.hex` | The instruction after `j` is squashed |

### Test Design Constraints

End-state checking only catches bugs whose effects are still architecturally visible when the run stops. Write test programs so the symptom **survives to the end**:

- **Never overwrite an observed register.** If a hazard test's whole point is that `r5` might receive a stale value, nothing after that instruction may write `r5`. A test where the wrong value is later clobbered passes on a broken core and proves nothing.
- **One destination register per hazard under test.** Don't reuse destinations across the checks in a single program.
- **Sink observed values into distinct DMEM words** where practical, so the final memory image is itself the evidence.
- **`raw_dist3.hex` specifically:** the producer must be exactly three instructions ahead of the consumer, with no intervening jump or stall that changes the spacing, and the consumer's destination must remain untouched afterward. Before committing the fix, run this test against the *unfixed* register file and confirm it reports `TEST FAILED`. If it passes, the test is wrong, not the RTL.

Every test program needs a comment header stating the hazard it targets, the expected final state, and which register or memory word carries the evidence.

### Continuous Invariant Assertions

Add these to `tb/tb_processor.v` alongside the end-state checks. They fire the moment they're violated rather than waiting for the run to finish, so a failure points at the offending cycle instead of a wrong number an unknown number of cycles later. Wrap them in a `check_invariants` task called every clock edge after reset deasserts, and increment the same `errors` counter.

```verilog
// Architectural: r0 is hardwired zero
if (dut.regfile.registers[0] !== 32'd0) ...

// Read through the port path too — the r0 bypass must hold on both reads
if (dut.rs_data_id !== 32'd0 && dut.if_id_rs == 5'd0) ...

// Control: the data memory can never be read and written in the same cycle
if (dut.ex_mem_mem_read && dut.ex_mem_mem_write) ...

// Alignment: PC is always word-aligned
if (dut.pc[1:0] !== 2'b00) ...

// X-propagation: no unknowns on control or PC once reset is deasserted
if (^{dut.pc, dut.ctrl_reg_write, dut.ctrl_mem_write} === 1'bx) ...
```

Use case-inequality (`!==`, `===`) in all invariant checks, not `!=`/`==`. The `!=` operator returns `X` when either operand contains `X`, which an `if` treats as false — so an ordinary comparison silently passes on exactly the uninitialised-signal bug you're trying to catch.

**These invariants are the reason `make test` uses Icarus, not Verilator.** Icarus is a 4-state simulator: it models `X` (unknown) and `Z` (high-impedance) and propagates them, so an uninitialised pipeline register shows up. Verilator is 2-state — it silently treats `X` as 0, and the bug disappears. Verilator stays in this project as a linter only.

When an invariant fires, print the simulation time, the invariant name, and the offending value. A bare `TEST FAILED` with no location wastes the debug time the assertions were supposed to save.

## Boundaries

**Claude Code should generate:** Makefile, CI workflow, testbench harness and boilerplate, test program assembly and hex, README structure, docs scaffolding, mechanical fixes (items 1 and 4 above).

**The repo owner writes by hand:** the forwarding unit, the hazard detection unit, the register file write-first logic, and the jump/flush control. These are the parts an interviewer will ask them to derive on a whiteboard. If asked to write them, produce a commented skeleton with the conditions left as `TODO` and explain the reasoning instead.

**Commit style:** small, incremental, real messages (`fix: register file write-first forwarding for distance-3 RAW`). Do not squash the whole project into a handful of commits — commit history is part of what this repo demonstrates.

**When a test fails:** read the VCD and reason about the failing cycle before changing RTL. Do not loosen an assertion to make a test pass.

**Never modify the DUT to make it observable.** The testbench reaches internal state through hierarchical references — `dut.regfile.registers[3]`, `dut.dmem.mem[0]`, `dut.pc`. Do not add debug output ports, status flags, or `$display` calls to anything under `rtl/`. Changing a design in order to watch it is a real anti-pattern and is visible in the diff.
