module data_memory (
    input  wire        CLK,
    input  wire        reset,
    input  wire        mem_read,
    input  wire        mem_write,
    // Only addr[7:0] selects a byte; this memory is 256 bytes and there is no
    // address decode above it, so the top 24 bits are ignored by design.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [31:0] addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [31:0] write_data,
    output wire [31:0] read_data
);
    reg [7:0] mem [0:255];
    integer i;

    assign read_data = (mem_read) ? {mem[addr[7:0]], mem[addr[7:0]+8'd1], mem[addr[7:0]+8'd2], mem[addr[7:0]+8'd3]} : 32'd0;

    always @(posedge CLK) begin
        if (reset) begin
            // A 2-state lint zero-initialises mem, and the store path can reach
            // every one of these 256 bytes, so the loop is provably redundant
            // there. Icarus is 4-state: mem starts as X and this loop is what
            // makes an unwritten word read as 0 rather than X. make test runs
            // on Icarus, so the loop stays.
            /* verilator lint_off UNUSEDLOOP */
            for (i = 0; i < 256; i = i + 1) begin
                mem[i] <= 8'd0;
            end
            /* verilator lint_on UNUSEDLOOP */
            mem[0] <= 8'd0;
            mem[1] <= 8'd0;
            mem[2] <= 8'd0;
            mem[3] <= 8'd20; // Big-endian 32-bit 20
        end else if (mem_write) begin
            mem[addr[7:0]]        <= write_data[31:24];
            mem[addr[7:0]+8'd1]   <= write_data[23:16];
            mem[addr[7:0]+8'd2]   <= write_data[15:8];
            mem[addr[7:0]+8'd3]   <= write_data[7:0];
        end
    end
endmodule
