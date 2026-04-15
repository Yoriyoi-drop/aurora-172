`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 11 April 2026
// Design Name: AURORA-172 Global Scheduler — Single-Queue
// Module Name: global_scheduler_sq
//
// Description:
//   Single-queue scheduler — semua task masuk satu FIFO,
//   arbitrase by priority + aging.
//   Tidak ada multi-queue logic — clean & simple.
//////////////////////////////////////////////////////////////////////////////////

module global_scheduler_sq #(
    parameter DATA_WIDTH       = 128,  // OPTIMIZED: 64→128 for wider task data
    parameter ADDR_WIDTH       = 48,
    parameter QUEUE_DEPTH      = 32,
    parameter AGING_RATE       = 8,
    parameter MAX_AGING        = 8,
    parameter BASE_PRIORITY_G  = 0,
    parameter BASE_PRIORITY_A  = 2,
    parameter BASE_PRIORITY_N  = 3
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Task input
    input  wire [ADDR_WIDTH-1:0]        g_task_addr,
    input  wire [31:0]                  g_task_data,
    input  wire                         g_task_valid,
    output wire                         g_task_ready,
    output wire [DATA_WIDTH-1:0]        g_task_result,
    output wire                         g_task_result_valid,

    input  wire [ADDR_WIDTH-1:0]        a_task_addr,
    input  wire [63:0]                  a_task_data,
    input  wire                         a_task_valid,
    output wire                         a_task_ready,
    output wire [DATA_WIDTH-1:0]        a_task_result,
    output wire                         a_task_result_valid,

    input  wire                         npu_task_valid,
    output wire                         npu_task_ready,
    output wire [DATA_WIDTH-1:0]        npu_task_result,
    output wire                         npu_task_result_valid,

    // G-Core dispatch
    output wire [ADDR_WIDTH-1:0]        g_core_cmd_addr,
    output wire [31:0]                  g_core_cmd_data,
    output wire                         g_core_cmd_valid,
    input  wire                         g_core_cmd_ready,
    input  wire                         g_core_busy,
    input  wire                         g_core_complete,
    input  wire [DATA_WIDTH-1:0]        g_core_result,
    input  wire                         g_core_error_flag,
    input  wire                         g_core_error_valid,

    // A-Core dispatch
    output wire [ADDR_WIDTH-1:0]        a_core_cmd_addr,
    output wire [63:0]                  a_core_cmd_data,
    output wire                         a_core_cmd_valid,
    input  wire                         a_core_cmd_ready,
    input  wire                         a_core_busy,
    input  wire                         a_core_complete,
    input  wire [DATA_WIDTH-1:0]        a_core_result,
    output wire                         a_core_result_ready,  // NEW: Pull result from A-Core FIFO

    // NPU dispatch
    output wire                         npu_dispatch_valid,
    input  wire                         npu_dispatch_ready,
    input  wire                         npu_busy,
    input  wire                         npu_complete,
    input  wire [DATA_WIDTH-1:0]        npu_result,

    // Debug / performance
    output wire [63:0]                  sched_total_dispatched,
    output wire [63:0]                  sched_total_completed,
    output wire [63:0]                  sched_total_stalled,
    output wire [63:0]                  sched_stall_resource_wait,
    output wire [63:0]                  sched_stall_queue_contention,
    output wire [31:0]                  sched_queue_depth,
    output wire [31:0]                  sched_max_queue_depth,
    output wire [31:0]                  sched_conflict_count,
    output wire [7:0]                   sched_gaming_priority,
    output wire [7:0]                   sched_ai_priority,
    output wire [7:0]                   sched_npu_priority,
    output wire [31:0]                  sched_aging_tasks,
    output wire [31:0]                  sched_rr_rotations,
    output wire [31:0]                  sched_queue_avoidance,
    output wire [31:0]                  sched_watchdog_resets,
    output wire [31:0]                  sched_bp_queue_full_rejections,
    output wire [31:0]                  sched_bp_timeout_stalls,
    output wire [31:0]                  sched_bp_actual_accepts,
    output wire [31:0]                  sched_hazard_raw,
    output wire [31:0]                  sched_hazard_war,
    output wire [31:0]                  sched_hazard_waw,
    output wire [31:0]                  sched_hazard_structural,
    output wire [31:0]                  sched_hazard_dependency
);

    localparam TASK_GAMING = 2'b00;
    localparam TASK_AI     = 2'b01;
    localparam TASK_NPU    = 2'b10;

    // ── Queue storage ──
    reg [1:0]               queue_type      [0:QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0]    queue_addr      [0:QUEUE_DEPTH-1];
    reg [63:0]              queue_data      [0:QUEUE_DEPTH-1];
    reg                     queue_valid     [0:QUEUE_DEPTH-1];
    reg                     queue_dispatched[0:QUEUE_DEPTH-1];
    reg [7:0]               queue_aging     [0:QUEUE_DEPTH-1];
    reg [7:0]               queue_wait_cycles[0:QUEUE_DEPTH-1];

    reg [$clog2(QUEUE_DEPTH)-1:0] head_idx;
    reg [$clog2(QUEUE_DEPTH)-1:0] tail_idx;
    reg [31:0]               queue_count;

    // ── Active task ──
    reg [1:0]               active_task_type;
    reg                     active_task_valid;
    reg [ADDR_WIDTH-1:0]    active_task_addr;
    reg [63:0]              active_task_data;
    reg                     task_being_served;
    reg [15:0]              active_task_wait_counter;
    reg [$clog2(QUEUE_DEPTH)-1:0] active_queue_idx;  // NEW: Track which queue entry is being served
    reg                     active_queue_idx_valid;   // NEW: Flag to track if active_queue_idx is valid

    // ── Pending result ──
    reg [DATA_WIDTH-1:0]    pending_result;
    reg                     pending_result_valid;
    reg [1:0]               pending_result_type;
    reg                     g_core_complete_prev;
    reg                     a_core_complete_prev;
    reg                     npu_complete_prev;

    // ── Arbiter ──
    reg [1:0]               arbiter_select;  // FIXED: 2-bit to support values 0, 1, 2 (was 1-bit)

    // ── Counters ──
    reg [63:0]              counter_dispatched;
    reg [63:0]              counter_completed;
    reg [63:0]              stall_waiting_for_resource;
    reg [63:0]              stall_queue_contention;
    reg [31:0]              counter_conflicts;
    reg [31:0]              max_queue_depth_seen;
    reg [31:0]              aging_boosted_tasks;
    reg [31:0]              rr_rotations;
    reg [31:0]              queue_aware_skips;
    reg [31:0]              bp_queue_full_rejections;
    reg [31:0]              bp_timeout_stalls;
    reg [31:0]              bp_actual_accepts;
    reg [7:0]               effective_priority_g;
    reg [7:0]               effective_priority_a;
    reg [7:0]               effective_priority_n;
    reg [31:0]              hazard_structural_count;
    reg [31:0]              hazard_raw_count;
    reg                     g_core_error_prev;
    reg                     skip_g_dispatch;
    reg [7:0]               skip_g_counter;
    reg [31:0]              rv_cleaned;  // Module-level cleanup temp
    integer                 li_cleanup;
    integer                 li_prio;
    integer                 li_assert;  // For runtime assertions
    integer                 i_assert;   // For runtime assertions
    reg [15:0]              task_0_wait_counter;  // For starvation detection
    
    // Variables used in dispatch logic (must be declared at module level for Icarus)
    integer                 li;  // Main loop iterator
    integer                 best_idx;
    reg [7:0]               best_prio;
    reg                     can_dispatch;
    integer                 actual_valid_count;
    reg [7:0]               ep;  // Effective priority temp

    // ── Helper functions ──
    function automatic reg [7:0] calc_eff_prio;
        input [1:0] t;
        input [7:0] aging;
        case (t)
            TASK_GAMING: calc_eff_prio = BASE_PRIORITY_G - aging;
            TASK_AI:     calc_eff_prio = BASE_PRIORITY_A - aging;
            TASK_NPU:    calc_eff_prio = BASE_PRIORITY_N - aging;
            default:     calc_eff_prio = 8'd255;
        endcase
    endfunction

    // ── Assignments ──
    assign g_task_ready  = (queue_count < QUEUE_DEPTH);
    assign a_task_ready  = (queue_count < QUEUE_DEPTH);
    assign npu_task_ready = (queue_count < QUEUE_DEPTH);

    assign g_task_result       = (pending_result_type == TASK_GAMING && pending_result_valid) ? pending_result : {DATA_WIDTH{1'b0}};
    assign g_task_result_valid = (pending_result_type == TASK_GAMING && pending_result_valid);
    assign a_task_result       = (pending_result_type == TASK_AI && pending_result_valid) ? pending_result : {DATA_WIDTH{1'b0}};
    assign a_task_result_valid = (pending_result_type == TASK_AI && pending_result_valid);
    assign npu_task_result     = (pending_result_type == TASK_NPU && pending_result_valid) ? pending_result : {DATA_WIDTH{1'b0}};
    assign npu_task_result_valid = (pending_result_type == TASK_NPU && pending_result_valid);

    assign g_core_cmd_addr  = (arbiter_select == 0) ? active_task_addr : {ADDR_WIDTH{1'b0}};
    assign g_core_cmd_data  = (arbiter_select == 0) ? active_task_data[31:0] : 32'b0;
    assign g_core_cmd_valid = (arbiter_select == 0) && active_task_valid && !g_core_busy && !skip_g_dispatch;

    assign a_core_cmd_addr  = (arbiter_select == 1) ? active_task_addr : {ADDR_WIDTH{1'b0}};
    assign a_core_cmd_data  = (arbiter_select == 1) ? active_task_data : 64'b0;
    assign a_core_cmd_valid = (arbiter_select == 1) && active_task_valid && !a_core_busy;
    
    // DEBUG: Track why A-Core command is not being sent
    reg a_core_cmd_valid_prev_debug;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_core_cmd_valid_prev_debug <= 1'b0;
        end else begin
            a_core_cmd_valid_prev_debug <= a_core_cmd_valid;
        end
    end
    
    wire a_core_cmd_valid_edge_debug = a_core_cmd_valid && !a_core_cmd_valid_prev_debug;
    always @(posedge clk) begin
        if (a_core_cmd_valid_edge_debug)
            $display("[%0t] [SQ-SCHEDULER] 📤 a_core_cmd_valid asserted! arbiter_select=%0d, active_task_valid=%0d, a_core_busy=%0d", 
                     $time, arbiter_select, active_task_valid, a_core_busy);
    end

    assign npu_dispatch_valid = (arbiter_select == 2) && active_task_valid && !npu_busy;
    
    // NEW: Assert result_ready when A-Core complete is detected (pull from FIFO)
    assign a_core_result_ready = a_core_complete && task_being_served && active_task_type == TASK_AI;
    
    // DEBUG: Monitor active_task_valid and arbiter_select
    reg active_task_valid_prev_mon;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_task_valid_prev_mon <= 1'b0;
        end else begin
            active_task_valid_prev_mon <= active_task_valid;
            // Print when active_task_valid is asserted with arbiter_select == 1
            if (active_task_valid && !active_task_valid_prev_mon && arbiter_select == 1)
                $display("[%0t] [SQ-SCHEDULER] 🔍 active_task_valid=1, arbiter_select=1, a_core_busy=%0d, a_core_cmd_valid=%0d", 
                         $time, a_core_busy, a_core_cmd_valid);
        end
    end

    assign sched_total_dispatched     = counter_dispatched;
    assign sched_total_completed      = counter_completed;
    assign sched_total_stalled        = stall_waiting_for_resource + stall_queue_contention;
    assign sched_stall_resource_wait  = stall_waiting_for_resource;
    assign sched_stall_queue_contention = stall_queue_contention;
    assign sched_queue_depth          = queue_count;
    assign sched_max_queue_depth      = max_queue_depth_seen;
    assign sched_conflict_count       = counter_conflicts;
    assign sched_gaming_priority      = effective_priority_g;
    assign sched_ai_priority          = effective_priority_a;
    assign sched_npu_priority         = effective_priority_n;
    assign sched_aging_tasks          = aging_boosted_tasks;
    assign sched_rr_rotations         = rr_rotations;
    assign sched_queue_avoidance      = queue_aware_skips;
    assign sched_watchdog_resets      = 32'd0;
    assign sched_bp_queue_full_rejections = bp_queue_full_rejections;
    assign sched_bp_timeout_stalls    = bp_timeout_stalls;
    assign sched_bp_actual_accepts    = bp_actual_accepts;
    assign sched_hazard_raw           = hazard_raw_count;
    assign sched_hazard_war           = 32'd0;
    assign sched_hazard_waw           = 32'd0;
    assign sched_hazard_structural    = hazard_structural_count;
    assign sched_hazard_dependency    = 32'd0;

    // ── Main logic ──
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_idx <= 0; tail_idx <= 0; queue_count <= 0;
            active_task_valid <= 1'b0; active_task_type <= TASK_GAMING;
            active_task_addr <= {ADDR_WIDTH{1'b0}}; active_task_data <= 64'b0;
            task_being_served <= 1'b0; active_task_wait_counter <= 16'b0;
            active_queue_idx <= 0; active_queue_idx_valid <= 1'b0;  // NEW: Reset active queue tracking
            pending_result_valid <= 1'b0; pending_result <= {DATA_WIDTH{1'b0}};
            pending_result_type <= TASK_GAMING;
            arbiter_select <= 0;
            counter_dispatched <= 64'b0; counter_completed <= 64'b0;
            stall_waiting_for_resource <= 64'b0; stall_queue_contention <= 64'b0;
            counter_conflicts <= 32'b0; max_queue_depth_seen <= 32'b0;
            aging_boosted_tasks <= 32'b0; rr_rotations <= 32'b0;
            queue_aware_skips <= 32'b0;
            bp_queue_full_rejections <= 32'b0; bp_timeout_stalls <= 32'b0;
            bp_actual_accepts <= 32'b0;
            effective_priority_g <= BASE_PRIORITY_G;
            effective_priority_a <= BASE_PRIORITY_A;
            effective_priority_n <= BASE_PRIORITY_N;
            hazard_structural_count <= 32'b0; hazard_raw_count <= 32'b0;
            g_core_error_prev <= 1'b0; skip_g_dispatch <= 1'b0; skip_g_counter <= 8'b0;
            g_core_complete_prev <= 1'b0; a_core_complete_prev <= 1'b0; npu_complete_prev <= 1'b0;
            for (li = 0; li < QUEUE_DEPTH; li = li + 1) begin
                queue_valid[li] <= 1'b0; queue_dispatched[li] <= 1'b0;
                queue_type[li] <= 2'b0; queue_addr[li] <= {ADDR_WIDTH{1'b0}};
                queue_data[li] <= 64'b0; queue_aging[li] <= 8'b0; queue_wait_cycles[li] <= 8'b0;
            end
        end else begin
            // Edge detection
            g_core_complete_prev <= g_core_complete;
            a_core_complete_prev <= a_core_complete;
            npu_complete_prev  <= npu_complete;

            // Error detection
            if (g_core_error_valid && !g_core_error_prev) begin
                skip_g_dispatch <= 1'b1;
                skip_g_counter  <= 8'd10;
                if (active_task_valid && active_task_type == TASK_GAMING) begin
                    active_task_valid <= 1'b0;
                    task_being_served <= 1'b0;
                end
            end
            g_core_error_prev <= g_core_error_valid;
            if (skip_g_counter > 0) begin
                skip_g_counter <= skip_g_counter - 1;
                if (skip_g_counter == 1) skip_g_dispatch <= 1'b0;
            end

            // ── ENQUEUE ──
            if (queue_count < QUEUE_DEPTH) begin
                if (g_task_valid) begin
                    queue_type[tail_idx]      <= TASK_GAMING;
                    queue_addr[tail_idx]      <= g_task_addr;
                    queue_data[tail_idx]      <= {32'b0, g_task_data};
                    queue_valid[tail_idx]     <= 1'b1;
                    queue_dispatched[tail_idx]<= 1'b0;
                    queue_aging[tail_idx]     <= 8'b0;
                    queue_wait_cycles[tail_idx]<= 8'b0;
                    tail_idx <= (tail_idx == QUEUE_DEPTH-1) ? 0 : tail_idx + 1;
                    queue_count <= queue_count + 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    $display("[%0t] [SQ-SCHEDULER] 📥 Enqueued G task, queue_count=%0d", $time, queue_count+1);
                end else if (a_task_valid) begin
                    queue_type[tail_idx]      <= TASK_AI;
                    queue_addr[tail_idx]      <= a_task_addr;
                    queue_data[tail_idx]      <= a_task_data;
                    queue_valid[tail_idx]     <= 1'b1;
                    queue_dispatched[tail_idx]<= 1'b0;
                    queue_aging[tail_idx]     <= 8'b0;
                    queue_wait_cycles[tail_idx]<= 8'b0;
                    tail_idx <= (tail_idx == QUEUE_DEPTH-1) ? 0 : tail_idx + 1;
                    queue_count <= queue_count + 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    $display("[%0t] [SQ-SCHEDULER] 📥 Enqueued A task, queue_count=%0d", $time, queue_count+1);
                end else if (npu_task_valid) begin
                    queue_type[tail_idx]      <= TASK_NPU;
                    queue_addr[tail_idx]      <= {ADDR_WIDTH{1'b0}};
                    queue_data[tail_idx]      <= 64'b0;  // NPU tasks don't carry data to A-Core
                    queue_valid[tail_idx]     <= 1'b1;
                    queue_dispatched[tail_idx]<= 1'b0;
                    queue_aging[tail_idx]     <= 8'b0;
                    queue_wait_cycles[tail_idx]<= 8'b0;
                    tail_idx <= (tail_idx == QUEUE_DEPTH-1) ? 0 : tail_idx + 1;
                    queue_count <= queue_count + 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    $display("[%0t] [SQ-SCHEDULER] 📥 Enqueued NPU task, queue_count=%0d", $time, queue_count+1);
                end
            end else begin
                if (g_task_valid || a_task_valid || npu_task_valid)
                    bp_queue_full_rejections <= bp_queue_full_rejections + 1;
            end

            // ── AGING ──
            for (li = 0; li < QUEUE_DEPTH; li = li + 1) begin
                if (queue_valid[li] && !queue_dispatched[li]) begin
                    queue_wait_cycles[li] <= queue_wait_cycles[li] + 1;
                    if (queue_wait_cycles[li] >= AGING_RATE && queue_aging[li] < MAX_AGING) begin
                        queue_aging[li] <= queue_aging[li] + 1;
                        aging_boosted_tasks <= aging_boosted_tasks + 1;
                    end
                end
            end

            // ── Completion (edge detect) ──
            // FIXED BUG #1: Decrement queue_count when task completes
            // FIXED QUEUE DE-SYNC: Clear queue_valid and queue_dispatched for completed entry
            if (g_core_complete && !g_core_complete_prev && task_being_served && active_task_type == TASK_GAMING) begin
                counter_completed <= counter_completed + 1;
                pending_result <= g_core_result; pending_result_valid <= 1'b1;
                pending_result_type <= TASK_GAMING;
                active_task_valid <= 1'b0; task_being_served <= 1'b0;
                // Clear queue entry to prevent de-sync
                if (active_queue_idx_valid) begin
                    queue_valid[active_queue_idx] <= 1'b0;
                    queue_dispatched[active_queue_idx] <= 1'b0;
                    active_queue_idx_valid <= 1'b0;
                end
                if (queue_count > 0) queue_count <= queue_count - 1;  // FIX: Decrement on completion
            end
            if (a_core_complete && !a_core_complete_prev && task_being_served && active_task_type == TASK_AI) begin
                $display("[%0t] [SQ-SCHEDULER] ✓ A-Core completion detected! Pulling result from FIFO", $time);
                counter_completed <= counter_completed + 1;
                pending_result <= a_core_result; pending_result_valid <= 1'b1;
                pending_result_type <= TASK_AI;
                active_task_valid <= 1'b0; task_being_served <= 1'b0;
                // Clear queue entry to prevent de-sync
                if (active_queue_idx_valid) begin
                    queue_valid[active_queue_idx] <= 1'b0;
                    queue_dispatched[active_queue_idx] <= 1'b0;
                    active_queue_idx_valid <= 1'b0;
                end
                if (queue_count > 0) queue_count <= queue_count - 1;  // FIX: Decrement on completion
            end
            if (npu_complete && !npu_complete_prev && task_being_served && active_task_type == TASK_NPU) begin
                counter_completed <= counter_completed + 1;
                pending_result <= npu_result; pending_result_valid <= 1'b1;
                pending_result_type <= TASK_NPU;
                active_task_valid <= 1'b0; task_being_served <= 1'b0;
                // Clear queue entry to prevent de-sync
                if (active_queue_idx_valid) begin
                    queue_valid[active_queue_idx] <= 1'b0;
                    queue_dispatched[active_queue_idx] <= 1'b0;
                    active_queue_idx_valid <= 1'b0;
                end
                if (queue_count > 0) queue_count <= queue_count - 1;  // FIX: Decrement on completion
            end

            if (!active_task_valid) pending_result_valid <= 1'b0;

            // ── Dispatch ──
            if (active_task_valid) begin
                if (active_task_wait_counter < 16'hFFFF)
                    active_task_wait_counter <= active_task_wait_counter + 1;
                if (active_task_wait_counter == 16'd500)
                    bp_timeout_stalls <= bp_timeout_stalls + 1;
                case (active_task_type)
                    TASK_GAMING: if (g_core_busy && !g_core_complete) stall_waiting_for_resource <= stall_waiting_for_resource + 1;
                    TASK_AI:     if (a_core_busy && !a_core_complete) stall_waiting_for_resource <= stall_waiting_for_resource + 1;
                    TASK_NPU:    if (npu_busy && !npu_complete)     stall_waiting_for_resource <= stall_waiting_for_resource + 1;
                    default: ;  // Cover incomplete case
                endcase
            end else if (queue_count > 0) begin
                // Find best-priority task
                best_idx = -1;
                best_prio = 8'd255;
                for (li = 0; li < QUEUE_DEPTH; li = li + 1) begin
                    if (queue_valid[li] && !queue_dispatched[li]) begin
                        ep = calc_eff_prio(queue_type[li], queue_aging[li]);
                        if (ep < best_prio) begin
                            best_prio = ep;
                            best_idx = li;
                        end
                    end
                end
                if (best_idx >= 0) begin
                    case (queue_type[best_idx])
                        TASK_GAMING: can_dispatch = !g_core_busy && !skip_g_dispatch;
                        TASK_AI:     can_dispatch = !a_core_busy;
                        TASK_NPU:    can_dispatch = !npu_busy;
                        default:     can_dispatch = 1'b0;
                    endcase
                    if (can_dispatch) begin
                        active_task_valid  <= 1'b1;
                        active_task_type   <= queue_type[best_idx];
                        active_task_addr   <= queue_addr[best_idx];
                        active_task_data   <= queue_data[best_idx];
                        active_queue_idx   <= best_idx;  // NEW: Track which queue entry is active
                        active_queue_idx_valid <= 1'b1;   // NEW: Mark index as valid
                        queue_dispatched[best_idx] <= 1'b1;
                        counter_dispatched <= counter_dispatched + 1;
                        task_being_served  <= 1'b1;
                        active_task_wait_counter <= 16'b0;
                        case (queue_type[best_idx])
                            TASK_GAMING: arbiter_select <= 0;
                            TASK_AI: begin
                                arbiter_select <= 1;
                                $display("[%0t] [SQ-SCHEDULER] 🔍 Setting arbiter_select=1 for AI task, a_core_busy=%0d", $time, a_core_busy);
                            end
                            TASK_NPU:    arbiter_select <= 2;
                            default: ;  // Cover incomplete case
                        endcase
                        if (queue_type[best_idx] == TASK_AI)
                            $display("[%0t] [SQ-SCHEDULER] 🤖 Dispatched AI task to A-Core, arbiter_select will be 1 next cycle", $time);
                        rr_rotations <= rr_rotations + 1;
                    end else begin
                        counter_conflicts <= counter_conflicts + 1;
                        hazard_structural_count <= hazard_structural_count + 1;
                        stall_waiting_for_resource <= stall_waiting_for_resource + 1;
                        // FIX: Count queue full rejections when resource busy
                        bp_queue_full_rejections <= bp_queue_full_rejections + 1;
                    end
                end else begin
                    // FIX #2 v2: No dispatchable task found but queue_count > 0
                    // This means queue_count is desynced - perform invariant check and recovery
                    // Count actual valid, undispatched entries to verify queue_count
                    actual_valid_count = 0;
                    for (li = 0; li < QUEUE_DEPTH; li = li + 1) begin
                        if (queue_valid[li] && !queue_dispatched[li]) begin
                            actual_valid_count = actual_valid_count + 1;
                        end
                    end

                    // If actual count doesn't match queue_count, fix the counter
                    if (actual_valid_count == 0) begin
                        // No valid entries but queue_count > 0 - force reset
                        if (rv_cleaned == 0) begin
                            $display("[%0t] [SQ-SCHEDULER] ⚠ QUEUE DE-SYNC DETECTED: queue_count=%0d but 0 valid entries. Forcing reset.", $time, queue_count);
                            queue_count <= 0;
                            head_idx <= 0;
                            tail_idx <= 0;
                            // Reset all dispatched flags to prevent stale state
                            for (li = 0; li < QUEUE_DEPTH; li = li + 1) begin
                                queue_dispatched[li] <= 1'b0;
                            end
                        end
                    end else begin
                        // There are valid entries but none dispatchable (all cores busy)
                        // This is normal backpressure, don't reset
                        stall_queue_contention <= stall_queue_contention + 1;
                    end
                end
            end

            // CRITICAL FIX: Move cleanup OUTSIDE the dispatch block
            // This ensures cleanup happens every cycle, not just when queue_count > 0
            rv_cleaned = 0;
            for (li_cleanup = 0; li_cleanup < QUEUE_DEPTH; li_cleanup = li_cleanup + 1) begin
                if (queue_valid[li_cleanup] && queue_dispatched[li_cleanup]) begin
                    queue_valid[li_cleanup] <= 1'b0;
                    rv_cleaned = rv_cleaned + 1;
                end
            end
            if (rv_cleaned > 0) begin
                // Advance head_idx by the actual number of cleaned entries
                // NOTE: queue_count already decremented on completion, so just advance head
                head_idx <= head_idx + rv_cleaned[$clog2(QUEUE_DEPTH)-1:0];
            end
            if (queue_count > max_queue_depth_seen)
                max_queue_depth_seen <= queue_count;

            // Effective priority tracking
            effective_priority_g <= BASE_PRIORITY_G;
            effective_priority_a <= BASE_PRIORITY_A;
            effective_priority_n <= BASE_PRIORITY_N;
            for (li_prio = 0; li_prio < QUEUE_DEPTH; li_prio = li_prio + 1) begin
                if (queue_valid[li_prio] && !queue_dispatched[li_prio]) begin
                    ep = calc_eff_prio(queue_type[li_prio], queue_aging[li_prio]);
                    case (queue_type[li_prio])
                        TASK_GAMING: if (ep < effective_priority_g) effective_priority_g <= ep;
                        TASK_AI:     if (ep < effective_priority_a) effective_priority_a <= ep;
                        TASK_NPU:    if (ep < effective_priority_n) effective_priority_n <= ep;
                        default: ;  // Cover incomplete case
                    endcase
                end
            end
        end
    end

endmodule
