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

    // Write-first (read-during-write) forwarding.
    //
    // Writes land on posedge, reads are combinational, and ID/EX samples the
    // read on that same edge. A consumer in ID would therefore latch the value
    // from before the write when the producer is in WB in the same cycle --
    // the distance-3 RAW window. The forwarding unit cannot close it: by the
    // time the consumer reaches EX the producer has already left MEM/WB, so
    // ex_mem_rd and mem_wb_rd no longer match and both selects read 00.
    // Returning write_data on an address collision is the only fix.
    //
    // r0 is tested first so the bypass can never make r0 read non-zero. That
    // ordering matters: the write port is guarded by write_addr != 0, but a
    // bypass placed ahead of the r0 check would still expose write_data on a
    // read of r0.
    assign rs_data = (rs_addr == 5'd0)                      ? 32'd0      :
                     (reg_write && (write_addr == rs_addr)) ? write_data :
                                                              registers[rs_addr];

    assign rt_data = (rt_addr == 5'd0)                      ? 32'd0      :
                     (reg_write && (write_addr == rt_addr)) ? write_data :
                                                              registers[rt_addr];

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
