module processor (
    input wire CLK,
    input wire reset
);

    // IF STAGE WIRES
    reg  [31:0] pc;
    wire [31:0] pc_plus4;
    wire [31:0] instr_if;
    wire [31:0] jump_target;
    wire        jump_taken;   // from ID stage control
    wire        pc_write;     // from hazard detection unit
    wire        if_id_write;  // from hazard detection unit

    assign pc_plus4 = pc + 32'd4;

    // IF/ID PIPELINE REGISTER OUTPUTS
    // Only bits [31:28] are read, by the jump target below. That is the J-type
    // rule: the target inherits the top 4 bits of PC+4 and takes the other 28
    // from the instruction. The lower bits are carried but never consumed --
    // they would be needed by a branch adder, and there are no branches here.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] if_id_pc_plus4;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] if_id_instr;

    // Decode fields from IF/ID instruction
    wire [5:0]  if_id_opcode = if_id_instr[31:26];
    wire [4:0]  if_id_rs     = if_id_instr[25:21];
    wire [4:0]  if_id_rt     = if_id_instr[20:16];
    wire [4:0]  if_id_rd     = if_id_instr[15:11];
    wire [15:0] if_id_imm    = if_id_instr[15:0];
    wire [5:0]  if_id_funct  = if_id_instr[5:0];

    // ID STAGE WIRES
    wire [31:0] rs_data_id, rt_data_id;
    wire [31:0] sign_ext_imm;

    // Control signals from control unit
    wire        ctrl_reg_dst, ctrl_alu_src, ctrl_mem_to_reg;
    wire        ctrl_reg_write, ctrl_mem_read, ctrl_mem_write;
    wire [1:0]  ctrl_alu_op;
    wire        ctrl_reads_rs, ctrl_reads_rt;
    wire        ctrl_jump;

    // Jump target address: { PC+4[31:28], instr[25:0], 2'b00 }
    assign jump_target = { if_id_pc_plus4[31:28], if_id_instr[25:0], 2'b00 };
    assign jump_taken  = ctrl_jump;

    // Write-back data and address (fed back to register file from MEM/WB)
    wire [31:0] wb_write_data;
    wire [4:0]  wb_write_addr;
    wire        wb_reg_write;

    // ID/EX PIPELINE REGISTER OUTPUTS
    wire        id_ex_reg_dst, id_ex_alu_src, id_ex_mem_to_reg;
    wire        id_ex_reg_write, id_ex_mem_read, id_ex_mem_write;
    wire [1:0]  id_ex_alu_op;
    wire [31:0] id_ex_rs_data, id_ex_rt_data, id_ex_sign_ext_imm;
    wire [4:0]  id_ex_rs_addr, id_ex_rt_addr, id_ex_rd_addr;

    // EX STAGE WIRES
    wire [4:0]  ex_reg_dst_addr;   // after RegDst mux
    wire [31:0] alu_input_a;       // after ForwardRs mux
    wire [31:0] alu_input_b_pre;   // after ForwardRt mux
    wire [31:0] alu_input_b;       // after ALUSrc mux
    wire [31:0] alu_result;
    wire [1:0]  forward_rs, forward_rt;

    // EX/MEM pipeline register outputs (needed for forwarding)
    wire        ex_mem_mem_to_reg, ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write;
    wire [31:0] ex_mem_alu_result, ex_mem_rt_data;
    wire [4:0]  ex_mem_rd_addr;

    // MEM/WB pipeline register outputs (needed for forwarding)
    wire        mem_wb_mem_to_reg, mem_wb_reg_write;
    wire [31:0] mem_wb_alu_result, mem_wb_mem_read_data;
    wire [4:0]  mem_wb_rd_addr;

    // HAZARD DETECTION
    wire        id_ex_flush;

    // MEM STAGE WIRES
    wire [31:0] mem_read_data;

    // WB STAGE
    assign wb_write_data = mem_wb_mem_to_reg ? mem_wb_mem_read_data : mem_wb_alu_result;
    assign wb_write_addr = mem_wb_rd_addr;
    assign wb_reg_write  = mem_wb_reg_write;

    // PC LOGIC
    always @(posedge CLK) begin
        if (reset)
            pc <= 32'd0;
        else if (jump_taken)
            pc <= jump_target;
        else if (pc_write)
            pc <= pc_plus4;
        // else: stall - hold current PC
    end

    // MODULE INSTANTIATIONS

    // Instruction Memory
    instruction_memory imem (
        .pc    (pc),
        .instr (instr_if)
    );

    // IF/ID Pipeline Register
    // flush on jump
    IF_ID if_id_reg (
        .CLK          (CLK),
        .reset        (reset),
        .flush        (jump_taken),
        .write_enable (if_id_write),
        .pc_plus4_in  (pc_plus4),
        .instr_in     (instr_if),
        .pc_plus4_out (if_id_pc_plus4),
        .instr_out    (if_id_instr)
    );

    // Register File
    register_file regfile (
        .CLK        (CLK),
        .reset      (reset),
        .reg_write  (wb_reg_write),
        .rs_addr    (if_id_rs),
        .rt_addr    (if_id_rt),
        .write_addr (wb_write_addr),
        .write_data (wb_write_data),
        .rs_data    (rs_data_id),
        .rt_data    (rt_data_id)
    );

    // Sign Extend
    sign_extend se (
        .in  (if_id_imm),
        .out (sign_ext_imm)
    );

    // Control Unit
    control_unit ctrl (
        .opcode   (if_id_opcode),
        .funct    (if_id_funct),
        .RegDst   (ctrl_reg_dst),
        .ALUSrc   (ctrl_alu_src),
        .MemToReg (ctrl_mem_to_reg),
        .RegWrite (ctrl_reg_write),
        .MemRead  (ctrl_mem_read),
        .MemWrite (ctrl_mem_write),
        .ALUOp    (ctrl_alu_op),
        .Jump     (ctrl_jump),
        .ReadsRs  (ctrl_reads_rs),
        .ReadsRt  (ctrl_reads_rt)
    );

    // Hazard Detection Unit
    hazard_detection_unit hdu (
        .id_ex_mem_read (id_ex_mem_read),
        .id_ex_rt       (id_ex_rt_addr),
        .if_id_rs       (if_id_rs),
        .if_id_rt       (if_id_rt),
        .if_id_reads_rs (ctrl_reads_rs),
        .if_id_reads_rt (ctrl_reads_rt),
        .pc_write       (pc_write),
        .if_id_write    (if_id_write),
        .id_ex_flush    (id_ex_flush)
    );

    // ID/EX Pipeline Register
    // flush = jump_taken (insert NOP) OR id_ex_flush (load-use stall NOP)
    ID_EX id_ex_reg (
        .CLK              (CLK),
        .reset            (reset),
        .flush            (jump_taken | id_ex_flush),
        // Control in - zeroed on flush to create NOP
        .RegDst_in        (ctrl_reg_dst),
        .ALUSrc_in        (ctrl_alu_src),
        .MemToReg_in      (ctrl_mem_to_reg),
        .RegWrite_in      (ctrl_reg_write),
        .MemRead_in       (ctrl_mem_read),
        .MemWrite_in      (ctrl_mem_write),
        .ALUOp_in         (ctrl_alu_op),
        // Data in
        .rs_data_in       (rs_data_id),
        .rt_data_in       (rt_data_id),
        .sign_ext_imm_in  (sign_ext_imm),
        .rs_addr_in       (if_id_rs),
        .rt_addr_in       (if_id_rt),
        .rd_addr_in       (if_id_rd),
        // Control out
        .RegDst_out       (id_ex_reg_dst),
        .ALUSrc_out       (id_ex_alu_src),
        .MemToReg_out     (id_ex_mem_to_reg),
        .RegWrite_out     (id_ex_reg_write),
        .MemRead_out      (id_ex_mem_read),
        .MemWrite_out     (id_ex_mem_write),
        .ALUOp_out        (id_ex_alu_op),
        // Data out
        .rs_data_out      (id_ex_rs_data),
        .rt_data_out      (id_ex_rt_data),
        .sign_ext_imm_out (id_ex_sign_ext_imm),
        .rs_addr_out      (id_ex_rs_addr),
        .rt_addr_out      (id_ex_rt_addr),
        .rd_addr_out      (id_ex_rd_addr)
    );

    // Forwarding Unit
    forwarding_unit fwd (
        .id_ex_rs         (id_ex_rs_addr),
        .id_ex_rt         (id_ex_rt_addr),
        .ex_mem_rd        (ex_mem_rd_addr),
        .ex_mem_reg_write (ex_mem_reg_write),
        .mem_wb_rd        (mem_wb_rd_addr),
        .mem_wb_reg_write (mem_wb_reg_write),
        .forward_rs       (forward_rs),
        .forward_rt       (forward_rt)
    );

    // ForwardRs MUX: select ALU input A
    // 00 = register file, 01 = EX/MEM ALU result, 10 = MEM/WB write-back data
    assign alu_input_a = (forward_rs == 2'b01) ? ex_mem_alu_result :
                         (forward_rs == 2'b10) ? wb_write_data     :
                                                 id_ex_rs_data;

    // ForwardRt MUX: select ALU input B (before ALUSrc mux)
    assign alu_input_b_pre = (forward_rt == 2'b01) ? ex_mem_alu_result :
                             (forward_rt == 2'b10) ? wb_write_data     :
                                                     id_ex_rt_data;

    // ALUSrc MUX: select between register value and sign-extended immediate
    assign alu_input_b = id_ex_alu_src ? id_ex_sign_ext_imm : alu_input_b_pre;

    // ALU
    alu alu_inst (
        .a        (alu_input_a),
        .b        (alu_input_b),
        .alu_ctrl (id_ex_alu_op),
        .result   (alu_result)
    );

    // RegDst MUX: select write-back destination register
    // 0 = rt (I-type: lw, ori), 1 = rd (R-type: xor)
    assign ex_reg_dst_addr = id_ex_reg_dst ? id_ex_rd_addr : id_ex_rt_addr;

    // EX/MEM Pipeline Register
    EX_MEM ex_mem_reg (
        .CLK            (CLK),
        .reset          (reset),
        // Control in
        .MemToReg_in    (id_ex_mem_to_reg),
        .RegWrite_in    (id_ex_reg_write),
        .MemRead_in     (id_ex_mem_read),
        .MemWrite_in    (id_ex_mem_write),
        // Data in
        .alu_result_in  (alu_result),
        .rt_data_in     (alu_input_b_pre), // un-muxed rt value for sw store
        .rd_addr_in     (ex_reg_dst_addr),
        // Control out
        .MemToReg_out   (ex_mem_mem_to_reg),
        .RegWrite_out   (ex_mem_reg_write),
        .MemRead_out    (ex_mem_mem_read),
        .MemWrite_out   (ex_mem_mem_write),
        // Data out
        .alu_result_out (ex_mem_alu_result),
        .rt_data_out    (ex_mem_rt_data),
        .rd_addr_out    (ex_mem_rd_addr)
    );

    // Data Memory
    data_memory dmem (
        .CLK        (CLK),
        .reset      (reset),
        .mem_read   (ex_mem_mem_read),
        .mem_write  (ex_mem_mem_write),
        .addr       (ex_mem_alu_result),
        .write_data (ex_mem_rt_data),
        .read_data  (mem_read_data)
    );

    // MEM/WB Pipeline Register
    MEM_WB mem_wb_reg (
        .CLK               (CLK),
        .reset             (reset),
        // Control in
        .MemToReg_in       (ex_mem_mem_to_reg),
        .RegWrite_in       (ex_mem_reg_write),
        // Data in
        .alu_result_in     (ex_mem_alu_result),
        .mem_read_data_in  (mem_read_data),
        .rd_addr_in        (ex_mem_rd_addr),
        // Control out
        .MemToReg_out      (mem_wb_mem_to_reg),
        .RegWrite_out      (mem_wb_reg_write),
        // Data out
        .alu_result_out    (mem_wb_alu_result),
        .mem_read_data_out (mem_wb_mem_read_data),
        .rd_addr_out       (mem_wb_rd_addr)
    );

endmodule
