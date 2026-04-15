`timescale 1ns / 1ps

// verilator lint_off WIDTHEXPAND

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: System Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 H-Core (Multi-Instance by Design)
// Module Name: h_core
//
// Description:
//   Hybrid Core - General purpose, multitasking, efisiensi daya
//   MULTI-INSTANCE: Di-instantiate banyak via generate loop di top.sv
//   Setiap instance punya CORE_ID unik dan menerima command dari broadcast bus.
//////////////////////////////////////////////////////////////////////////////////

module h_core #(
    parameter CORE_ID       = 0,
    parameter DATA_WIDTH    = 64,
    parameter ADDR_WIDTH    = 48,
    parameter ROB_SIZE      = 64,

    // Pipeline depth parameters
    parameter H_PIPE_ALU    = 4,
    parameter H_PIPE_MUL    = 6,
    parameter H_PIPE_DIV    = 12,
    parameter H_PIPE_LOAD   = 8,
    parameter H_PIPE_STORE  = 6,
    parameter H_PIPE_BRANCH = 5
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Command interface — BROADCAST BUS (multi-instance by design)
    input  wire [ADDR_WIDTH-1:0]        cmd_addr,
    input  wire [DATA_WIDTH-1:0]        cmd_data,
    input  wire                         cmd_valid,
    output reg                          cmd_ready,

    // Result interface
    output reg [DATA_WIDTH-1:0]         result,
    output reg                          result_valid,

    // Status
    output reg                          busy,
    output reg                          complete,

    // Error/Exception interface
    output reg                          error_flag,
    output reg [7:0]                    error_code,
    output reg                          error_valid,

    // Memory fabric interface
    output reg [ADDR_WIDTH-1:0]         fabric_addr,
    output reg                          fabric_rd_en,
    output reg                          fabric_wr_en,
    input  wire [DATA_WIDTH-1:0]        fabric_rd_data,
    output reg [DATA_WIDTH-1:0]         fabric_wr_data,
    input  wire                         fabric_ready
);

    // =========================================================================
    // Internal registers
    // =========================================================================
    reg [DATA_WIDTH-1:0]    register_file [0:31];
    reg [DATA_WIDTH-1:0]    rob_data [0:ROB_SIZE-1];
    reg [ADDR_WIDTH-1:0]    rob_addr [0:ROB_SIZE-1];
    reg                     rob_valid [0:ROB_SIZE-1];

    reg [5:0]               rob_head;
    reg [5:0]               rob_tail;

    reg [DATA_WIDTH-1:0]    alu_result;
    reg [DATA_WIDTH-1:0]    load_data;

    // Pipeline state
    reg [2:0]               pipeline_state;
    reg [15:0]              h_exec_counter;
    reg [15:0]              h_exec_target_cycles;

    // Saved command
    reg [ADDR_WIDTH-1:0]    saved_cmd_addr;
    reg [DATA_WIDTH-1:0]    saved_cmd_data;
    reg [7:0]               saved_opcode;

    localparam IDLE         = 3'b000;
    localparam FETCH        = 3'b001;
    localparam DECODE       = 3'b010;
    localparam EXECUTE      = 3'b011;
    localparam MEMORY       = 3'b100;
    localparam WRITEBACK    = 3'b101;
    localparam RETIRE       = 3'b110;
    localparam ERROR_STATE  = 3'b111;

    // ALU operations
    localparam OP_NOP       = 8'h00;
    localparam OP_ADD       = 8'h01;
    localparam OP_SUB       = 8'h02;
    localparam OP_MUL       = 8'h03;
    localparam OP_DIV       = 8'h04;
    localparam OP_AND       = 8'h05;
    localparam OP_OR        = 8'h06;
    localparam OP_XOR       = 8'h07;
    localparam OP_LOAD      = 8'h08;
    localparam OP_STORE     = 8'h09;
    localparam OP_BRANCH    = 8'h0A;

    // Error codes
    localparam ERR_ILLEGAL_OPCODE = 8'h01;

    // =========================================================================
    // Main pipeline
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipeline_state      <= IDLE;
            rob_head            <= 6'b0;
            rob_tail            <= 6'b0;
            busy                <= 1'b0;
            complete            <= 1'b0;
            cmd_ready           <= 1'b1;
            result              <= {DATA_WIDTH{1'b0}};
            result_valid        <= 1'b0;
            error_flag          <= 1'b0;
            error_code          <= 8'h0;
            error_valid         <= 1'b0;
            saved_cmd_addr      <= {ADDR_WIDTH{1'b0}};
            saved_cmd_data      <= {DATA_WIDTH{1'b0}};
            saved_opcode        <= 8'h0;
            fabric_rd_en        <= 1'b0;
            fabric_wr_en        <= 1'b0;
            fabric_addr         <= {ADDR_WIDTH{1'b0}};
            h_exec_counter      <= 16'h0;
            h_exec_target_cycles <= 16'h0;

            for (int i = 0; i < 32; i++)
                register_file[i] <= {DATA_WIDTH{1'b0}};
            for (int i = 0; i < ROB_SIZE; i++) begin
                rob_valid[i] <= 1'b0;
                rob_data[i] <= {DATA_WIDTH{1'b0}};
                rob_addr[i] <= {ADDR_WIDTH{1'b0}};
            end
        end else begin
            error_valid <= 1'b0;
            complete <= 1'b0;

            case (pipeline_state)
                IDLE: begin
                    cmd_ready <= 1'b1;
                    busy <= 1'b0;
                    if (cmd_valid && !busy) begin
                        saved_opcode <= cmd_data[7:0];
                        // Validate opcode
                        case (cmd_data[7:0])
                            OP_NOP: begin
                                // NOP — stay idle (suppress verbose logging)
                                // Only log on state change, not every cycle
                                // Removed: $display for NOP idle to prevent log spam
                            end
                            OP_ADD, OP_SUB, OP_AND, OP_OR, OP_XOR: begin
                                cmd_ready <= 1'b0;
                                busy <= 1'b1;
                                saved_cmd_addr <= cmd_addr;
                                saved_cmd_data <= cmd_data;
                                pipeline_state <= DECODE;
                            end
                            OP_MUL: begin
                                cmd_ready <= 1'b0;
                                busy <= 1'b1;
                                saved_cmd_addr <= cmd_addr;
                                saved_cmd_data <= cmd_data;
                                h_exec_counter <= 16'h0;
                                h_exec_target_cycles <= H_PIPE_MUL;
                                pipeline_state <= DECODE;
                            end
                            OP_DIV: begin
                                cmd_ready <= 1'b0;
                                busy <= 1'b1;
                                saved_cmd_addr <= cmd_addr;
                                saved_cmd_data <= cmd_data;
                                h_exec_counter <= 16'h0;
                                h_exec_target_cycles <= H_PIPE_DIV;
                                pipeline_state <= DECODE;
                            end
                            OP_LOAD: begin
                                cmd_ready <= 1'b0;
                                busy <= 1'b1;
                                saved_cmd_addr <= cmd_addr;
                                saved_cmd_data <= cmd_data;
                                h_exec_counter <= 16'h0;
                                h_exec_target_cycles <= H_PIPE_LOAD;
                                pipeline_state <= DECODE;
                            end
                            OP_STORE: begin
                                cmd_ready <= 1'b0;
                                busy <= 1'b1;
                                saved_cmd_addr <= cmd_addr;
                                saved_cmd_data <= cmd_data;
                                h_exec_counter <= 16'h0;
                                h_exec_target_cycles <= H_PIPE_STORE;
                                pipeline_state <= DECODE;
                            end
                            OP_BRANCH: begin
                                cmd_ready <= 1'b0;
                                busy <= 1'b1;
                                saved_cmd_addr <= cmd_addr;
                                saved_cmd_data <= cmd_data;
                                h_exec_counter <= 16'h0;
                                h_exec_target_cycles <= H_PIPE_BRANCH;
                                pipeline_state <= DECODE;
                            end
                            default: begin
                                error_flag <= 1'b1;
                                error_code <= ERR_ILLEGAL_OPCODE;
                                error_valid <= 1'b1;
                                busy <= 1'b0;
                                pipeline_state <= ERROR_STATE;
                                if (CORE_ID == 0)
                                    $display("[%0t] [H-CORE#%0d] ERROR: Invalid opcode 0x%02x", $time, CORE_ID, cmd_data[7:0]);
                            end
                        endcase
                    end
                end

                FETCH: begin
                    busy <= 1'b1;
                    pipeline_state <= DECODE;
                end

                DECODE: begin
                    // BUG-3 FIX: Check ROB not full before writing to prevent overflow
                    // ROB can hold ROB_SIZE entries, check if tail - head < ROB_SIZE
                    if ((rob_tail - rob_head) < ROB_SIZE) begin
                        busy <= 1'b1;
                        rob_addr[rob_tail] <= saved_cmd_addr;
                        rob_data[rob_tail] <= saved_cmd_data;
                        rob_valid[rob_tail] <= 1'b1;
                        rob_tail <= rob_tail + 1;
                        pipeline_state <= EXECUTE;
                    end else begin
                        // ROB full - stall and wait for retirement
                        busy <= 1'b1;
                        pipeline_state <= DECODE;  // Stay in DECODE
                        if (CORE_ID == 0)
                            $display("[%0t] [H-CORE#%0d] WARNING: ROB full, stalling", $time, CORE_ID);
                    end
                end

                EXECUTE: begin
                    busy <= 1'b1;
                    if (h_exec_counter < h_exec_target_cycles) begin
                        h_exec_counter <= h_exec_counter + 1;
                    end else begin
                        // FIX v2: Decode register operands from instruction
                        // Instruction format: [7:0]=opcode, [11:7]=rs1, [16:12]=rs2, [21:17]=rd
                        case (saved_opcode)
                            OP_ADD: alu_result <= register_file[saved_cmd_data[11:7]] + register_file[saved_cmd_data[16:12]];
                            OP_SUB: alu_result <= register_file[saved_cmd_data[11:7]] - register_file[saved_cmd_data[16:12]];
                            OP_AND: alu_result <= register_file[saved_cmd_data[11:7]] & register_file[saved_cmd_data[16:12]];
                            OP_OR:  alu_result <= register_file[saved_cmd_data[11:7]] | register_file[saved_cmd_data[16:12]];
                            OP_XOR: alu_result <= register_file[saved_cmd_data[11:7]] ^ register_file[saved_cmd_data[16:12]];
                            OP_MUL: alu_result <= register_file[saved_cmd_data[11:7]] * register_file[saved_cmd_data[16:12]];
                            OP_DIV: alu_result <= (register_file[saved_cmd_data[16:12]] != 0) ?
                                                    register_file[saved_cmd_data[11:7]] / register_file[saved_cmd_data[16:12]] : 64'hDEADBEEF;
                            OP_LOAD: begin
                                fabric_addr <= saved_cmd_addr;
                                fabric_rd_en <= 1'b1;
                                pipeline_state <= MEMORY;
                            end
                            OP_STORE: begin
                                // FIX v2: Use decoded rs1 for store data
                                fabric_wr_data <= register_file[saved_cmd_data[11:7]];
                                fabric_addr <= saved_cmd_addr;
                                fabric_wr_en <= 1'b1;
                                pipeline_state <= WRITEBACK;
                            end
                            OP_BRANCH: begin
                                pipeline_state <= WRITEBACK;
                            end
                            default: alu_result <= register_file[saved_cmd_data[11:7]];
                        endcase
                        if (saved_opcode != OP_LOAD && saved_opcode != OP_STORE)
                            pipeline_state <= WRITEBACK;
                    end
                end

                MEMORY: begin
                    fabric_rd_en <= 1'b0;
                    // CRITICAL FIX #1: Add 256-cycle timeout to prevent permanent stall
                    // Pattern copied from G-Core WAIT_L1 timeout mechanism
                    if (fabric_ready) begin
                        load_data <= fabric_rd_data;
                        alu_result <= fabric_rd_data;
                        h_exec_counter <= 16'h0;  // Reset counter
                        pipeline_state <= WRITEBACK;
                    end else if (h_exec_counter >= 16'hFF) begin
                        // TIMEOUT: Force transition to WRITEBACK with stale/dummy data
                        // This prevents permanent stall when memory fabric is unresponsive
                        if (CORE_ID == 0)
                            $display("[%0t] [H-CORE#%0d] MEMORY TIMEOUT: fabric_ready not asserted after 256 cycles", $time, CORE_ID);
                        load_data <= {DATA_WIDTH{1'b0}};  // Dummy data
                        alu_result <= {DATA_WIDTH{1'b0}};
                        h_exec_counter <= 16'h0;
                        pipeline_state <= WRITEBACK;
                    end else begin
                        h_exec_counter <= h_exec_counter + 1;
                    end
                end

                WRITEBACK: begin
                    fabric_wr_en <= 1'b0;
                    // FIX v2: Write to destination register (rd from ROB entry)
                    register_file[rob_data[rob_head][21:17]] <= alu_result;
                    result <= alu_result;
                    pipeline_state <= RETIRE;
                end

                RETIRE: begin
                    // FIXED BUG #4: Retire ALL completed entries quickly
                    // Use combinational logic to find how many we can retire
                    integer retire_count;
                    retire_count = 0;
                    
                    // Count consecutive valid entries from head
                    while (retire_count < ROB_SIZE && 
                           rob_head + retire_count != rob_tail && 
                           rob_valid[rob_head + retire_count]) begin
                        retire_count = retire_count + 1;
                    end
                    
                    // Retire all at once (unroll in hardware)
                    if (retire_count > 0) begin
                        integer i;
                        for (i = 0; i < retire_count; i = i + 1) begin
                            rob_valid[rob_head + i] <= 1'b0;
                        end
                        rob_head <= rob_head + retire_count;
                        result_valid <= 1'b1;
                        complete <= 1'b1;
                    end
                    
                    busy <= 1'b0;
                    pipeline_state <= IDLE;
                    // Only log for non-zero results and core #0
                    if (CORE_ID == 0 && alu_result != 0)
                        $display("[%0t] [H-CORE#%0d] RETIRE complete, result=0x%h", $time, CORE_ID, result);
                end

                ERROR_STATE: begin
                    busy <= 1'b0;
                    cmd_ready <= 1'b1;
                    // Auto-recover on next cycle
                    pipeline_state <= IDLE;
                end

                default: pipeline_state <= IDLE;
            endcase
        end
    end

endmodule
