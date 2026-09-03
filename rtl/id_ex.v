module ID_EX (
    input  wire        CLK,
    input  wire        reset,
    input  wire        flush,
    // Control in
    input  wire        RegDst_in, ALUSrc_in, MemToReg_in, RegWrite_in, MemRead_in, MemWrite_in,
    input  wire [1:0]  ALUOp_in,
    // Data in
    input  wire [31:0] rs_data_in, rt_data_in, ext_imm_in,
    input  wire [4:0]  rs_addr_in, rt_addr_in, rd_addr_in,
    // Control out
    output reg         RegDst_out, ALUSrc_out, MemToReg_out, RegWrite_out, MemRead_out, MemWrite_out,
    output reg  [1:0]  ALUOp_out,
    // Data out
    output reg  [31:0] rs_data_out, rt_data_out, ext_imm_out,
    output reg  [4:0]  rs_addr_out, rt_addr_out, rd_addr_out
);
    always @(posedge CLK) begin
        if (reset || flush) begin
            RegDst_out <= 0; ALUSrc_out <= 0; MemToReg_out <= 0; RegWrite_out <= 0;
            MemRead_out <= 0; MemWrite_out <= 0; ALUOp_out <= 2'b00;
            rs_data_out <= 32'd0; rt_data_out <= 32'd0; ext_imm_out <= 32'd0;
            rs_addr_out <= 5'd0; rt_addr_out <= 5'd0; rd_addr_out <= 5'd0;
        end else begin
            RegDst_out <= RegDst_in; ALUSrc_out <= ALUSrc_in; MemToReg_out <= MemToReg_in;
            RegWrite_out <= RegWrite_in; MemRead_out <= MemRead_in; MemWrite_out <= MemWrite_in;
            ALUOp_out <= ALUOp_in;
            rs_data_out <= rs_data_in; rt_data_out <= rt_data_in;
            ext_imm_out <= ext_imm_in;
            rs_addr_out <= rs_addr_in; rt_addr_out <= rt_addr_in; rd_addr_out <= rd_addr_in;
        end
    end
endmodule
