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
    localparam PROG_JUMP_FLUSH = 6;

    localparam ROM_WORDS = 64;

    reg     CLK;
    reg     reset;
    integer errors;
    integer cycle;
    integer i;

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
        errors = 0;
        cycle  = 0;
    end

    initial begin
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
    // Continuous invariants
    //
    // Checked on negedge rather than posedge: at a posedge the testbench runs
    // in the active region, before the RTL's non-blocking updates land, so it
    // would sample stale state. Mid-cycle everything has settled.
    //
    // Every comparison uses === / !== . The == and != operators return X when
    // either side contains X, and an if treats X as false -- which would
    // silently pass on exactly the uninitialised-signal bug these are here to
    // catch.
    // ------------------------------------------------------------------
    task fail_invariant;
        input [511:0] name;
        input [511:0] detail;
        begin
            $display("INVARIANT VIOLATED at %0t (cycle %0d): %0s -- %0s",
                     $time, cycle, name, detail);
            errors = errors + 1;
        end
    endtask

    task check_invariants;
        begin
            // Architectural: r0 is hardwired zero.
            if (dut.regfile.registers[0] !== 32'd0) begin
                fail_invariant("r0_is_zero", "registers[0] is not 32'd0");
                $display("           registers[0] = %h", dut.regfile.registers[0]);
            end

            // The r0 bypass must hold on the read port too, not just in storage.
            if (dut.if_id_rs === 5'd0 && dut.rs_data_id !== 32'd0) begin
                fail_invariant("r0_read_port", "if_id_rs is r0 but rs_data_id is non-zero");
                $display("           rs_data_id = %h", dut.rs_data_id);
            end

            // Control: data memory can never be read and written in one cycle.
            if (dut.ex_mem_mem_read === 1'b1 && dut.ex_mem_mem_write === 1'b1) begin
                fail_invariant("dmem_no_rw_same_cycle", "ex_mem_mem_read and ex_mem_mem_write both high");
            end

            // Alignment: the PC is always word-aligned.
            if (dut.pc[1:0] !== 2'b00) begin
                fail_invariant("pc_word_aligned", "pc[1:0] is not 2'b00");
                $display("           pc = %h", dut.pc);
            end

            // No unknowns on the PC or the control signals once reset is gone.
            if (^{dut.pc, dut.ctrl_reg_write, dut.ctrl_mem_write} === 1'bx) begin
                fail_invariant("no_x_on_control", "X or Z on pc / ctrl_reg_write / ctrl_mem_write");
                $display("           pc = %h  ctrl_reg_write = %b  ctrl_mem_write = %b",
                         dut.pc, dut.ctrl_reg_write, dut.ctrl_mem_write);
            end
        end
    endtask

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
