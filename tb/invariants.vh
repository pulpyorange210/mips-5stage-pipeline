// Continuous invariant checks, shared by tb_processor.v and
// tb_invariants_selftest.v.
//
// This lives in its own file for one reason: tb_invariants_selftest.v proves
// these checks actually fire. If the selftest carried its own copy of the
// logic it would only prove the copy works, which is worth nothing. Both
// testbenches include this file, so the selftest exercises the same code that
// guards the real runs.
//
// The including module must provide:
//   - an `integer errors` counter
//   - an `integer cycle` counter, for the diagnostic line
//   - an instance named `dut` of the processor
//
// Every comparison uses === / !== . The == and != operators return X when
// either side contains X, and an `if` treats X as false -- which would
// silently pass on exactly the uninitialised-signal bug these are here to
// catch.

`ifndef INVARIANTS_VH
`define INVARIANTS_VH

    localparam INV_R0_ZERO        = 1;
    localparam INV_R0_READ_PORT   = 2;
    localparam INV_DMEM_RW        = 3;
    localparam INV_PC_ALIGN       = 4;
    localparam INV_NO_X           = 5;
    localparam INV_COUNT          = 5;

    // Per-invariant fire counters, so the selftest can assert that the
    // invariant it provoked is the one that fired and no other.
    integer       inv_fires [1:INV_COUNT];
    integer       last_invariant_id;
    reg [511:0]   last_invariant;

    integer inv_init_idx;
    initial begin
        for (inv_init_idx = 1; inv_init_idx <= INV_COUNT; inv_init_idx = inv_init_idx + 1)
            inv_fires[inv_init_idx] = 0;
        last_invariant_id = 0;
        last_invariant    = "none";
    end

    task fail_invariant;
        input integer id;
        input [511:0] name;
        input [511:0] detail;
        begin
            inv_fires[id]     = inv_fires[id] + 1;
            last_invariant_id = id;
            last_invariant    = name;
            errors            = errors + 1;
            $display("INVARIANT VIOLATED at %0t (cycle %0d): %0s -- %0s",
                     $time, cycle, name, detail);
        end
    endtask

    task check_invariants;
        begin
            // Architectural: r0 is hardwired zero.
            if (dut.regfile.registers[0] !== 32'd0) begin
                fail_invariant(INV_R0_ZERO, "r0_is_zero", "registers[0] is not 32'd0");
                $display("           registers[0] = %h", dut.regfile.registers[0]);
            end

            // The r0 bypass must hold on the read port too, not just in storage.
            if (dut.if_id_rs === 5'd0 && dut.rs_data_id !== 32'd0) begin
                fail_invariant(INV_R0_READ_PORT, "r0_read_port",
                               "if_id_rs is r0 but rs_data_id is non-zero");
                $display("           rs_data_id = %h", dut.rs_data_id);
            end

            // Control: data memory can never be read and written in one cycle.
            if (dut.ex_mem_mem_read === 1'b1 && dut.ex_mem_mem_write === 1'b1) begin
                fail_invariant(INV_DMEM_RW, "dmem_no_rw_same_cycle",
                               "ex_mem_mem_read and ex_mem_mem_write both high");
            end

            // Alignment: the PC is always word-aligned.
            if (dut.pc[1:0] !== 2'b00) begin
                fail_invariant(INV_PC_ALIGN, "pc_word_aligned", "pc[1:0] is not 2'b00");
                $display("           pc = %h", dut.pc);
            end

            // No unknowns on the PC or the control signals once reset is gone.
            if (^{dut.pc, dut.ctrl_reg_write, dut.ctrl_mem_write} === 1'bx) begin
                fail_invariant(INV_NO_X, "no_x_on_control",
                               "X or Z on pc / ctrl_reg_write / ctrl_mem_write");
                $display("           pc = %h  ctrl_reg_write = %b  ctrl_mem_write = %b",
                         dut.pc, dut.ctrl_reg_write, dut.ctrl_mem_write);
            end
        end
    endtask

`endif
