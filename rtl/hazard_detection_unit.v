module hazard_detection_unit (
    // From ID/EX pipeline register
    input  wire       id_ex_mem_read, // 1 if instruction in EX is a load
    input  wire [4:0] id_ex_rt,       // destination register of the load

    // From IF/ID pipeline register (instruction currently being decoded)
    input  wire [4:0] if_id_rs,       // rs field of the incoming instruction
    input  wire [4:0] if_id_rt,       // rt field of the incoming instruction

    // Whether those fields are actually sources for this opcode, decoded in
    // control_unit. Without them the fields are just bit positions and a
    // destination register looks identical to a source.
    input  wire       if_id_reads_rs,
    input  wire       if_id_reads_rt,

    // Stall control outputs
    output reg        pc_write,       // 0 = stall PC
    output reg        if_id_write,    // 0 = stall IF/ID register
    output reg        id_ex_flush     // 1 = flush ID/EX (insert NOP)
);

    always @(*) begin
        // Default: no stall, pipeline runs freely
        pc_write    = 1'b1;
        if_id_write = 1'b1;
        id_ex_flush = 1'b0;

        // Load-use hazard: the instruction in EX is a load, and the instruction
        // in ID genuinely reads the register it is loading.
        //
        // Both guards below are load-bearing.
        //
        // id_ex_rt != 0: a load into r0 writes nothing, because the register
        // file discards writes to r0. Nothing can depend on a value that is
        // never stored, so there is nothing to wait for.
        //
        // if_id_reads_rs / if_id_reads_rt: a register field that is a
        // destination is not a dependency. Comparing the fields alone stalls
        // whenever a consumer happens to write the same register the load
        // writes -- a WAW, which an in-order pipeline resolves for free.
        if (id_ex_mem_read && (id_ex_rt != 5'd0) &&
            ((if_id_reads_rs && (id_ex_rt == if_id_rs)) ||
             (if_id_reads_rt && (id_ex_rt == if_id_rt))))
        begin
            pc_write    = 1'b0; // freeze PC
            if_id_write = 1'b0; // freeze IF/ID
            id_ex_flush = 1'b1; // inject NOP into EX stage
        end
    end

endmodule
