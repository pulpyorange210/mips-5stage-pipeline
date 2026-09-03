module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [1:0]  alu_ctrl,
    output reg  [31:0] result,
    output wire        zero
);
    assign zero = (result == 32'd0);

    always @(*) begin
        case (alu_ctrl)
            2'b00:   result = a + b; // ADD (lw, sw)
            2'b10:   result = a | b; // OR (ori)
            2'b11:   result = a ^ b; // XOR
            default: result = 32'd0;
        endcase
    end
endmodule
