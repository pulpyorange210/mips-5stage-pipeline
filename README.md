# 5-stage pipelined MIPS core

[![ci](https://github.com/pulpyorange210/mips-5stage-pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/pulpyorange210/mips-5stage-pipeline/actions/workflows/ci.yml)

A five-stage pipelined MIPS processor in Verilog-2005, supporting `lw`, `sw`,
`j`, `xor` and `ori`, with a forwarding unit, a load-use interlock, and
write-first forwarding in the register file. It started as a university course
assignment. The submitted version did not compile — a trailing comma in a port
list, three capitalised `Endmodule`s, and a duplicated module — and underneath
those it had a real pipeline bug: a distance-3 read-after-write returned stale
data. Since then it has been split one module per file, fixed, put under a
linter and a self-checking test suite, and wired to CI. It is a small core; the
work worth looking at is the verification, not the instruction count.

---

## Quick start

| Tool | Local | CI (pinned) | Used for |
|---|---|---|---|
| `iverilog` | 11.0 | `12.0-2build2` | Simulation. 4-state, so `X`/`Z` propagate. |
| `verilator` | 5.050 | `5.020-1` | Lint only, `--lint-only`. |
| `yosys` | 0.9 | – | Optional RTL cell count. |
| `gtkwave` | 3.3 | – | Viewing VCDs by hand. |
| `make` | any | – | Every entry point. |

```bash
sudo apt-get install -y iverilog verilator gtkwave make git yosys
git clone https://github.com/pulpyorange210/mips-5stage-pipeline
cd mips-5stage-pipeline
make check
```

`make check` runs lint, the invariant selftest and all eight test programs, and is
the whole story — a clean clone reproduces the green CI run from that one
command.

| Target | What it does |
|---|---|
| `make lint` | `verilator --lint-only -Wall -Wno-DECLFILENAME`. Exits 0 with no warnings. |
| `make test` | Builds and runs all eight programs, greps each log for `TEST PASSED`. |
| `make selftest` | Proves each continuous invariant actually fires. Excluded from `make test`. |
| `make check` | `lint` + `selftest` + `test`. |
| `make wave` | Runs one program and opens its VCD. `WAVE_VIEWER` and `WAVE_PROGRAM` are overridable. |
| `make synth` | Per-module RTL cell count via yosys. Not part of `check`. |
| `make clean` | Removes `build/`. |

`vvp` exits 0 even after a testbench prints `TEST FAILED`, so `make test` takes
its verdict from the log rather than the simulator's exit status. It runs every
program even after one fails, then exits non-zero at the end. The exit code was
checked in both directions by stubbing the simulator, not by reading the recipe.

---

## Architecture

Five stages — IF, ID, EX, MEM, WB — separated by four pipeline registers
(`IF_ID`, `ID_EX`, `EX_MEM`, `MEM_WB`), one module per file under `rtl/`.

Forwarding into EX comes from two places: the `EX/MEM` register for the
instruction one ahead (`ForwardRs = 01`) and `MEM/WB` for two ahead
(`ForwardRs = 10`), with EX taking priority. A third path sits in the register
file itself, covering the case neither of those can reach — see
[the write-first bug](#1-register-file-write-first-forwarding-78f9764).

Jumps resolve in **ID**, not EX. `jump_taken` is combinational from the decoded
opcode, so it is high for exactly the cycle `j` occupies ID. By then the next
instruction is already in IF, and there is no delay slot, so `IF/ID` is flushed
on that edge and the fetched instruction is discarded before it can decode. A
taken jump costs exactly one squashed slot.

### Instruction set

All five are 32-bit, and the core implements nothing else; any other opcode
decodes to an architectural no-op.

| Instruction | Format | opcode | funct | Operation |
|---|---|---|---|---|
| `lw rt, off(rs)`  | I | `100011` | – | `rt <- MEM[rs + sext(off)]` |
| `sw rt, off(rs)`  | I | `101011` | – | `MEM[rs + sext(off)] <- rt` |
| `ori rt, rs, imm` | I | `001101` | – | `rt <- rs \| zext(imm)` |
| `xor rd, rs, rt`  | R | `000000` | `100110` | `rd <- rs ^ rt` |
| `j target`        | J | `000010` | – | `PC <- {PC+4[31:28], target, 2'b00}` |

### Control signals

| Instruction | RegDst | ALUSrc | ExtOp | MemToReg | RegWrite | MemRead | MemWrite | ALUOp | Jump |
|---|---|---|---|---|---|---|---|---|---|
| `lw`  | 0 | 1 | 1 | 1 | 1 | 1 | 0 | `00` | 0 |
| `sw`  | 0 | 1 | 1 | 0 | 0 | 0 | 1 | `00` | 0 |
| `j`   | 0 | 0 | – | 0 | 0 | 0 | 0 | `00` | 1 |
| `ori` | 0 | 1 | **0** | 0 | 1 | 0 | 0 | `10` | 0 |
| `xor` | 1 | 0 | – | 0 | 1 | 0 | 0 | `11` | 0 |
| other | 0 | 0 | 0 | 0 | 0 | 0 | 0 | `00` | 0 |

`ALUOp` reaches the ALU unencoded: `00` add, `10` or, `11` xor. There is no
separate ALU control unit — see [Known limitations](#known-limitations).

`ExtOp` widens the 16-bit immediate: 1 sign-extends, 0 zero-extends, and is
marked – where `ALUSrc` is 0 and the immediate never reaches the ALU. MIPS
decides this by opcode class, not by format: `lw`, `sw` and `ori` are all
I-type, so nothing in the encoding distinguishes them and it has to be decoded.
See [the `ori` bug](#5-ori-sign-extended-its-immediate-c83eb3e).

**[docs/design.md](docs/design.md) has the datapath diagram and the full
derivations** for forwarding, the interlock, jump/flush and write-first. They
are not repeated here.

---

## Verification

Four layers, each catching something the others cannot.

**1. Lint.** `verilator --lint-only -Wall`, clean, no blanket `-Wno-` flags.
Codes actually hit and dealt with during the work: `CASEINCOMPLETE`,
`UNUSEDSIGNAL`, `UNUSEDLOOP`, `PINCONNECTEMPTY`, `PINMISSING`, `BADVLTPRAGMA`.
The only command-line suppression is `DECLFILENAME`, because the pipeline
registers are named `IF_ID`/`ID_EX`/`EX_MEM`/`MEM_WB` in lowercase files.

**2. Self-checking test programs**, one per hazard class, in `tb/programs/`.
One testbench serves all eight, parameterised at compile time over the hex path
and a program id selecting a block of hardcoded expected values.

| Program | Proves |
|---|---|
| `raw_dist1.hex` | EX→EX forwarding, `ForwardRs = 01` |
| `raw_dist2.hex` | MEM→EX forwarding, `ForwardRs = 10` |
| `raw_dist3.hex` | Register-file write-first, distance-3 RAW |
| `load_use.hex` | One-cycle load-use interlock |
| `r0_write.hex` | Writes to `r0` discarded on all three paths |
| `jump_flush.hex` | The instruction after `j` is squashed |
| `false_stall.hex` | The interlock does **not** fire when there is no dependency |
| `ori_zeroext.hex` | `ori` zero-extends its immediate |

Each has a positive control proving it ran, so a zero in the evidence register
cannot be confused with a program that never executed, and an independent
witness in data memory. The witness is real evidence rather than a restatement:
reset leaves dmem word 0 at `0x00000014`, so a store landing `0` there proves
the store executed **and** carried a zero — which re-reading the same register
cannot distinguish.

**3. Continuous invariants** (`tb/invariants.vh`), checked every cycle of every
program rather than only at the end, so a violation names the cycle it happened
in: `r0` is hardwired zero; the `r0` bypass holds on the read port too; data
memory is never read and written in the same cycle; the PC is word-aligned; no
`X` on the PC or control signals after reset. All use `===`/`!==` — `==` returns
`X` when either side is `X`, and `if` treats that as false, which would pass
silently on exactly the uninitialised-signal bug these exist to catch.

This is why `make test` runs on Icarus rather than Verilator. Icarus is 4-state
and propagates `X`; Verilator is 2-state and would quietly read it as 0.

**4. An invariant selftest** (`make selftest`). An assertion that cannot fail is
worse than no assertion — it reads like coverage and provides none. The selftest
corrupts the state each invariant polices and asserts the invariant notices, and
additionally that *no other* invariant fired. That second half is what earns its
keep: a check that fires on everything is as useless as one that fires on
nothing. It includes the same `invariants.vh` the real runs use, so it tests the
live code rather than a copy.

### Mutation testing

Eight passing tests say nothing about coverage. To find out whether the suite
actually detects anything, each mechanism was broken in a scratch tree:

```
EX->EX forwarding disabled     caught by: raw_dist1
MEM->EX forwarding disabled    caught by: raw_dist2 load_use
load-use interlock disabled    caught by: load_use
forwarding r0 guard removed    caught by: r0_write
write-first ahead of r0 test   caught by: r0_write
write-first bypass removed     caught by: raw_dist3
IF/ID jump flush disabled      caught by: jump_flush
read mask removed              caught by: false_stall
id_ex_rt != 0 guard removed    caught by: false_stall
ExtOp forced to sign-extend    caught by: ori_zeroext
```

No mutation goes undetected, and each is caught by the test written for it.
MEM forwarding appearing twice is correct rather than sloppy — `load_use`
depends on it to deliver the loaded word after the interlock resolves.

**The harness checks that each mutation applied.** It diffs the RTL after
mutating and refuses to report a result if nothing changed. This is not
belt-and-braces: a substitution that silently fails to match produces a row
identical to a mutation nothing caught. That happened — a pattern ending in
`"&& "` did not match a line ending at `"&&"` before a newline, and the run
invented a coverage gap that did not exist. The same failure could as easily
hide a real one behind a green row.

### Behavioural counters

End-state checking is structurally blind to anything that leaves architectural
state correct. A **spurious stall** is the clearest case: it costs a cycle and
changes no register, so a suite that only compares final state cannot see it.

The testbench therefore counts cycles where `pc_write` is low, where
`jump_taken` is high, and where `ForwardRs` is `01` or `10`. `load_use` asserts
exactly one stall, `jump_flush` exactly one flush, and **every other program
asserts zero stalls** — including `false_stall`, which contains two loads and
must still never stall. `raw_dist1` and `raw_dist2` additionally assert their
forwarding path was genuinely exercised, so neither can pass on a value that
happened to be right for another reason.

This is not a hypothetical safety net. It is the only thing that caught
[the spurious-stall bug](#4-spurious-load-use-stalls-c59c051): in that failing
run every register and memory check passed, and the stall count was the single
mismatch.

That makes the timing claims in the program headers checkable rather than
prose. `load_use` is 8 instructions + 4 cycles of pipeline fill + 1 stall = 13
cycles; `jump_flush` is 11 executed instructions + 4 fill + 1 squashed slot = 16.

---

## Bugs found and fixed

### 1. Register file write-first forwarding (`78f9764`)

The one that mattered. Writes land on `posedge`, reads are combinational, and
`ID/EX` samples the read on that same edge. When a producer is in WB during the
same cycle a consumer is in ID — exactly three instructions apart — the consumer
latched the value from *before* the write.

```
cycle    1    2    3    4    5
producer IF   ID   EX  MEM   WB     writes r5 on the edge ending cycle 5
+1            IF   ID   EX  MEM
+2                 IF   ID   EX
+3 consumer          IF   ID        reads r5 on that same edge
```

**Why forwarding structurally cannot reach it.** Forwarding compares against
`ex_mem_rd` and `mem_wb_rd` while the consumer is in EX. By the time this
consumer reaches EX in cycle 6, the producer has already left MEM/WB — it
retired at the end of cycle 5. Neither register holds it any more, so both
selects read `00` and the EX stage takes the stale `ID/EX` value. No amount of
logic in the forwarding unit helps once the producer is gone. The register file
is the only thing still holding the value at the instant of the read.

**Why the existing tests missed it.** There weren't any. The submission had no
testbench, and the assignment program never places a producer and consumer
exactly three apart, so running it produced correct output on a broken core.

**How it was caught.** By writing `raw_dist3.hex` first and running it against
the unfixed register file. It reported `TEST FAILED`, and that failing run is
committed on its own at `a47ce17` — the commit before the fix — with the
mismatches in the message. That commit is deliberately red.

**The fix**, on both ports:

```verilog
assign rs_data = (rs_addr == 5'd0)                      ? 32'd0      :
                 (reg_write && (write_addr == rs_addr)) ? write_data :
                                                          registers[rs_addr];
```

**Why `rt` too, not just `rs`.** `sw` takes its store data through `rt`, so a
distance-3 store would otherwise write a stale word to memory — a bug that never
shows up in a register dump.

**Why the `r0` test must come first.** The write port is already guarded by
`write_addr != 0`, so it looks like the ordering is free. It is not: when the
discarded write targets `r0` and the read is also of `r0`, the bypass condition
`reg_write && write_addr == rs_addr` is **true**, both being zero. A bypass
placed ahead of the `r0` test would return `write_data` on a read of `r0` and
break the hardwired zero. `r0_write.hex` covers exactly this at distance 3, and
the mutation table confirms it: swap those two terms and `r0_write` is the only
test that fails.

**Why a bypass and not a negedge write.** Writing on the falling edge would also
close the window, and is a smaller diff. It was rejected because it puts the
register file on a different clock edge from the rest of the pipeline, halves
the time available for the write path, and makes the design depend on duty
cycle. It solves a logical problem with a timing trick. The bypass is a mux and
costs nothing at the boundary.

**Proof:** `raw_dist3` went `TEST FAILED` → `TEST PASSED` across `78f9764`, with
the diff confined to `rtl/register_file.v` and no testbench change. Reverting the
bypass still fails that test today.

### 2. Compile blockers (`0de6afe`)

Three trivial ones, all fatal: a trailing comma after the last port in
`processor`, `Endmodule` capitalised in `data_memory`, `EX_MEM` and `IF_ID`
(Verilog is case-sensitive, so the parser never saw a module end), and `IF_ID`
defined twice. Before: `iverilog` exits 7. After: exits 0, no warnings. The
duplicate was resolved by the one-module-per-file split in the import.

### 3. Dead net removal (`75110bd`)

`alu_zero` and `id_ex_pc_plus4` were unreferenced. Removing the wires left
dangling pins, and Verilator rejects that either way — `PINCONNECTEMPTY` for an
empty connection, `PINMISSING` for an omitted one, both verified. A pragma would
have silenced the complaint while keeping the dead logic, so the **ports** went
too: `alu`'s `zero` output and its 32-bit comparator, and `ID_EX`'s
`pc_plus4_in`/`pc_plus4_out` along with the 32-bit pipeline register between
them. That is real hardware, not tidier source; `make synth` shows `ID_EX` going
29 → 27 RTL cells and `alu` 8 → 7 across that commit.

**The linter overruled the notes.** The working list of dead code named a third
net, `ex_mem_mem_read`. It was wrong. That signal drives `dmem.mem_read` and is
read by the invariant asserting data memory is never read and written in the same
cycle — removing it would have deleted the signal *and* disarmed the check that
would have caught it. Verilator never flagged it; only the two above appeared in
`UNUSEDSIGNAL` output, and only those two were removed. A hand-written list of
dead code is a hypothesis; the linter is the authority.

### 4. Spurious load-use stalls (`c59c051`)

The interlock compared `id_ex_rt` against `if_id_rs` and `if_id_rt` without
asking whether the opcode reads them. `rs` and `rt` are only bit positions;
whether either is a *source* is an opcode question. `lw` and `ori` use `rt` as
their **destination**, and `j`'s `rs`/`rt` bits are part of the 26-bit target
and not register numbers at all. So a load followed by an instruction that
*writes* the loaded register — a WAW, which an in-order pipeline resolves for
free — stalled a cycle waiting for a value nobody reads.

**Why the existing tests missed it, and why this one is different.** A spurious
stall is architecturally invisible. It delays and never corrupts, so every
register and every memory word ends up exactly as it would without it. The
entire six-program suite passed, and would keep passing, because end-state
checking is structurally incapable of seeing this. Look at the failing run in
`6e040ec`: `r4`, `r5`, `dmem[4]` and `dmem[0]` all pass, and the single
mismatch is the stall counter.

**How it was caught.** `false_stall.hex`, written first and committed red at
`6e040ec`, asserting zero stalls against the counter added in `fd35c24`.

**The fix.** `ReadsRs`/`ReadsRt` decoded in `control_unit` and routed to the
hazard unit, plus an `id_ex_rt != 0` guard:

```verilog
if (id_ex_mem_read && (id_ex_rt != 5'd0) &&
    ((if_id_reads_rs && (id_ex_rt == if_id_rs)) ||
     (if_id_reads_rt && (id_ex_rt == if_id_rt))))
```

**Why the decode lives in `control_unit`.** Giving the hazard unit its own
opcode input and letting it decode for itself keeps the hazard logic
self-contained, which has some appeal. It was rejected because it creates a
second decoder over the same instruction set — add a sixth instruction, update
one table, and the pipeline stalls correctly while the datapath does something
else. Nothing catches that. In `control_unit` the read mask is set by the same
`case` arms that set `RegDst` and `ALUSrc`, so getting it wrong is the same
visible mistake as getting `ALUSrc` wrong.

**Why both guards.** They cover different cases and neither substitutes for the
other. The read mask does not cover a load into `r0`: a consumer reading `r0`
really does read `rs`, and `rs` really does equal the load's destination, both
being zero, so the masked comparison is still true — but the write was
discarded, so there is nothing to wait for. `false_stall.hex` carries one case
for each, added at `fa631e0` after mutation testing showed the zero guard was
uncovered.

**Proof:** `false_stall` went `TEST FAILED` → `TEST PASSED` across `c59c051`
with every other stall and flush count unchanged — `load_use` still stalls
exactly once, `jump_flush` still flushes once, the other five still stall zero
times. Both guards are independently mutation-covered.

### 5. `ori` sign-extended its immediate (`c83eb3e`)

Every immediate went through `sign_extend`, so `ori r7, r0, 0x8000` produced
`0xFFFF8000` where MIPS specifies `0x00008000`. A wrong architectural result
for a legal instruction — not a stall, not a timing cost, a wrong number in a
register.

MIPS decides extension by **opcode class, not instruction format**. The logical
immediates zero-extend; the arithmetic and memory ones sign-extend. `lw`, `sw`
and `ori` are all I-type with a 16-bit immediate, so nothing in the encoding
distinguishes them — which is exactly why `ExtOp` has to be a decoded control
signal rather than something derived from the format bits.

**Why the existing tests missed it.** Every earlier program kept its immediates
below `0x8000`, which was deliberate — chosen so this bug could not contaminate
the hazard tests — but it also meant nothing exercised it.

**The subtlety that makes the test able to fail at all.** The two extensions
differ *only* in bits [31:16], filled from a copy of bit 15. For any immediate
with bit 15 clear they are bit-for-bit identical, so a test written with a
convenient value like `0x0044` passes on broken RTL and proves nothing. The
evidence immediate is `0x8000` — bit 15 set, everything else clear — and the
header says so explicitly, because clearing that bit would not weaken the test,
it would silently disable it while leaving a green tick behind.

**Where the evidence had to come from.** Not a load or store offset. The memory
path indexes on `addr[7:0]`, and the two extensions agree on the low sixteen
bits by construction, so no `lw`/`sw` offset can ever tell them apart. Only the
ALU result of a logical immediate can.

**How it was caught.** `ori_zeroext.hex`, committed red at `48e914a`. The
positive control does real work here: `r8` is an `ori` with bit 15 *clear*,
deliberately insensitive to the bug, so it passes either way. The failing run
shows `r7` and its memory witness wrong while `r8` and its witness are right —
isolating the fault to the extension rather than `ori` generally, the ALU OR
path, or a program that never ran.

**The fix.** `ExtOp` decoded in `control_unit` alongside `ALUSrc` and `RegDst`,
selecting between `sign_extend`'s output and a zero-extended immediate formed
in the datapath. `sign_extend` keeps its interface and stays a pure
sign-extender: a module called `sign_extend` that sometimes zero-extends is a
worse thing to leave behind than one extra mux, and leaving it alone means
`lw`/`sw` cannot be perturbed. The now-inaccurate `sign_ext_imm` signals
through ID/EX were renamed `ext_imm` in the same commit, since a name that
contradicts its value is precisely what misleads the next reader.

**Proof:** red at `48e914a`, green at `c83eb3e`, with all eight programs passing
and every stall and flush count unchanged. Mutation testing confirms reverting
`ExtOp` to a hard sign-extend is caught by `ori_zeroext` and nothing else.

### Still open

None of the five known bugs remain. What is left are the design limitations
below, which are properties of a deliberately small core rather than defects.

---

## Design decisions

**Memories left with async reads and array resets.** `instruction_memory` and
`data_memory` read combinationally and clear their arrays on reset. Both are
wrong for real hardware (see [Known limitations](#known-limitations)) and both
were deliberately left alone. Fixing them properly is not a patch — synchronous
memory changes the pipeline's timing contract, which stage sees data when, and
therefore the hazard logic that the entire test suite is built around. That
belongs in a core designed around synchronous memory from the start, not
retrofitted into one whose value is a verified hazard path. The scope was held
to the bugs and the verification.

**Targeted lint pragmas over blanket flags.** Every suppression sits on the
exact line with a comment saying why it is safe, rather than a `-Wno-` on the
command line. Three exist: unused upper address bits in each memory, and the
`data_memory` reset loop, which a 2-state tool can prove redundant because it
zero-initialises anyway — but Icarus is 4-state, where that loop is what makes
an unwritten word read `0` instead of `X`. A blanket flag would have hidden all
three reasons and any future fourth.

**Pinned toolchain versions, with a concrete reason.** CI initially ran
`ubuntu-latest` and went red on a lint pragma. `UNUSEDLOOP` was introduced in
Verilator **5.028**; Ubuntu 24.04 ships **5.020**. An unrecognised warning name
is not ignored — it raises `BADVLTPRAGMA` and fails the build — so a pragma
written to *suppress* a warning became the thing that broke CI, on a runner
where the warning did not exist in the first place. Fixed by naming the
long-standing `UNUSED` meta-warning instead, and by pinning `ubuntu-24.04` plus
exact package versions. An unpinned image means the lint gate changes shape when
the image rolls and nothing in the repo changed.

**The history contains a commit that does not compile and one that fails.** The
first commit imports the original submission verbatim, trailing comma and all;
`a47ce17` adds `raw_dist3` and reports `TEST FAILED`. Both are deliberate and
both say so in their messages. A test written after the fix proves only that it
agrees with the code. The failing run is the evidence that the test can detect
the bug at all, and squashing it away would delete the only proof the suite
works.

**AI tooling.** Claude Code was used for the test harness, Makefile, CI
workflow, test-program scaffolding and documentation. Design decisions, debugging
and the hazard-path RTL were owner-directed, and generated RTL in that path was
reviewed line by line before commit.

---

## Known limitations

Real, not nitpicks. Each is what it costs and what would change.

**Asynchronous memory reads.** Both memories read combinationally. No SRAM
behaves this way. On ASIC or FPGA this synthesises into a large mux tree — 256
bytes and 64 words respectively — and is almost certainly the critical path.
*Would change:* synchronous reads with registered outputs, which moves the load
data one stage later and reworks the interlock accordingly.

**Memory arrays are reset.** `data_memory` resets 256×8 bits and
`register_file` 32×32, so reset clears 3,072 flops. Real designs do not reset
arrays — the reset tree alone would be substantial, and memory contents are
established by initialisation or by the program. *Would change:* drop the array
resets and let the testbench establish known contents.

**ROM initialised in an `initial` block.** `instruction_memory` fills its ROM in
`initial` rather than from `$readmemh`, and the assignment asked for reset-time
initialisation. It is not synthesisable as intended and the tests work around it
— the testbench clears the ROM and loads the program by hierarchical reference
before the first fetch. *Would change:* `$readmemh` from a parameterised path.

**Five instructions, and the control path does not scale.** No branches, no
shifts, no arithmetic beyond add. There is no ALU control unit: `ALUOp` wires
straight from the control unit into the ALU as the operation itself. That works
for three operations and collapses immediately on a fourth — the standard
two-level opcode/funct decode exists precisely because this does not extend.
Adding branches would also mean a comparator and a resolution stage, which is
why `alu.zero` was removed rather than kept "for later".

**No external interface.** The top level has only `CLK` and `reset`. Memories
are internal, so nothing is observable from outside and the testbench reaches in
by hierarchical reference. A side effect: synthesising with `-top processor`
reports **zero cells**, because every cell is unobservable and the optimiser
removes all of it. `make synth` therefore reports per-module counts.

**Local and CI simulators differ.** Development ran iverilog 11.0; CI runs
12.0. Both are 4-state and the RTL is `-g2005`, so nothing in the suite depends
on the difference, but it is untested ground between them.

**Two cosmetic warnings left alone.** iverilog reports that the `rtl/` modules
carry no `timescale` (harmless — there are no delays in the RTL), and
`$readmemh` warns that the hex files are shorter than the 64-word ROM (expected
— the testbench zeroes the ROM to NOPs first). Both would need an `rtl/` edit to
silence, and neither justifies touching the design.

---

## Layout

```
rtl/                       one module per file, filename matches module
  processor.v              top level: stage wiring, forwarding muxes, PC logic
  instruction_memory.v  register_file.v  data_memory.v
  control_unit.v  alu.v  sign_extend.v
  if_id.v  id_ex.v  ex_mem.v  mem_wb.v
  forwarding_unit.v  hazard_detection_unit.v
tb/
  tb_processor.v           self-checking harness, one for all programs
  tb_invariants_selftest.v proves the invariants fire
  invariants.vh            shared by both, so the selftest tests the real code
  programs/*.hex           test programs, each with a header stating the
                           hazard, expected final state and evidence register
docs/design.md             datapath, control table, hazard derivations
.github/workflows/ci.yml   ubuntu-24.04, pinned tools, lint then test
```

Full derivations are in **[docs/design.md](docs/design.md)**.
