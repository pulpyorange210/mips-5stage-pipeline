`timescale 1ns / 1ps

// Self-checking testbench for the 5-stage pipelined MIPS core.
//
// One harness serves every test program. The Makefile bakes four things in at
// compile time, so each build under build/ is a self-contained run:
//
//   PROGRAM     path to the .hex loaded into the instruction ROM
//   VCDFILE     where to dump waves
//   PROG_ID     selects which block of hardcoded expected values to check
//   RUN_CYCLES  how many post-reset cycles to run before checking end state
//
// The DUT is reached by hierarchical reference only. Nothing under rtl/ has a
// debug port, a status flag or a $display in it, and it must stay that way --
// changing a design so you can watch it is visible in the diff.

`ifndef PROGRAM
  `define PROGRAM "tb/programs/raw_dist3.hex"
`endif
`ifndef VCDFILE
  `define VCDFILE "build/tb_processor.vcd"
`endif
`ifndef PROG_ID
  `define PROG_ID 3
`endif
`ifndef RUN_CYCLES
  `define RUN_CYCLES 20
`endif

module tb_processor;

    // Program ids. These mirror the PROGID_<name> values in the Makefile.
    localparam PROG_ORIGINAL   = 0;
    localparam PROG_RAW_DIST1  = 1;
    localparam PROG_RAW_DIST2  = 2;
    localparam PROG_RAW_DIST3  = 3;
    localparam PROG_LOAD_USE   = 4;
    localparam PROG_R0_WRITE   = 5;
    localparam PROG_JUMP_FLUSH  = 6;
    localparam PROG_FALSE_STALL = 7;

    localparam ROM_WORDS = 64;

    reg     CLK;
    reg     reset;
    integer errors;
    integer cycle;
    integer i;

    // Behavioural counters. These turn the timing claims in the .hex headers
    // into assertions instead of comments, and they catch the failure modes
    // end-state checking is blind to: a spurious stall costs cycles without
    // changing any architectural result, and a forward that never happens can
    // be masked by a value that was going to be right anyway.
    integer stall_cycles;   // cycles with pc_write low: the interlock firing
    integer flush_cycles;   // cycles with jump_taken high
    integer fwd_rs_ex;      // cycles with ForwardRs = 01 (EX/MEM -> EX)
    integer fwd_rs_mem;     // cycles with ForwardRs = 10 (MEM/WB -> EX)

    processor dut (
        .CLK   (CLK),
        .reset (reset)
    );

    // 10ns period.  Posedges land at 5, 15, 25, ... ns.
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    // Reset held across two posedges (5ns and 15ns), released at 20ns.
    initial begin
        reset = 1'b1;
        @(negedge CLK);
        @(negedge CLK);
        reset = 1'b0;
    end

    initial begin
        errors       = 0;
        cycle        = 0;
        stall_cycles = 0;
        flush_cycles = 0;
        fwd_rs_ex    = 0;
        fwd_rs_mem   = 0;
    end

    initial begin
        $timeformat(-9, 0, " ns", 10);
        $dumpfile(`VCDFILE);
        $dumpvars(0, tb_processor);
    end

    // Load the program at 1ns: after the ROM's own initial block has run, but
    // well before the first posedge at 5ns. The ROM is cleared first, because
    // $readmemh only overwrites as many words as the file holds and the RTL's
    // initial block would otherwise leave its own program in the tail.
    // 32'h00000000 decodes to an R-type with funct 000000, which is not xor, so
    // the control unit asserts nothing -- a true architectural NOP.
    initial begin
        #1;
        for (i = 0; i < ROM_WORDS; i = i + 1) begin
            dut.imem.rom[i] = 32'd0;
        end
        $readmemh(`PROGRAM, dut.imem.rom);
        $display("[tb] program = %0s", `PROGRAM);
    end

    // ------------------------------------------------------------------
    // Checking helpers
    // ------------------------------------------------------------------

    // Reads a big-endian 32-bit word out of the byte-addressed data memory.
    function [31:0] dmem_word;
        input integer byte_addr;
        begin
            dmem_word = {dut.dmem.mem[byte_addr],
                         dut.dmem.mem[byte_addr + 1],
                         dut.dmem.mem[byte_addr + 2],
                         dut.dmem.mem[byte_addr + 3]};
        end
    endfunction

    task expect_reg;
        input [4:0]   idx;
        input [31:0]  expected;
        input [511:0] why;
        begin
            if (dut.regfile.registers[idx] !== expected) begin
                $display("MISMATCH r%0d: expected %h, got %h  (%0s)",
                         idx, expected, dut.regfile.registers[idx], why);
                errors = errors + 1;
            end else begin
                $display("ok       r%0d = %h  (%0s)", idx, expected, why);
            end
        end
    endtask

    task expect_count;
        input integer  actual;
        input integer  expected;
        input [511:0]  what;
        begin
            if (actual !== expected) begin
                $display("MISMATCH %0s: expected %0d, got %0d", what, expected, actual);
                errors = errors + 1;
            end else begin
                $display("ok       %0s = %0d", what, actual);
            end
        end
    endtask

    // For coverage-style claims where the exact count is an implementation
    // detail but zero would mean the mechanism never ran.
    task expect_at_least_one;
        input integer  actual;
        input [511:0]  what;
        begin
            if (actual < 1) begin
                $display("MISMATCH %0s: never occurred, expected at least once", what);
                errors = errors + 1;
            end else begin
                $display("ok       %0s occurred %0d time(s)", what, actual);
            end
        end
    endtask

    task expect_dmem;
        input integer byte_addr;
        input [31:0]  expected;
        input [511:0] why;
        begin
            if (dmem_word(byte_addr) !== expected) begin
                $display("MISMATCH dmem[%0d]: expected %h, got %h  (%0s)",
                         byte_addr, expected, dmem_word(byte_addr), why);
                errors = errors + 1;
            end else begin
                $display("ok       dmem[%0d] = %h  (%0s)", byte_addr, expected, why);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Continuous invariants.
    //
    // The checks themselves live in tb/invariants.vh, shared with
    // tb_invariants_selftest.v so that the selftest proves this exact code
    // fires rather than a duplicate of it.
    //
    // check_invariants is called on negedge, not posedge: at a posedge the
    // testbench runs in the active region, before the RTL's non-blocking
    // updates land, so it would sample stale state. Mid-cycle everything has
    // settled.
    // ------------------------------------------------------------------
    `include "invariants.vh"

    // ------------------------------------------------------------------
    // Per-program end-state expectations, hardcoded.
    // ------------------------------------------------------------------
    task check_end_state;
        begin
            $display("[tb] end-state check after %0d cycles", cycle);
            case (`PROG_ID)

                // raw_dist3 -- write-first forwarding in the register file.
                // r5 is produced at index 0 and consumed at index 3, so the
                // producer is in WB in the same cycle the consumer is in ID.
                // Evidence: r6. It is 0x000000AB only if the register file
                // returns the value being written rather than the stale entry.
                PROG_RAW_DIST3: begin
                    expect_reg(5'd5, 32'h000000AB, "producer wrote r5");
                    expect_reg(5'd6, 32'h000000AB, "EVIDENCE: distance-3 read of r5 must see 0xAB, not stale 0");
                    expect_dmem(0,   32'h000000AB, "r6 sunk to dmem word 0");
                    expect_count(stall_cycles, 0, "stall cycles (no lw in this program)");
                end

                // raw_dist1 -- EX->EX forwarding, ForwardRs = 01.
                // Producer at index 0, consumer at index 1.
                PROG_RAW_DIST1: begin
                    expect_reg(5'd1, 32'h00000011, "producer wrote r1");
                    expect_reg(5'd2, 32'h00000011, "EVIDENCE: distance-1 read of r1 must see 0x11, not stale 0");
                    expect_dmem(0,   32'h00000011, "r2 sunk to dmem word 0");
                    expect_at_least_one(fwd_rs_ex, "ForwardRs = 01 (EX/MEM -> EX)");
                    expect_count(stall_cycles, 0, "stall cycles (no lw in this program)");
                end

                // raw_dist2 -- MEM->EX forwarding, ForwardRs = 10.
                // Producer at index 0, consumer at index 2, NOP between them so
                // the EX hazard cannot match and 10 is reached on its own path.
                PROG_RAW_DIST2: begin
                    expect_reg(5'd3, 32'h00000022, "producer wrote r3");
                    expect_reg(5'd4, 32'h00000022, "EVIDENCE: distance-2 read of r3 must see 0x22, not stale 0");
                    expect_dmem(0,   32'h00000022, "r4 sunk to dmem word 0");
                    expect_at_least_one(fwd_rs_mem, "ForwardRs = 10 (MEM/WB -> EX)");
                    expect_count(stall_cycles, 0, "stall cycles (no lw in this program)");
                end

                // load_use -- the one-cycle interlock.
                // Without the stall the consumer would forward ex_mem_alu_result,
                // which for a load is the address, and r8 would read 0.
                PROG_LOAD_USE: begin
                    expect_reg(5'd7, 32'h00000014, "lw loaded 0x14 from dmem word 0");
                    expect_reg(5'd8, 32'h00000014, "EVIDENCE: consumer must see the loaded word, not the address");
                    expect_dmem(8,   32'h00000014, "r8 sunk to dmem word 8");
                    expect_dmem(0,   32'h00000014, "dmem word 0 untouched by the load");
                    expect_count(stall_cycles, 1, "stall cycles (exactly one interlock)");
                end

                // r0_write -- writes to r0 discarded on all three paths:
                // the write port, the forwarding unit's rd != 0 guard, and the
                // ordering of the write-first bypass behind the r0 test.
                PROG_R0_WRITE: begin
                    expect_reg(5'd0,  32'h00000000, "r0 never written");
                    expect_reg(5'd9,  32'h00000055, "EVIDENCE: distance-1 read of r0 (forwarding rd != 0 guard)");
                    expect_reg(5'd10, 32'h00000066, "EVIDENCE: distance-3 read of r0 (write-first ordered behind r0 test)");
                    expect_dmem(0,    32'h00000000, "r0 stored to dmem word 0, was 0x14 at reset");
                    expect_count(stall_cycles, 0, "stall cycles (no lw in this program)");
                end

                // jump_flush -- the instruction after j is squashed.
                PROG_JUMP_FLUSH: begin
                    expect_reg(5'd11, 32'h000000C1, "reached the jump");
                    expect_reg(5'd12, 32'h00000000, "EVIDENCE: index 4 was squashed, must not have written 0xBA");
                    expect_reg(5'd13, 32'h000000D1, "landed on the jump target");
                    expect_reg(5'd14, 32'h00000000, "index 5 was jumped over entirely");
                    expect_dmem(0,    32'h00000000, "r12 stored to dmem word 0, was 0x14 at reset");
                    expect_count(flush_cycles, 1, "flush cycles (jump_taken high exactly once)");
                    expect_count(stall_cycles, 0, "stall cycles (no lw in this program)");
                end

                // false_stall -- the interlock must NOT fire. A lw at index 4
                // is followed by ori r5, r0, 0x77, whose rt is the destination
                // rather than a source, so there is no dependency to wait for.
                //
                // The stall count is the whole test. Every architectural value
                // below is identical with and without the spurious stall, which
                // is exactly why end-state checking alone cannot catch this.
                PROG_FALSE_STALL: begin
                    expect_reg(5'd4, 32'h00000014, "positive control: a real lw executed");
                    expect_reg(5'd5, 32'h00000077, "ori won the WAW; same either way");
                    expect_dmem(4,   32'h00000077, "r5 sunk to dmem word 4");
                    expect_dmem(0,   32'h00000014, "dmem word 0 untouched by the loads");
                    expect_count(stall_cycles, 0, "EVIDENCE: stall cycles must be 0, rt here is a destination");
                end

                default: begin
                    $display("NO EXPECTATIONS defined for PROG_ID %0d", `PROG_ID);
                    errors = errors + 1;
                end
            endcase
        end
    endtask

    task report_and_finish;
        begin
            $display("[tb] errors = %0d", errors);
            if (errors == 0)
                $display("TEST PASSED");
            else
                $display("TEST FAILED");
            $finish;
        end
    endtask

    // ------------------------------------------------------------------
    // Main loop
    // ------------------------------------------------------------------
    always @(negedge CLK) begin
        if (!reset) begin
            cycle = cycle + 1;
            check_invariants;

            if (dut.pc_write   === 1'b0)  stall_cycles = stall_cycles + 1;
            if (dut.jump_taken === 1'b1)  flush_cycles = flush_cycles + 1;
            if (dut.forward_rs === 2'b01) fwd_rs_ex    = fwd_rs_ex + 1;
            if (dut.forward_rs === 2'b10) fwd_rs_mem   = fwd_rs_mem + 1;
            if (cycle >= `RUN_CYCLES) begin
                check_end_state;
                report_and_finish;
            end
        end
    end

    // Backstop so CI can never hang, e.g. if the clock or reset logic breaks
    // and the negedge block above never reaches its cycle budget.
    initial begin
        #((`RUN_CYCLES + 100) * 10);
        $display("TIMEOUT at %0t: reached the watchdog without finishing", $time);
        errors = errors + 1;
        report_and_finish;
    end

endmodule
