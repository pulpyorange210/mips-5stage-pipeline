module instruction_memory (
    input  wire [31:0] pc,
    output wire [31:0] instr
);
    reg [31:0] rom [0:63];
    integer i;

    // Combinational read
    assign instr = rom[pc[7:2]];

    initial begin
        for (i = 0; i < 64; i = i + 1) begin
            rom[i] = 32'd0;
        end
        // Hex literals for the specific 7 instructions
        rom[0] = 32'h00421026; // xor r2, r2, r2
        rom[1] = 32'h34030001; // ori r3, r0, 1
        rom[2] = 32'h00632026; // xor r4, r3, r3
        rom[3] = 32'h08000005; // j L (Jump to index 5)
        rom[4] = 32'h00631826; // xor r3, r3, r3
        rom[5] = 32'h8C010000; // L: lw r1, 0(r0)
        rom[6] = 32'hAC610000; // sw r1, 0(r3)
    end
endmodule
