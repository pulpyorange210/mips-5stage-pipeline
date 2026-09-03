module MEM_WB (
    input  wire        CLK,
    input  wire        reset,
    // Control in
    input  wire        MemToReg_in, RegWrite_in,
    // Data in
    input  wire [31:0] alu_result_in, mem_read_data_in,
    input  wire [4:0]  rd_addr_in,
    // Control out
    output reg         MemToReg_out, RegWrite_out,
    // Data out
    output reg  [31:0] alu_result_out, mem_read_data_out,
    output reg  [4:0]  rd_addr_out
);
    always @(posedge CLK) begin
        if (reset) begin
            MemToReg_out <= 0; RegWrite_out <= 0;
            alu_result_out <= 32'd0; mem_read_data_out <= 32'd0; rd_addr_out <= 5'd0;
        end else begin
            MemToReg_out <= MemToReg_in; RegWrite_out <= RegWrite_in;
            alu_result_out <= alu_result_in; mem_read_data_out <= mem_read_data_in;
            rd_addr_out <= rd_addr_in;
        end
    end
endmodule
