`timescale 1ns / 1ps

// Selftest for the continuous invariants.
//
// An assertion that cannot fail is worse than no assertion: it reads like
// coverage and provides none. This testbench deliberately corrupts the state
// each invariant polices and asserts that the invariant notices.
//
// It includes tb/invariants.vh, the same file tb_processor.v includes, so what
// is under test here is the code that actually guards the real runs.
//
// Two things are checked per scenario:
//   1. the provoked invariant fired
//   2. no other invariant fired
//
// (2) matters. An invariant that fires on everything is as useless as one that
// fires on nothing, and without it a single over-broad check could appear to
// pass all five scenarios.
//
// The program ROM is left as all-zeros, which decodes to architectural NOPs, so
// the pipeline stays quiet and every firing is attributable to the corruption
// being applied. The baseline scenario asserts that quiet really is quiet.
//
// Run with `make selftest`. It is not part of `make test`: it verifies the
// testbench, not the processor.

`ifndef VCDFILE
  `define VCDFILE "build/invariants_selftest.vcd"
`endif

module tb_invariants_selftest;

    localparam ROM_WORDS = 64;

    reg     CLK;
    reg     reset;
    integer errors;           // driven by the invariants; deliberately inflated
    integer cycle;
    integer selftest_errors;  // the verdict for this testbench
    integer i;

    integer before [1:5];

    processor dut (
        .CLK   (CLK),
        .reset (reset)
    );

    `include "invariants.vh"

    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    initial begin
        reset = 1'b1;
        @(negedge CLK);
        @(negedge CLK);
        reset = 1'b0;
    end

    initial begin
        errors          = 0;
        cycle           = 0;
        selftest_errors = 0;
    end

    initial begin
        $timeformat(-9, 0, " ns", 10);
        $dumpfile(`VCDFILE);
        $dumpvars(0, tb_invariants_selftest);
    end

    // All-NOP ROM: opcode 000000 with funct 000000 is an R-type that is not
    // xor, so the control unit asserts nothing.
    initial begin
        #1;
        for (i = 0; i < ROM_WORDS; i = i + 1) begin
            dut.imem.rom[i] = 32'd0;
        end
    end

    always @(negedge CLK) begin
        if (!reset) begin
            cycle = cycle + 1;
            check_invariants;
        end
    end

    // ------------------------------------------------------------------
    // Scenario scaffolding
    // ------------------------------------------------------------------

    task snapshot;
        integer k;
        begin
            for (k = 1; k <= INV_COUNT; k = k + 1)
                before[k] = inv_fires[k];
        end
    endtask

    // Waits one full check, then asserts that exactly the expected invariant
    // fired. The #1 after the negedge lets the always block above run first;
    // without it the two negedge-sensitive processes would race.
    task expect_fired;
        input integer  id;
        input [511:0]  label;
        integer k;
        integer others;
        begin
            @(negedge CLK);
            #1;
            others = 0;
            for (k = 1; k <= INV_COUNT; k = k + 1)
                if (k != id && inv_fires[k] !== before[k])
                    others = others + 1;

            if (inv_fires[id] === before[id]) begin
                $display("SELFTEST FAIL: %0s -- state was corrupted but the invariant did not fire", label);
                selftest_errors = selftest_errors + 1;
            end else if (others !== 0) begin
                $display("SELFTEST FAIL: %0s -- fired, but so did %0d other invariant(s)", label, others);
                selftest_errors = selftest_errors + 1;
            end else begin
                $display("ok  %0s -- fired, and nothing else did", label);
            end
        end
    endtask

    task expect_quiet;
        input [511:0] label;
        integer k;
        integer any;
        begin
            any = 0;
            for (k = 1; k <= INV_COUNT; k = k + 1)
                if (inv_fires[k] !== before[k])
                    any = any + 1;
            if (any !== 0) begin
                $display("SELFTEST FAIL: %0s -- %0d invariant(s) fired on an undisturbed core", label, any);
                selftest_errors = selftest_errors + 1;
            end else begin
                $display("ok  %0s -- no invariant fired", label);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Scenarios
    // ------------------------------------------------------------------

    initial begin
        // Let reset finish and the pipeline settle.
        @(negedge reset);
        repeat (3) @(negedge CLK);

        // Baseline: an undisturbed core must trip nothing. If this fails the
        // rest of the run means nothing, because firings stop being
        // attributable to the corruption.
        snapshot;
        repeat (4) @(negedge CLK);
        #1;
        expect_quiet("baseline (undisturbed core)");

        // 1. r0 is hardwired zero -- poke the storage directly.
        @(posedge CLK);
        snapshot;
        dut.regfile.registers[0] = 32'hDEADBEEF;
        expect_fired(INV_R0_ZERO, "r0_is_zero");
        dut.regfile.registers[0] = 32'd0;
        repeat (2) @(negedge CLK);

        // 2. The r0 bypass on the read port -- make the decoded rs read r0
        //    while the read port returns something non-zero.
        @(posedge CLK);
        snapshot;
        force dut.if_id_reg.instr_out = 32'd0;
        force dut.rs_data_id          = 32'hDEADBEEF;
        expect_fired(INV_R0_READ_PORT, "r0_read_port");
        release dut.if_id_reg.instr_out;
        release dut.rs_data_id;
        repeat (2) @(negedge CLK);

        // 3. Data memory read and written in the same cycle.
        @(posedge CLK);
        snapshot;
        force dut.ex_mem_mem_read  = 1'b1;
        force dut.ex_mem_mem_write = 1'b1;
        expect_fired(INV_DMEM_RW, "dmem_no_rw_same_cycle");
        release dut.ex_mem_mem_read;
        release dut.ex_mem_mem_write;
        repeat (2) @(negedge CLK);

        // 4. PC alignment -- a non-word-aligned PC, without any X in it, so
        //    this scenario cannot be satisfied by the X check instead.
        @(posedge CLK);
        snapshot;
        force dut.pc = 32'h00000002;
        expect_fired(INV_PC_ALIGN, "pc_word_aligned");
        release dut.pc;
        // A release on a reg leaves the forced value in place until the next
        // procedural assignment, so the PC would resume counting from 2 and
        // stay misaligned for the rest of the run, contaminating every later
        // scenario. Put it back on a word boundary explicitly.
        dut.pc = 32'd0;
        repeat (2) @(negedge CLK);

        // 5. X on a control signal. Driven onto ctrl_mem_write rather than the
        //    PC, so it does not also trip pc_word_aligned.
        @(posedge CLK);
        snapshot;
        force dut.ctrl_mem_write = 1'bx;
        expect_fired(INV_NO_X, "no_x_on_control");
        release dut.ctrl_mem_write;
        repeat (2) @(negedge CLK);

        $display("[selftest] invariant firings: r0=%0d read_port=%0d dmem_rw=%0d pc_align=%0d no_x=%0d",
                 inv_fires[INV_R0_ZERO], inv_fires[INV_R0_READ_PORT],
                 inv_fires[INV_DMEM_RW], inv_fires[INV_PC_ALIGN], inv_fires[INV_NO_X]);
        $display("[selftest] selftest_errors = %0d", selftest_errors);
        $display("[selftest] note: the INVARIANT VIOLATED lines above are deliberate");
        if (selftest_errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

    // Backstop so CI cannot hang.
    initial begin
        #5000;
        $display("TIMEOUT at %0t: selftest did not complete", $time);
        $display("TEST FAILED");
        $finish;
    end

endmodule
