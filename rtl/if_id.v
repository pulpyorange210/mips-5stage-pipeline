module IF_ID (
    input  wire        CLK,
    input  wire        reset,
    input  wire        flush,
    input  wire        write_enable,
    input  wire [31:0] pc_plus4_in,
    input  wire [31:0] instr_in,
    output reg  [31:0] pc_plus4_out,
    output reg  [31:0] instr_out
);
    always @(posedge CLK) begin
        if (reset || flush) begin
            pc_plus4_out <= 32'd0;
            instr_out    <= 32'd0;
        end else if (write_enable) begin
            pc_plus4_out <= pc_plus4_in;
            instr_out    <= instr_in;
        end
    end

endmodule
