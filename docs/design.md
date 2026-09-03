# Design notes

A 5-stage pipelined MIPS core supporting `lw`, `sw`, `j`, `xor`, `ori`, with a
forwarding unit, a load-use interlock, and write-first forwarding in the
register file.

## Datapath

```
   IF                IF/ID        ID                ID/EX      EX             EX/MEM     MEM          MEM/WB   WB
 ┌────────┐         ┌─────┐   ┌───────────┐        ┌─────┐  ┌────────┐       ┌─────┐  ┌────────┐     ┌─────┐
 │  PC    │────────▶│     │──▶│ regfile   │───────▶│     │─▶│ fwd    │──────▶│     │─▶│ dmem   │────▶│     │──┐
 │  +4    │  instr  │instr│   │ control   │ rs,rt  │rs,rt│  │ muxes  │ alu   │ alu │  │        │ data│ alu │  │
 └────────┘         │pc+4 │   │ sign_ext  │ ctrl   │ imm │  │  ALU   │ result│result│ └────────┘     │ data│  │
      ▲             └─────┘   └───────────┘        │ctrl │  └────────┘       │rt   │                └─────┘  │
      │                │            │              └─────┘       ▲           │rd   │                   │     │
      │                │            │                 ▲          │           └─────┘                   │     │
      │                │            ▼                 │          │              │                      │     │
      │                │        ctrl_jump             │          └──────────────┘ EX/MEM forward       │     │
      │                │            │                 │          │                                     │     │
      │                │            │            id_ex_flush     └─────────────────────────────────────┘     │
      │                │            │            (interlock)       MEM/WB forward                            │
      │                │            │                                                                        │
      │                └────────────┼──── jump_target = {pc_plus4[31:28], instr[25:0], 2'b00}                 │
      └────────────────────────────-┴────────────────────────────────────────────────────────────────────────┘
                                                                                    write-back to regfile
```

Reset is active-high and synchronous. The clock is `CLK` throughout.

## Control table

Decoded combinationally in `control_unit.v` from `opcode`, and `funct` for
R-type. Every signal is default-assigned at the top of the `always @(*)` block,
so unimplemented opcodes decode to an architectural no-op; `default: ;` states
that explicitly rather than leaving the case incomplete.

| Instruction | opcode | funct | RegDst | ALUSrc | ExtOp | MemToReg | RegWrite | MemRead | MemWrite | ALUOp | Jump |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `lw`  | `100011` | –        | 0 | 1 | 1 | 1 | 1 | 1 | 0 | `00` | 0 |
| `sw`  | `101011` | –        | 0 | 1 | 1 | 0 | 0 | 0 | 1 | `00` | 0 |
| `j`   | `000010` | –        | 0 | 0 | – | 0 | 0 | 0 | 0 | `00` | 1 |
| `ori` | `001101` | –        | 0 | 1 | **0** | 0 | 1 | 0 | 0 | `10` | 0 |
| `xor` | `000000` | `100110` | 1 | 0 | – | 0 | 1 | 0 | 0 | `11` | 0 |
| other | –        | –        | 0 | 0 | 0 | 0 | 0 | 0 | 0 | `00` | 0 |

`ALUOp` reaches the ALU unencoded: `00` add, `10` or, `11` xor, anything else 0.
There is no separate ALU control unit; with five instructions the control unit
emits the operation directly.

`ExtOp` widens the 16-bit immediate: 1 sign-extends, 0 zero-extends. It is
marked – where `ALUSrc` is 0 and the immediate never reaches the ALU. MIPS
decides this by opcode class rather than by instruction format — the logical
immediates zero-extend, the arithmetic and memory ones sign-extend — and `lw`,
`sw` and `ori` are all I-type, so nothing in the encoding distinguishes them.
That is why it has to be decoded rather than derived. `sign_extend` remains a
pure sign-extender and the zero-extended alternative is formed in the datapath;
`ExtOp` selects between them before ID/EX.

`RegDst` picks the write-back register: 0 selects `rt` (the I-type
destination, `lw` and `ori`), 1 selects `rd` (`xor`).

## Hazard derivations

### Forwarding

Two sources can be newer than the register file when an instruction is in EX:
the EX/MEM register (the instruction one ahead) and MEM/WB (two ahead).

```
ForwardRs = 01  if  ex_mem_reg_write and ex_mem_rd != 0 and ex_mem_rd == id_ex_rs
          = 10  elif mem_wb_reg_write and mem_wb_rd != 0 and mem_wb_rd == id_ex_rs
          = 00  otherwise
```

`ForwardRt` is the same with `id_ex_rt`. Three things matter:

- **EX takes priority over MEM.** If both match, the EX/MEM value is the more
  recent write and the `else if` enforces that.
- **The `rd != 0` guard.** Without it, any instruction whose destination
  decoded to r0 would forward its result onto a read of r0 and break the
  hardwired zero. `r0_write.hex` covers this at distance 1.
- **`ForwardRt` is not optional.** `sw` takes its store data through `rt`, so a
  store whose data register was just written needs the rt path or it writes a
  stale word to memory.

### Load-use interlock

Forwarding cannot cover a load followed immediately by a consumer of the loaded
register: the data does not exist until the load's MEM stage finishes, which is
the same cycle the consumer needs it in EX. One stall cycle is required.

```
stall  if  id_ex_mem_read
       and id_ex_rt != 0
       and ( (reads_rs and id_ex_rt == if_id_rs)
          or (reads_rt and id_ex_rt == if_id_rt) )
  -> pc_write = 0, if_id_write = 0, id_ex_flush = 1
```

Freezing the PC and IF/ID holds the consumer in ID for an extra cycle, while
flushing ID/EX injects a NOP into EX so the bubble carries no side effects. By
the next cycle the load is in MEM/WB and `ForwardRs = 10` delivers the word.

Note the failure mode this test has to distinguish. Without the stall the
consumer reaches EX while the load is in EX/MEM, so forwarding matches on
`ex_mem_rd` and supplies `ex_mem_alu_result` — which for a load is the
*address*, not the data. The result is wrong but not obviously wrong, which is
why `load_use.hex` checks the loaded value rather than just that the program
completed.

Both guards on that condition are load-bearing, and they cover different cases.

**The read mask.** `rs` and `rt` are only bit positions, `instr[25:21]` and
`instr[20:16]`. Whether either is a *source* is an opcode question:

| | `rs` | `rt` |
|---|---|---|
| `lw`  | source (base) | **destination** |
| `ori` | source | **destination** |
| `sw`  | source (base) | source (store data) |
| `xor` | source | source |
| `j`   | – | – (part of the 26-bit target) |

Comparing the fields alone stalls whenever a consumer happens to *write* the
register a load is writing — a WAW, which an in-order pipeline resolves for
free because WB is sequential. `ReadsRs`/`ReadsRt` are decoded in
`control_unit`, by the same `case` arms that set the datapath control, so the
opcode list exists in one place and the two cannot drift apart. An unrecognised
R-type reads nothing, which covers `32'h00000000` — the NOP injected on a flush.

**The `id_ex_rt != 0` guard.** A load into `r0` writes nothing, because the
register file discards writes to `r0`. Nothing can depend on a value that is
never stored. The read mask does not cover this: a consumer reading `r0` really
does read `rs`, and `rs` really does equal the load's destination — both are
zero — so the masked comparison is still true. Only the zero guard closes it.

Neither guard substitutes for the other, and `false_stall.hex` contains one
case for each.

### Jump and flush

`jump_taken` is combinational from the decoded opcode, so it is high for exactly
the one cycle `j` occupies ID. By then the next instruction has already been
fetched. There is no delay slot, so IF/ID is flushed on that edge and the
fetched instruction is discarded before it can decode. ID/EX is flushed in the
same edge.

```
jump_target = { if_id_pc_plus4[31:28], if_id_instr[25:0], 2'b00 }
```

A taken jump therefore costs exactly one squashed slot.

### Write-first forwarding in the register file

Writes land on `posedge` and reads are combinational, and ID/EX samples the read
on that same edge. When a producer is in WB in the same cycle a consumer is in
ID — exactly three instructions apart — the consumer would latch the pre-write
value.

```
    cycle    1    2    3    4    5
    producer IF   ID   EX  MEM   WB     writes on the edge ending 5
    +3 consumer          IF   ID        reads on the same edge
```

The forwarding unit cannot close this window: by the time the consumer reaches
EX the producer has left MEM/WB, so neither `ex_mem_rd` nor `mem_wb_rd` matches
and both selects read `00`. The register file is the only thing still holding
the value at the moment of the read, so it returns `write_data` on an address
collision:

```verilog
assign rs_data = (rs_addr == 5'd0)                      ? 32'd0      :
                 (reg_write && (write_addr == rs_addr)) ? write_data :
                                                          registers[rs_addr];
```

Both ports get it. **The r0 test must stay first in the chain.** The write port
is already guarded by `write_addr != 0`, but the bypass condition
`reg_write && write_addr == rs_addr` is genuinely true when both addresses are
zero, so a bypass placed ahead of the r0 test would expose `write_data` on a
read of r0. `r0_write.hex` covers exactly that ordering at distance 3.

## Removed ports

Two output ports were deleted along with their dead nets. Both were carrying
signals nothing consumed, and both cost real gates.

| Module | Port | Why it went |
|---|---|---|
| `alu` | `zero` | A zero flag exists to drive a branch comparison. There are no branch instructions in this ISA, so nothing ever read it. The port and its `assign zero = (result == 32'd0)` comparator are both gone. |
| `ID_EX` | `pc_plus4_in`, `pc_plus4_out` | PC+4 is never read after ID. A branch would need it in EX to compute a target; `j` does not, because `jump_target` is built in ID from `if_id_pc_plus4` straight off the IF/ID register. The 32-bit pipeline register between the two ports went with them. |

Removing them was not optional once the nets were gone: Verilator rejects a
dangling pin either way, `PINCONNECTEMPTY` for an empty connection and
`PINMISSING` for an omitted one. Silencing that with a pragma would have kept
the dead logic and hidden it, so the ports went instead.

### `ex_mem_mem_read` is not dead — do not remove it

The working notes this project was built from listed a third dead net,
`ex_mem_mem_read`, alongside the two above. That was wrong, and it is recorded
here because acting on it would have broken the design and, worse, the
assertion meant to catch the breakage.

`ex_mem_mem_read` drives `dmem.mem_read`, which gates the data memory's read
path. It is also read by the testbench invariant asserting that data memory is
never read and written in the same cycle — so deleting the net would have
removed the signal *and* disarmed the check that would have noticed. Verilator
does not flag it as unused, which is the giveaway: only `alu_zero` and
`id_ex_pc_plus4` ever appeared in the `UNUSEDSIGNAL` output.

The general lesson is worth more than the specific net. A hand-written list of
dead code is a hypothesis, not a result. The linter is the authority on what is
actually unreferenced, and the two nets it named are exactly the two that went.

One consequence is worth recording. With ID/EX no longer consuming it, only
`if_id_pc_plus4[31:28]` is read — by `jump_target`. That is the J-type rule: the
target inherits the top 4 bits of PC+4 and takes the other 28 from the
instruction. The lower bits are carried but unused by design, and that net
carries a targeted `lint_off UNUSEDSIGNAL` saying so.

## Other deviations from the original submission

- **Instruction memory initialises in an `initial` block, not on reset.** The
  assignment specified reset-time initialisation. Left as-is; the testbench
  overwrites the ROM by hierarchical reference before the first fetch, so the
  test programs are unaffected.
### A note on what `lw`/`sw` cannot test

The memory address path cannot distinguish the two extensions, so no load or
store offset can ever serve as evidence for `ExtOp`. `data_memory` indexes on
`addr[7:0]`, and sign- and zero-extension agree on the low sixteen bits by
construction — they differ only in bits [31:16]. Any offset therefore produces
an identical byte address either way.

Evidence has to come through the ALU result of a logical immediate, which is
what `ori_zeroext.hex` uses, and its immediate must have bit 15 set or the two
extensions coincide and the test silently stops testing anything.
