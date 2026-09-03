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
    output reg        Jump,

    // Which source registers this opcode actually reads. rs and rt are only
    // bit positions -- instr[25:21] and instr[20:16] -- and whether either is
    // a source is an opcode question, not a field question. The hazard unit
    // needs this to tell a real dependency from a name collision with a
    // destination. Decoded here rather than in the hazard path so that the
    // opcode list exists once: these are set by the same case arms that set
    // the datapath control, and cannot drift out of step with them.
    output reg        ReadsRs,
    output reg        ReadsRt
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
        ReadsRs  = 0;
        ReadsRt  = 0;

        case (opcode)
            6'b100011: begin // lw
                ALUSrc   = 1;
                MemToReg = 1;
                RegWrite = 1;
                MemRead  = 1;
                ReadsRs  = 1;   // base address; rt is the destination
            end

            6'b101011: begin // sw
                ALUSrc   = 1;
                MemWrite = 1;
                ReadsRs  = 1;   // base address
                ReadsRt  = 1;   // store data
            end

            6'b000010: begin // j
                Jump = 1;
                // Reads neither. instr[25:21] and instr[20:16] are part of the
                // 26-bit target here and are not register numbers at all.
            end

            6'b001101: begin // ori
                ALUSrc   = 1;
                RegWrite = 1;
                ALUOp    = 2'b10;
                ReadsRs  = 1;   // rt is the destination
            end

            6'b000000: begin // R-type
                if (funct == 6'b100110) begin // xor
                    RegDst   = 1;
                    RegWrite = 1;
                    ALUOp    = 2'b11;
                    ReadsRs  = 1;
                    ReadsRt  = 1;
                end
                // Any other funct is a no-op and reads nothing, which includes
                // 32'h00000000 -- the NOP the pipeline injects on a flush.
            end

            // Every unimplemented opcode decodes to the defaults above, which
            // are an architectural no-op: no register write, no memory access,
            // no jump. Stating that explicitly rather than leaving the case
            // incomplete, so the intent is in the source and not just in the
            // reader's head.
            default: ;
        endcase
    end

endmodule
