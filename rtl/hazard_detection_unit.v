module hazard_detection_unit (
    // From ID/EX pipeline register
    input  wire       id_ex_mem_read, // 1 if instruction in EX is a load
    input  wire [4:0] id_ex_rt,       // destination register of the load

    // From IF/ID pipeline register (instruction currently being decoded)
    input  wire [4:0] if_id_rs,       // source register 1 of incoming instruction
    input  wire [4:0] if_id_rt,       // source register 2 of incoming instruction

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

        // Load-use hazard condition (from lecture slide 18/19)
        if (id_ex_mem_read &&
            ((id_ex_rt == if_id_rs) || (id_ex_rt == if_id_rt)))
        begin
            pc_write    = 1'b0; // freeze PC
            if_id_write = 1'b0; // freeze IF/ID
            id_ex_flush = 1'b1; // inject NOP into EX stage
        end
    end

endmodule
