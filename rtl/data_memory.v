module data_memory (
    input  wire        CLK,
    input  wire        reset,
    input  wire        mem_read,
    input  wire        mem_write,
    input  wire [31:0] addr,
    input  wire [31:0] write_data,
    output wire [31:0] read_data
);
    reg [7:0] mem [0:255];
    integer i;

    assign read_data = (mem_read) ? {mem[addr[7:0]], mem[addr[7:0]+8'd1], mem[addr[7:0]+8'd2], mem[addr[7:0]+8'd3]} : 32'd0;

    always @(posedge CLK) begin
        if (reset) begin
            for (i = 0; i < 256; i = i + 1) begin
                mem[i] <= 8'd0;
            end
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
Endmodule
