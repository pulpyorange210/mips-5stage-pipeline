module control_unit (
    input  wire [5:0] opcode,
    input  wire [5:0] funct,
    output reg        RegDst,
    output reg        ALUSrc,
    output reg        MemToReg,
    output reg        RegWrite,
    output reg        MemRead,
    output reg        MemWrite,
    output reg [1:0]  ALUOp,
    output reg        Jump
);

    always @(*) begin
        // defaults X as 0
        RegDst   = 0;
        ALUSrc   = 0;
        MemToReg = 0;
        RegWrite = 0;
        MemRead  = 0;
        MemWrite = 0;
        ALUOp    = 2'b00;
        Jump     = 0;

        case (opcode)
            6'b100011: begin // lw
                ALUSrc   = 1;
                MemToReg = 1;
                RegWrite = 1;
                MemRead  = 1;
            end

            6'b101011: begin // sw
                ALUSrc   = 1;
                MemWrite = 1;
            end

            6'b000010: begin // j
                Jump = 1;
            end

            6'b001101: begin // ori
                ALUSrc   = 1;
                RegWrite = 1;
                ALUOp    = 2'b10;
            end

            6'b000000: begin // R-type
                if (funct == 6'b100110) begin // xor
                    RegDst   = 1;
                    RegWrite = 1;
                    ALUOp    = 2'b11;
                end
            end
        endcase
    end

endmodule
