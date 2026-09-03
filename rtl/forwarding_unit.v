module forwarding_unit (
    // Current instruction's source register addresses (in EX stage)
    input  wire [4:0] id_ex_rs,
    input  wire [4:0] id_ex_rt,

    // Previous instruction's destination (in EX/MEM stage)
    input  wire [4:0] ex_mem_rd,
    input  wire       ex_mem_reg_write,

    // Two-instructions-ago destination (in MEM/WB stage)
    input  wire [4:0] mem_wb_rd,
    input  wire       mem_wb_reg_write,

    // Forwarding mux select outputs
    output reg  [1:0] forward_rs,
    output reg  [1:0] forward_rt
);

    always @(*) begin
        // Default: no forwarding
        forward_rs = 2'b00;
        forward_rt = 2'b00;

        // --- ForwardRs ---
        // EX hazard (higher priority): instruction 1 cycle ahead wrote to our rs
        if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs))
            forward_rs = 2'b01;
        // MEM hazard: instruction 2 cycles ahead wrote to our rs
        // only if EX hazard didn't already cover it
        else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs))
            forward_rs = 2'b10;

        // --- ForwardRt ---
        // EX hazard
        if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rt))
            forward_rt = 2'b01;
        // MEM hazard
        else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rt))
            forward_rt = 2'b10;
    end

endmodule
