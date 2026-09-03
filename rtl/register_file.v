module register_file (
    input  wire        CLK,
    input  wire        reset,
    input  wire        reg_write,
    input  wire [4:0]  rs_addr,
    input  wire [4:0]  rt_addr,
    input  wire [4:0]  write_addr,
    input  wire [31:0] write_data,
    output wire [31:0] rs_data,
    output wire [31:0] rt_data
);
    reg [31:0] registers [0:31];
    integer i;

    //enforcing r0 = 0
    assign rs_data = (rs_addr == 5'd0) ? 32'd0 : registers[rs_addr];
    assign rt_data = (rt_addr == 5'd0) ? 32'd0 : registers[rt_addr];

    always @(posedge CLK) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1) begin
                registers[i] <= 32'd0;
            end
        end else if (reg_write && write_addr != 5'd0) begin
            registers[write_addr] <= write_data;
        end
    end
endmodule
