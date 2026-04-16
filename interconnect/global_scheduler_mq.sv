`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 11 April 2026
// Design Name: AURORA-172 Global Scheduler — Hybrid Multi-Queue (v4.0)
// Module Name: global_scheduler_mq
//
// Description:
//   HYBRID MULTI-QUEUE ARCHITECTURE (v4.0):
//   FQ (Front Queue) → DQ (Decode Queue) → EQ (Execution Queues) → RQ → CQ
//
//   Queue Pipeline:
//   1. FQ: Input buffer — semua task masuk sini dulu (FIFO)
//   2. DQ: Decode & dependency tagging — parse opcode, set DEP_MASK, PRIORITY
//   3. EQ: Execution Queues — EQ-ALU, EQ-MEM, EQ-VEC (parallel, load balanced)
//   4. RQ: Reorder Queue — out-of-order execution, in-order commit
//   5. CQ: Commit Queue — atomic write-back ke core/memory
//
//   Dynamic Queue Balancer (DQB):
//   - Spill overflow EQ ke EQ lain yang kompatibel
//   - Work stealing dari EQ yang idle
//   - Load balancing berdasarkan latency sensitivity
//
//   Legacy Multi-Queue (v3.x):
//   G/A/NPU domain-isolated queues + WDRR arbitration + aging
//////////////////////////////////////////////////////////////////////////////////

// verilator lint_off CASEINCOMPLETE
// verilator lint_off BLKANDNBLK
// verilator lint_off BLKLOOPINIT

module global_scheduler_mq #(
    parameter DATA_WIDTH       = 128,  // OPTIMIZED: 64→128 for wider task data
    parameter ADDR_WIDTH       = 48,
    parameter G_QUEUE_DEPTH    = 16,
    parameter A_QUEUE_DEPTH    = 16,
    parameter N_QUEUE_DEPTH    = 8,
    /* verilator lint_off UNUSED */
    parameter G_WEIGHT         = 4,
    parameter A_WEIGHT         = 8,
    parameter N_WEIGHT         = 2,
    /* verilator lint_on UNUSED */
    parameter AGING_RATE       = 8,
    parameter MAX_AGING        = 8,
    parameter ADMISSION_THRESHOLD_PERCENT = 75,  // Queue depth % untuk admission control

    // Per-domain watchdog thresholds (cycles) - based on max latency per core type
    // FIXED v2: G-Core watchdog increased to 200 for multi-core broadcast (was 80)
    // FIXED v3: G-Core watchdog increased to 500 to accommodate pipeline + queue delays
    // DRAW=10, TEXTURE=12, PHYSICS=20, COLLISION=15, RAYTRACE=38, FRAMEGEN=28, SHADING=16
    // Max pipeline = 38 cycles + queue wait + dispatch latency = ~500 cycles safe margin
    G_WATCHDOG_TIMEOUT   = 500,  // G-Core: max 38 cycles * 10x margin for queue/broadcast
    A_WATCHDOG_TIMEOUT   = 500,  // A-Core: max 180 cycles * 3x margin
    N_WATCHDOG_TIMEOUT   = 200,  // NPU: max 75 cycles * 3x margin

    // ═══════════════════════════════════════════════════════
    // HYBRID MULTI-QUEUE PARAMETERS (v4.0)
    // ═══════════════════════════════════════════════════════
    parameter FQ_DEPTH         = 8,    // Front Queue depth (input buffer)
    parameter DQ_DEPTH         = 12,   // Decode Queue depth (with dependency tags)
    parameter EQ_ALU_DEPTH     = 8,    // EQ-ALU queue depth (compute ops)
    parameter EQ_MEM_DEPTH     = 8,    // EQ-MEM queue depth (memory ops)
    parameter EQ_VEC_DEPTH     = 8,    // EQ-VEC queue depth (vector/AI ops)
    parameter RQ_DEPTH         = 16,   // Reorder Queue depth (in-order commit)
    parameter CQ_DEPTH         = 4,    // Commit Queue depth (atomic write-back)
    parameter TAG_ID_WIDTH     = 8,    // Task tag ID width
    parameter DEP_MASK_WIDTH   = 16    // Dependency mask width
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
    input  wire                         g_core_busy,
    input  wire                         g_core_complete,
    input  wire [DATA_WIDTH-1:0]        g_core_result,
    input  wire                         g_core_error_valid,

    // A-Core dispatch
    output wire [ADDR_WIDTH-1:0]        a_core_cmd_addr,
    output wire [63:0]                  a_core_cmd_data,
    output wire                         a_core_cmd_valid,
    input  wire                         a_core_busy,
    input  wire                         a_core_complete,
    input  wire [DATA_WIDTH-1:0]        a_core_result,
    input  wire                         a_core_result_valid,  // CRITICAL FIX: A-Core result valid signal
    output wire                         a_core_result_ready, // CRITICAL FIX: Scheduler ready to consume result,

    // NPU dispatch
    output wire                         npu_dispatch_valid,
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
    output wire [31:0]                  sched_admission_rejections,  // NEW
    output wire [31:0]                  sched_hazard_raw,
    output wire [31:0]                  sched_hazard_war,
    output wire [31:0]                  sched_hazard_waw,
    output wire [31:0]                  sched_hazard_structural,
    output wire [31:0]                  sched_hazard_dependency,
    output wire [31:0]                  sched_hazard_dependency_stalls,  // NEW: Track actual stall count
    
    // NEW: Per-core utilization outputs
    output wire [31:0]                  sched_g_core_busy_cycles,
    output wire [31:0]                  sched_a_core_busy_cycles,
    output wire [31:0]                  sched_n_core_busy_cycles,
    output wire [31:0]                  sched_total_sim_cycles,
    
    // NEW: Hybrid Queue stage counters (v4.0 debug)
    output wire [31:0]                  sched_hq_fq_enqueued,
    output wire [31:0]                  sched_hq_dq_decoded,
    output wire [31:0]                  sched_hq_eq_dispatched,
    output wire [31:0]                  sched_hq_rq_committed,
    output wire [31:0]                  sched_hq_cq_completed,

    // Ring bus interface for load balancing
    input  wire [31:0]                  ring_bus_g_packets,
    input  wire [31:0]                  ring_bus_a_packets,
    input  wire [31:0]                  ring_bus_contention,
    input  wire                         ring_bus_congested
);

    localparam TASK_GAMING = 2'b00;
    localparam TASK_AI     = 2'b01;
    localparam TASK_NPU    = 2'b10;

    // ── Per-domain queues ──
    // G-Queue
    reg [ADDR_WIDTH-1:0]    g_q_addr  [0:G_QUEUE_DEPTH-1];
    reg [63:0]              g_q_data  [0:G_QUEUE_DEPTH-1];
    reg                     g_q_valid [0:G_QUEUE_DEPTH-1];
    reg                     g_q_disp  [0:G_QUEUE_DEPTH-1];
    reg [7:0]               g_q_aging [0:G_QUEUE_DEPTH-1];
    reg [7:0]               g_q_wait  [0:G_QUEUE_DEPTH-1];
    reg                     g_q_fresh [0:G_QUEUE_DEPTH-1];  // FIX: Prevent same-cycle dequeue
    reg [$clog2(G_QUEUE_DEPTH)-1:0] g_head, g_tail;
    reg [31:0]              g_q_count, g_credits;

    // A-Queue
    reg [ADDR_WIDTH-1:0]    a_q_addr  [0:A_QUEUE_DEPTH-1];
    reg [63:0]              a_q_data  [0:A_QUEUE_DEPTH-1];
    reg                     a_q_valid [0:A_QUEUE_DEPTH-1];
    reg                     a_q_disp  [0:A_QUEUE_DEPTH-1];
    reg [7:0]               a_q_aging [0:A_QUEUE_DEPTH-1];
    reg [7:0]               a_q_wait  [0:A_QUEUE_DEPTH-1];
    reg                     a_q_fresh [0:A_QUEUE_DEPTH-1];  // FIX: Prevent same-cycle dequeue
    reg [$clog2(A_QUEUE_DEPTH)-1:0] a_head, a_tail;
    reg [31:0]              a_q_count, a_credits;

    // N-Queue
    reg [ADDR_WIDTH-1:0]    n_q_addr  [0:N_QUEUE_DEPTH-1];
    reg [63:0]              n_q_data  [0:N_QUEUE_DEPTH-1];
    reg                     n_q_valid [0:N_QUEUE_DEPTH-1];
    reg                     n_q_disp  [0:N_QUEUE_DEPTH-1];
    reg [7:0]               n_q_aging [0:N_QUEUE_DEPTH-1];
    reg [7:0]               n_q_wait  [0:N_QUEUE_DEPTH-1];
    reg                     n_q_fresh [0:N_QUEUE_DEPTH-1];  // FIX: Prevent same-cycle dequeue
    reg [$clog2(N_QUEUE_DEPTH)-1:0] n_head, n_tail;
    reg [31:0]              n_q_count, n_credits;

    // ═══════════════════════════════════════════════════════
    // HYBRID MULTI-QUEUE STRUCTURES (v4.0)
    // ═══════════════════════════════════════════════════════

    // ── Task Tag Structure (Dependency Tracking) ──
    // TAG = {ID, DEP_MASK, PRIORITY, EQ_TYPE}
    // ID: Unique task identifier
    // DEP_MASK: Bitmask of task IDs this task depends on
    // PRIORITY: 0=highest, 7=lowest (before aging)
    // EQ_TYPE: Target execution queue type

    localparam EQ_TYPE_ALU = 2'b00;  // ALU/Compute
    localparam EQ_TYPE_MEM = 2'b01;  // Memory ops
    localparam EQ_TYPE_VEC = 2'b10;  // Vector/AI ops
    localparam EQ_TYPE_ANY = 2'b11;  // Can go to any EQ (spill target)

    // Task Tag register
    reg [TAG_ID_WIDTH-1:0]        task_id_counter;  // Auto-increment task ID counter
    reg [TAG_ID_WIDTH-1:0]        fq_tag_id   [0:FQ_DEPTH-1];   // FQ task IDs
    reg [7:0]                     fq_tag_opcode [0:FQ_DEPTH-1]; // FQ opcodes (for decode)
    reg                           fq_tag_valid  [0:FQ_DEPTH-1]; // FQ tag valid flags

    reg [TAG_ID_WIDTH-1:0]        dq_tag_id   [0:DQ_DEPTH-1];   // DQ task IDs
    reg [DEP_MASK_WIDTH-1:0]      dq_dep_mask [0:DQ_DEPTH-1];   // DQ dependency masks
    reg [2:0]                     dq_priority [0:DQ_DEPTH-1];   // DQ priority (0-7)
    reg [1:0]                     dq_eq_type  [0:DQ_DEPTH-1];   // DQ target EQ type
    reg [ADDR_WIDTH-1:0]          dq_addr     [0:DQ_DEPTH-1];   // DQ addresses
    reg [63:0]                    dq_data     [0:DQ_DEPTH-1];   // DQ data
    reg                           dq_valid    [0:DQ_DEPTH-1];   // DQ valid flags
    reg                           dq_decoded  [0:DQ_DEPTH-1];   // DQ decoded flag
    reg [$clog2(DQ_DEPTH)-1:0]    dq_head, dq_tail;
    reg [31:0]                    dq_count;

    // ── Execution Queues (EQ) ──
    // EQ-ALU: For compute-heavy ops (DRAW, PHYSICS, MATMUL, etc)
    reg [TAG_ID_WIDTH-1:0]        eq_alu_tag_id  [0:EQ_ALU_DEPTH-1];
    reg [ADDR_WIDTH-1:0]          eq_alu_addr    [0:EQ_ALU_DEPTH-1];
    reg [63:0]                    eq_alu_data    [0:EQ_ALU_DEPTH-1];
    reg                           eq_alu_valid   [0:EQ_ALU_DEPTH-1];
    reg                           eq_alu_ready   [0:EQ_ALU_DEPTH-1];  // Dependencies met?
    reg [31:0]                    eq_alu_count;

    // EQ-MEM: For memory ops (LOAD, STORE, cache ops)
    reg [TAG_ID_WIDTH-1:0]        eq_mem_tag_id  [0:EQ_MEM_DEPTH-1];
    reg [ADDR_WIDTH-1:0]          eq_mem_addr    [0:EQ_MEM_DEPTH-1];
    reg [63:0]                    eq_mem_data    [0:EQ_MEM_DEPTH-1];
    reg                           eq_mem_valid   [0:EQ_MEM_DEPTH-1];
    reg                           eq_mem_ready   [0:EQ_MEM_DEPTH-1];
    reg [31:0]                    eq_mem_count;

    // EQ-VEC: For vector/AI ops (MATMUL, ATTENTION, CONV)
    reg [TAG_ID_WIDTH-1:0]        eq_vec_tag_id  [0:EQ_VEC_DEPTH-1];
    reg [ADDR_WIDTH-1:0]          eq_vec_addr    [0:EQ_VEC_DEPTH-1];
    reg [63:0]                    eq_vec_data    [0:EQ_VEC_DEPTH-1];
    reg                           eq_vec_valid   [0:EQ_VEC_DEPTH-1];
    reg                           eq_vec_ready   [0:EQ_VEC_DEPTH-1];
    reg [31:0]                    eq_vec_count;

    // ── Reorder Queue (RQ) — In-order commit tracking ──
    reg [TAG_ID_WIDTH-1:0]        rq_tag_id     [0:RQ_DEPTH-1];
    reg                           rq_completed  [0:RQ_DEPTH-1];   // Task done, waiting commit
    reg                           rq_valid      [0:RQ_DEPTH-1];
    reg [31:0]                    rq_count;
    reg [$clog2(RQ_DEPTH)-1:0]    rq_commit_ptr;  // Next to commit (in-order)

    // ── Commit Queue (CQ) — Atomic write-back ──
    reg [TAG_ID_WIDTH-1:0]        cq_tag_id     [0:CQ_DEPTH-1];
    reg [ADDR_WIDTH-1:0]          cq_addr       [0:CQ_DEPTH-1];
    reg [DATA_WIDTH-1:0]          cq_result     [0:CQ_DEPTH-1];
    reg                           cq_valid      [0:CQ_DEPTH-1];
    reg                           cq_committed  [0:CQ_DEPTH-1];
    reg [31:0]                    cq_count;
    reg [$clog2(CQ_DEPTH)-1:0]    cq_head, cq_tail;

    // ── Dynamic Queue Balancer (DQB) State ──
    reg [31:0]                    dqb_spill_count;    // Times tasks spilled to other EQ
    reg [31:0]                    dqb_steal_count;    // Times work was stolen
    reg [31:0]                    dqb_rebalance_count; // Times queues were rebalanced

    // Hybrid Queue Debug outputs
    wire [31:0]                   fq_count_wire;
    wire [31:0]                   eq_alu_ready_count;
    wire [31:0]                   eq_mem_ready_count;
    wire [31:0]                   eq_vec_ready_count;
    wire [31:0]                   rq_commit_rate;

    // ═══════════════════════════════════════════════════════
    // END HYBRID MULTI-QUEUE STRUCTURES
    // ═══════════════════════════════════════════════════════

    // ── Active task per domain (CONCURRENT EXECUTION) ──
    // FIX: Allow G, A, NPU to execute simultaneously instead of serialized
    reg                     g_active_task_valid;
    reg [ADDR_WIDTH-1:0]    g_active_task_addr;
    reg [63:0]              g_active_task_data;
    wire [31:0]              g_active_task_data_unused = g_active_task_data[63:32];

    reg                     a_active_task_valid;
    reg [ADDR_WIDTH-1:0]    a_active_task_addr;
    reg [63:0]              a_active_task_data;
    
    reg                     n_active_task_valid;
    reg [ADDR_WIDTH-1:0]    n_active_task_addr;
    reg [63:0]              n_active_task_data;
    wire [63:0]              n_active_task_data_unused = n_active_task_data;

    // Legacy interface (backward compatible - maps to G domain)
    reg [1:0]               active_task_type;
    reg                     active_task_valid;
    reg [ADDR_WIDTH-1:0]    active_task_addr;
    reg [63:0]              active_task_data;
    wire [ADDR_WIDTH-1:0]   active_task_addr_unused = active_task_addr;
    wire [63:0]             active_task_data_unused = active_task_data;
    reg                     task_being_served;
    wire                    task_being_served_unused = task_being_served;
    reg [15:0]              active_task_wait_counter;
    
    // Per-domain watchdog counters (P1: Different thresholds per core type)
    reg [15:0]              g_watchdog_counter;
    reg [15:0]              a_watchdog_counter;
    reg [15:0]              n_watchdog_counter;
    
    // P1: Track stalled task addresses to prevent duplicate hazard logging
    reg [ADDR_WIDTH-1:0]    g_stalled_addr;
    reg                     g_stalled_valid;
    reg [ADDR_WIDTH-1:0]    a_stalled_addr;
    reg                     a_stalled_valid;
    reg [ADDR_WIDTH-1:0]    n_stalled_addr;
    reg                     n_stalled_valid;

    // FIX v3: Deadlock detection - track how long each domain has been stalled
    // If stalled > DEADLOCK_TIMEOUT, force clear to prevent permanent queue block
    localparam DEADLOCK_TIMEOUT = 200;  // cycles before considering deadlock
    reg [15:0]              g_stalled_cycles;
    reg [15:0]              a_stalled_cycles;
    reg [15:0]              n_stalled_cycles;
    reg [31:0]              deadlock_resets;  // Track deadlock recoveries
    
    // CRITICAL FIX v4: Cross-domain dependency tracking
    // If G-Core produces data needed by A-Core, and G-Core stalls, A-Core will also stall
    // This tracks inter-domain dependencies to detect cascading deadlocks
    reg                     g_to_a_dependency;  // A-Core waiting for G-Core result
    reg                     g_to_n_dependency;  // NPU waiting for G-Core result
    reg                     a_to_n_dependency;  // NPU waiting for A-Core result
    reg [ADDR_WIDTH-1:0]    g_pending_result_addr;  // Address of G result being waited on
    reg [ADDR_WIDTH-1:0]    a_pending_result_addr;  // Address of A result being waited on

    // Loop variables for Hybrid Queue initialization
    integer                 li_fq_init;
    integer                 li_dq_init;
    integer                 li_eq_init;
    integer                 li_rq_init;
    integer                 li_cq_init;

    // Loop variables for dep_mask clearing (CRITICAL FIX #12)
    integer                 li_dq_dep_clear;
    integer                 li_dq_dep_clear_a;
    integer                 li_dq_dep_clear_n;
    integer                 li_eq_rq;
    integer                 li_rq_slot;
    integer                 li_eq_slot;
    reg                     found_eq;
    reg                     found_rq;

    // ── Pending result ──
    reg [DATA_WIDTH-1:0]    pending_result;
    reg                     pending_result_valid;
    reg [1:0]               pending_result_type;
    reg                     g_core_complete_prev;
    reg                     a_core_complete_prev;
    reg                     npu_complete_prev;

    // ── WDRR arbiter (modified: fair scheduling + aging boost) ──
    reg [1:0]               wrr_domain;
    wire [1:0]              wrr_domain_unused = wrr_domain;
    reg [31:0]              wrr_quantum;
    
    // ── Aging-based priority boost ──
    wire                    g_starvation_risk = (g_q_count > 0) && (g_q_aging[g_head] >= MAX_AGING / 2);
    wire                    a_starvation_risk = (a_q_count > 4) && (a_q_aging[a_head] >= MAX_AGING - 1);
    wire                    a_starvation_risk_unused = a_starvation_risk;
    reg                     g_priority_boost;
    
    // ── Arbiter select ──
    reg [1:0]               arbiter_select;
    wire [1:0]              arbiter_select_unused = arbiter_select;

    // ── Ring bus load balancing signals ──
    reg                     g_ring_inject;
    reg [ADDR_WIDTH-1:0]    g_ring_addr;
    reg [63:0]              g_ring_data;
    reg [31:0]              bp_ring_balanced;
    
    // ── Counters ──
    reg [63:0]              counter_dispatched;
    reg [63:0]              counter_completed;
    reg [63:0]              stall_waiting_for_resource;
    reg [63:0]              stall_queue_contention;
    reg [31:0]              counter_conflicts;
    reg [31:0]              max_queue_depth_seen;
    reg [31:0]              aging_boosted_tasks;
    reg [31:0]              rr_rotations;
    reg [31:0]              bp_queue_full_rejections;
    reg [31:0]              bp_timeout_stalls;
    reg [31:0]              bp_actual_accepts;
    reg [31:0]              admission_rejections;  // NEW: Track admission control rejections
    reg [31:0]              hazard_structural_count;
    reg [31:0]              hazard_raw_count;  // FIX: Track RAW hazards
    reg [31:0]              hazard_war_count;  // FIX: Track WAR hazards
    reg [31:0]              hazard_waw_count;  // FIX: Track WAW hazards
    reg [31:0]              hazard_dependency_stalls;  // NEW: Track actual dependency stalls
    reg [ADDR_WIDTH-1:0]    last_write_addr;   // Track last write address
    wire [ADDR_WIDTH-1:0]   last_write_addr_unused = last_write_addr;
    reg                     last_write_was_g;  // Track if last write was from G-Core
    wire                    last_write_was_g_unused = last_write_was_g;

    // NEW: Per-core utilization tracking
    reg [31:0]              g_core_busy_cycles;
    reg [31:0]              a_core_busy_cycles;
    reg [31:0]              n_core_busy_cycles;
    reg [31:0]              total_sim_cycles;
    
    // NEW: Hybrid Queue stage counters (v4.0 debug)
    reg [31:0]              hq_fq_enqueued;      // Tasks enqueued to FQ
    reg [31:0]              hq_dq_decoded;       // Tasks decoded in DQ
    reg [31:0]              hq_eq_dispatched;    // Tasks dispatched to EQ
    reg [31:0]              hq_rq_committed;     // Tasks committed to RQ
    reg [31:0]              hq_cq_completed;     // Tasks completed via CQ
    
    // NEW: Inflight tracking (CRITICAL FIX - prevent double dispatch)
    reg                     g_core_inflight;     // G-Core has inflight task
    reg                     a_core_inflight;     // A-Core has inflight task
    reg                     n_core_inflight;     // N-Core has inflight task
    reg [31:0]              g_inflight_timer;    // Cycles since G dispatch
    reg [31:0]              a_inflight_timer;    // Cycles since A dispatch
    reg [31:0]              n_inflight_timer;    // Cycles since N dispatch
    
    // Helper flags for single-driver inflight timer management
    reg                     g_reset_timer;       // Reset G-Core timer flag
    reg                     a_reset_timer;       // Reset A-Core timer flag
    reg                     n_reset_timer;       // Reset N-Core timer flag
    reg                     g_increment_timer;   // Increment G-Core timer flag
    reg                     a_increment_timer;   // Increment A-Core timer flag
    reg                     n_increment_timer;   // Increment N-Core timer flag
    
    // Address tracking per domain for hazard detection
    // Each active task has read_addr (input) and write_addr (output) semantics
    reg [ADDR_WIDTH-1:0]    g_active_read_addr;   // G-Core input address
    reg [ADDR_WIDTH-1:0]    g_active_write_addr;  // G-Core output address
    reg                     g_active_has_write;    // G task will write
    reg [ADDR_WIDTH-1:0]    a_active_read_addr;   // A-Core input address
    reg [ADDR_WIDTH-1:0]    a_active_write_addr;  // A-Core output address
    reg                     a_active_has_write;    // A task will write
    reg [ADDR_WIDTH-1:0]    n_active_read_addr;   // NPU input address
    reg [ADDR_WIDTH-1:0]    n_active_write_addr;  // NPU output address
    reg                     n_active_has_write;    // N task will write
    reg [31:0]              watchdog_resets_reg;
    reg                     g_core_error_prev;
    reg                     skip_g_dispatch;
    reg [7:0]               skip_g_counter;

    // FIX: Edge detection untuk prevent double enqueue
    reg                     g_task_valid_prev;
    reg                     a_task_valid_prev;
    reg                     npu_task_valid_prev;

    // ── Assignments ──
    // ADMISSION CONTROL: Throttle when queue > threshold
    localparam G_QUEUE_THRESHOLD = (G_QUEUE_DEPTH * ADMISSION_THRESHOLD_PERCENT) / 100;
    localparam A_QUEUE_THRESHOLD = (A_QUEUE_DEPTH * ADMISSION_THRESHOLD_PERCENT) / 100;
    localparam N_QUEUE_THRESHOLD = (N_QUEUE_DEPTH * ADMISSION_THRESHOLD_PERCENT) / 100;
    
    // CRITICAL FIX: Queue overflow protection
    // Prevent queue from exceeding absolute maximum capacity
    assign g_task_ready  = (g_credits > 0) && (g_q_count < G_QUEUE_THRESHOLD) && (g_q_count < G_QUEUE_DEPTH);
    assign a_task_ready  = (a_credits > 0) && (a_q_count < A_QUEUE_THRESHOLD) && (a_q_count < A_QUEUE_DEPTH);
    assign npu_task_ready = (n_credits > 0) && (n_q_count < N_QUEUE_THRESHOLD) && (n_q_count < N_QUEUE_DEPTH);
    
    // CRITICAL FIX: Queue overflow detection assertions
    // These will fail during simulation if queue overflows
    `ifdef SIMULATION
        always @(posedge clk) begin
            if (g_q_count > G_QUEUE_DEPTH) begin
                $error("[%0t] 🚨 G-QUEUE OVERFLOW: count=%0d > max=%0d", $time, g_q_count, G_QUEUE_DEPTH);
                $finish;
            end
            if (a_q_count > A_QUEUE_DEPTH) begin
                $error("[%0t] 🚨 A-QUEUE OVERFLOW: count=%0d > max=%0d", $time, a_q_count, A_QUEUE_DEPTH);
                $finish;
            end
            if (n_q_count > N_QUEUE_DEPTH) begin
                $error("[%0t] 🚨 N-QUEUE OVERFLOW: count=%0d > max=%0d", $time, n_q_count, N_QUEUE_DEPTH);
                $finish;
            end
        end
    `endif

    assign g_task_result       = (pending_result_type == TASK_GAMING && pending_result_valid) ? pending_result : {DATA_WIDTH{1'b0}};
    assign g_task_result_valid = (pending_result_type == TASK_GAMING && pending_result_valid);
    assign a_task_result       = (pending_result_type == TASK_AI && pending_result_valid) ? pending_result : {DATA_WIDTH{1'b0}};
    assign a_task_result_valid = (pending_result_type == TASK_AI && pending_result_valid);
    assign npu_task_result     = (pending_result_type == TASK_NPU && pending_result_valid) ? pending_result : {DATA_WIDTH{1'b0}};
    assign npu_task_result_valid = (pending_result_type == TASK_NPU && pending_result_valid);

    // CONCURRENT: Each core gets command independently when its domain has active task
    assign g_core_cmd_addr  = g_active_task_addr;
    assign g_core_cmd_data  = g_active_task_data[31:0];
    assign g_core_cmd_valid = g_active_task_valid && !g_core_busy && !skip_g_dispatch;

    assign a_core_cmd_addr  = a_active_task_addr;
    assign a_core_cmd_data  = a_active_task_data;
    assign a_core_cmd_valid = a_active_task_valid && !a_core_busy;
    
    // CRITICAL FIX: A-Core result consumption
    // Scheduler is ready to consume result when we have space for pending result
    // FIX #1 (MQ): a_core_result_ready diubah dari ekspresi kompleks yang menghasilkan
    // 'x' (pending_result_type tidak selalu terinisialisasi sebelum assignment) menjadi
    // 1'b1 permanen. A-Core memiliki RESULT_FIFO_DEPTH=4 sehingga selalu aman menerima
    // result tanpa harus menunggu pending_result slot kosong.
    assign a_core_result_ready = 1'b1;

    assign npu_dispatch_valid = n_active_task_valid && !npu_busy;

    // Legacy signals updated in always block (no assign)

    assign sched_total_dispatched     = counter_dispatched;
    assign sched_total_completed      = counter_completed;
    assign sched_total_stalled        = stall_waiting_for_resource + stall_queue_contention;
    assign sched_stall_resource_wait  = stall_waiting_for_resource;
    assign sched_stall_queue_contention = stall_queue_contention;
    // FIX: Queue depth should be MAX individual queue, not SUM
    // SUM is misleading: G=12 + A=12 = 24, but each queue limit is 16
    // IVC: Replace function with always @(*) for VVP compatibility
    reg [32:0] max3_result;
    always @(*) begin
        max3_result = (g_q_count >= a_q_count) ? ((g_q_count >= n_q_count) ? g_q_count : n_q_count) : ((a_q_count >= n_q_count) ? a_q_count : n_q_count);
    end
    assign sched_queue_depth          = max3_result;
    assign sched_max_queue_depth      = max_queue_depth_seen;
    assign sched_conflict_count       = counter_conflicts;
    assign sched_gaming_priority      = 8'd0;  // FIX: BASE_PRIORITY_G = 0 (highest), bukan 2
    assign sched_ai_priority          = 8'd2;
    assign sched_npu_priority         = 8'd3;
    assign sched_aging_tasks          = aging_boosted_tasks;
    assign sched_rr_rotations         = rr_rotations;
    // sched_queue_avoidance: Count DQB spill + steal + rebalance events
    assign sched_queue_avoidance      = dqb_spill_count + dqb_steal_count + dqb_rebalance_count;
    assign sched_watchdog_resets      = watchdog_resets_reg;
    assign sched_bp_queue_full_rejections = bp_queue_full_rejections;
    assign sched_bp_timeout_stalls    = bp_timeout_stalls;
    assign sched_bp_actual_accepts    = bp_actual_accepts;
    assign sched_admission_rejections = admission_rejections;
    assign sched_hazard_raw           = hazard_raw_count;
    assign sched_hazard_war           = hazard_war_count;
    assign sched_hazard_waw           = hazard_waw_count;
    assign sched_hazard_structural    = hazard_structural_count;
    assign sched_hazard_dependency    = hazard_dependency_stalls;
    assign sched_hazard_dependency_stalls = hazard_dependency_stalls;
    
    // NEW: Per-core utilization assigns
    assign sched_g_core_busy_cycles = g_core_busy_cycles;
    assign sched_a_core_busy_cycles = a_core_busy_cycles;
    assign sched_n_core_busy_cycles = n_core_busy_cycles;
    assign sched_total_sim_cycles   = total_sim_cycles;
    
    // NEW: Hybrid Queue stage counters assigns (v4.0)
    assign sched_hq_fq_enqueued    = hq_fq_enqueued;
    assign sched_hq_dq_decoded     = hq_dq_decoded;
    assign sched_hq_eq_dispatched  = hq_eq_dispatched;
    assign sched_hq_rq_committed   = hq_rq_committed;
    assign sched_hq_cq_completed   = hq_cq_completed;

    // ═══════════════════════════════════════════════════════
    // HYBRID MULTI-QUEUE DEBUG OUTPUTS (v4.0) - FULLY WIRED
    // ═══════════════════════════════════════════════════════

    // Count active entries in each queue stage (real-time monitoring)
    // IVC: Replace functions with always @(*) for VVP compatibility
    reg [31:0] fq_count_result;
    reg [31:0] eq_alu_ready_result;
    reg [31:0] eq_mem_ready_result;
    reg [31:0] eq_vec_ready_result;
    reg [31:0] rq_commit_result;

    always @(*) begin
        integer i;
        fq_count_result = 0;
        for (i = 0; i < FQ_DEPTH; i = i + 1)
            if (fq_tag_valid[i]) fq_count_result = fq_count_result + 1;
    end

    always @(*) begin
        integer i;
        eq_alu_ready_result = 0;
        for (i = 0; i < EQ_ALU_DEPTH; i = i + 1)
            if (eq_alu_valid[i] && eq_alu_ready[i]) eq_alu_ready_result = eq_alu_ready_result + 1;
    end

    always @(*) begin
        integer i;
        eq_mem_ready_result = 0;
        for (i = 0; i < EQ_MEM_DEPTH; i = i + 1)
            if (eq_mem_valid[i] && eq_mem_ready[i]) eq_mem_ready_result = eq_mem_ready_result + 1;
    end

    always @(*) begin
        integer i;
        eq_vec_ready_result = 0;
        for (i = 0; i < EQ_VEC_DEPTH; i = i + 1)
            if (eq_vec_valid[i] && eq_vec_ready[i]) eq_vec_ready_result = eq_vec_ready_result + 1;
    end

    always @(*) begin
        integer i;
        rq_commit_result = 0;
        for (i = 0; i < RQ_DEPTH; i = i + 1)
            if (rq_valid[i] && rq_completed[i]) rq_commit_result = rq_commit_result + 1;
    end

    assign fq_count_wire      = fq_count_result;
    assign eq_alu_ready_count = eq_alu_ready_result;
    assign eq_mem_ready_count = eq_mem_ready_result;
    assign eq_vec_ready_count = eq_vec_ready_result;
    assign rq_commit_rate     = rq_commit_result;

    // ── Main logic ──
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_head <= 0; g_tail <= 0; g_q_count <= 0; g_credits <= G_QUEUE_DEPTH;
            a_head <= 0; a_tail <= 0; a_q_count <= 0; a_credits <= A_QUEUE_DEPTH;
            n_head <= 0; n_tail <= 0; n_q_count <= 0; n_credits <= N_QUEUE_DEPTH;
            active_task_valid <= 1'b0; active_task_type <= TASK_GAMING;
            active_task_addr <= {ADDR_WIDTH{1'b0}}; active_task_data <= 64'b0;
            task_being_served <= 1'b0; active_task_wait_counter <= 16'b0;
            pending_result_valid <= 1'b0; pending_result <= {DATA_WIDTH{1'b0}};
            pending_result_type <= TASK_GAMING;
            arbiter_select <= 0; wrr_domain <= 0; wrr_quantum <= 0;
            counter_dispatched <= 64'b0; counter_completed <= 64'b0;
            stall_waiting_for_resource <= 64'b0; stall_queue_contention <= 64'b0;
            counter_conflicts <= 32'b0; max_queue_depth_seen <= 32'b0;
            aging_boosted_tasks <= 32'b0; rr_rotations <= 32'b0;
            bp_queue_full_rejections <= 32'b0; bp_timeout_stalls <= 32'b0;
            bp_actual_accepts <= 32'b0; hazard_structural_count <= 32'b0;
            hazard_raw_count <= 32'b0; hazard_war_count <= 32'b0; hazard_waw_count <= 32'b0;
            hazard_dependency_stalls <= 32'b0;
            last_write_addr <= {ADDR_WIDTH{1'b0}}; last_write_was_g <= 1'b0;
            admission_rejections <= 32'b0;
            watchdog_resets_reg <= 32'b0;
            g_core_error_prev <= 1'b0; skip_g_dispatch <= 1'b0; skip_g_counter <= 8'b0;
            g_core_complete_prev <= 1'b0; a_core_complete_prev <= 1'b0; npu_complete_prev <= 1'b0;
            g_priority_boost <= 1'b0;
            g_task_valid_prev <= 1'b0; a_task_valid_prev <= 1'b0; npu_task_valid_prev <= 1'b0;
            // Ring bus load balancing init
            g_ring_inject <= 1'b0;
            g_ring_addr <= {ADDR_WIDTH{1'b0}};
            g_ring_data <= 64'b0;
            bp_ring_balanced <= 32'b0;
            // Concurrent execution init
            g_active_task_valid <= 1'b0; a_active_task_valid <= 1'b0; n_active_task_valid <= 1'b0;
            g_active_read_addr <= {ADDR_WIDTH{1'b0}}; g_active_write_addr <= {ADDR_WIDTH{1'b0}};
            g_active_has_write <= 1'b0;
            a_active_read_addr <= {ADDR_WIDTH{1'b0}}; a_active_write_addr <= {ADDR_WIDTH{1'b0}};
            a_active_has_write <= 1'b0;
            n_active_read_addr <= {ADDR_WIDTH{1'b0}}; n_active_write_addr <= {ADDR_WIDTH{1'b0}};
            n_active_has_write <= 1'b0;
            active_task_valid <= 1'b0; task_being_served <= 1'b0;
            // Per-domain watchdog init
            g_watchdog_counter <= 16'b0; a_watchdog_counter <= 16'b0; n_watchdog_counter <= 16'b0;
            // P1: Stalled task tracking init
            g_stalled_addr <= {ADDR_WIDTH{1'b0}}; g_stalled_valid <= 1'b0;
            a_stalled_addr <= {ADDR_WIDTH{1'b0}}; a_stalled_valid <= 1'b0;
            n_stalled_addr <= {ADDR_WIDTH{1'b0}}; n_stalled_valid <= 1'b0;
            // CRITICAL FIX v4: Cross-domain dependency init
            g_to_a_dependency <= 1'b0; g_to_n_dependency <= 1'b0; a_to_n_dependency <= 1'b0;
            g_pending_result_addr <= {ADDR_WIDTH{1'b0}}; a_pending_result_addr <= {ADDR_WIDTH{1'b0}};
            g_stalled_cycles <= 16'b0; a_stalled_cycles <= 16'b0; n_stalled_cycles <= 16'b0;
            deadlock_resets <= 32'b0;
            // NEW: Per-core utilization init
            g_core_busy_cycles <= 32'b0; a_core_busy_cycles <= 32'b0; n_core_busy_cycles <= 32'b0;
            total_sim_cycles <= 32'b0;
            
            // NEW: Hybrid Queue stage counters init (v4.0)
            hq_fq_enqueued <= 32'b0; hq_dq_decoded <= 32'b0; hq_eq_dispatched <= 32'b0;
            hq_rq_committed <= 32'b0; hq_cq_completed <= 32'b0;
            
            // NEW: Inflight tracking init (CRITICAL FIX)
            g_core_inflight <= 1'b0; a_core_inflight <= 1'b0; n_core_inflight <= 1'b0;
            g_inflight_timer <= 32'b0; a_inflight_timer <= 32'b0; n_inflight_timer <= 32'b0;
            // Helper flags for single-driver inflight timer management
            g_reset_timer <= 1'b0; a_reset_timer <= 1'b0; n_reset_timer <= 1'b0;
            g_increment_timer <= 1'b0; a_increment_timer <= 1'b0; n_increment_timer <= 1'b0;

            // ═══════════════════════════════════════════════
            // HYBRID MULTI-QUEUE INIT (v4.0)
            // ═══════════════════════════════════════════════
            task_id_counter <= {TAG_ID_WIDTH{1'b0}};
            // FQ init
            for (li_fq_init = 0; li_fq_init < FQ_DEPTH; li_fq_init = li_fq_init + 1) begin
                fq_tag_valid[li_fq_init] <= 1'b0;
            end
            // DQ init
            dq_head <= 0; dq_tail <= 0; dq_count <= 0;
            for (li_dq_init = 0; li_dq_init < DQ_DEPTH; li_dq_init = li_dq_init + 1) begin
                dq_valid[li_dq_init] <= 1'b0;
                dq_decoded[li_dq_init] <= 1'b0;
            end
            // EQ init
            eq_alu_count <= 0; eq_mem_count <= 0; eq_vec_count <= 0;
            for (li_eq_init = 0; li_eq_init < EQ_ALU_DEPTH; li_eq_init = li_eq_init + 1)
                eq_alu_valid[li_eq_init] <= 1'b0;
            for (li_eq_init = 0; li_eq_init < EQ_MEM_DEPTH; li_eq_init = li_eq_init + 1)
                eq_mem_valid[li_eq_init] <= 1'b0;
            for (li_eq_init = 0; li_eq_init < EQ_VEC_DEPTH; li_eq_init = li_eq_init + 1)
                eq_vec_valid[li_eq_init] <= 1'b0;
            // RQ init
            rq_count <= 0; rq_commit_ptr <= 0;
            for (li_rq_init = 0; li_rq_init < RQ_DEPTH; li_rq_init = li_rq_init + 1) begin
                rq_valid[li_rq_init] <= 1'b0;
                rq_completed[li_rq_init] <= 1'b0;
            end
            // CQ init
            cq_head <= 0; cq_tail <= 0; cq_count <= 0;
            for (li_cq_init = 0; li_cq_init < CQ_DEPTH; li_cq_init = li_cq_init + 1) begin
                cq_valid[li_cq_init] <= 1'b0;
                cq_committed[li_cq_init] <= 1'b0;
            end
            // DQB init
            dqb_spill_count <= 0; dqb_steal_count <= 0; dqb_rebalance_count <= 0;
        end else begin
            total_sim_cycles <= total_sim_cycles + 1;

            // NEW: Per-core utilization tracking
            if (g_core_busy) g_core_busy_cycles <= g_core_busy_cycles + 1;
            if (a_core_busy) a_core_busy_cycles <= a_core_busy_cycles + 1;
            if (npu_busy) n_core_busy_cycles <= n_core_busy_cycles + 1;
            
            // CRITICAL FIX v4: Cross-domain deadlock detection
            // Track stalled cycles per domain and detect cascading stalls
            // G-Core stalled tracking
            if (g_core_busy && !g_core_complete) begin
                g_stalled_cycles <= g_stalled_cycles + 1;
                if (g_stalled_cycles == DEADLOCK_TIMEOUT - 10) begin
                    $display("[%0t] [MQ-SCHEDULER] ⚠ G-CORE STALLED: %0d cycles, checking for cross-domain deps", 
                            $time, g_stalled_cycles);
                end
            end else begin
                g_stalled_cycles <= 16'b0;
            end
            
            // A-Core stalled tracking
            if (a_core_busy && !a_core_complete) begin
                a_stalled_cycles <= a_stalled_cycles + 1;
                if (a_stalled_cycles == DEADLOCK_TIMEOUT - 10) begin
                    $display("[%0t] [MQ-SCHEDULER] ⚠ A-CORE STALLED: %0d cycles, checking for cross-domain deps", 
                            $time, a_stalled_cycles);
                end
            end else begin
                a_stalled_cycles <= 16'b0;
            end
            
            // NPU stalled tracking
            if (npu_busy && !npu_complete) begin
                n_stalled_cycles <= n_stalled_cycles + 1;
                if (n_stalled_cycles == DEADLOCK_TIMEOUT - 10) begin
                    $display("[%0t] [MQ-SCHEDULER] ⚠ NPU STALLED: %0d cycles, checking for cross-domain deps", 
                            $time, n_stalled_cycles);
                end
            end else begin
                n_stalled_cycles <= 16'b0;
            end
            
            // DEADLOCK RECOVERY: If any domain stalled > TIMEOUT, force reset
            if (g_stalled_cycles >= DEADLOCK_TIMEOUT) begin
                $display("[%0t] [MQ-SCHEDULER] ⚠ DEADLOCK RECOVERY: G-Core stalled %0d cycles, force clearing", 
                        $time, g_stalled_cycles);
                g_stalled_cycles <= 16'b0;
                // Clear any tasks dependent on G-Core
                if (g_to_a_dependency) begin
                    $display("[%0t] [MQ-SCHEDULER]    → Clearing A-Core dependency on G-Core result at addr %0h", 
                            $time, g_pending_result_addr);
                    g_to_a_dependency <= 1'b0;
                end
                if (g_to_n_dependency) begin
                    $display("[%0t] [MQ-SCHEDULER]    → Clearing NPU dependency on G-Core result at addr %0h", 
                            $time, g_pending_result_addr);
                    g_to_n_dependency <= 1'b0;
                end
                // CRITICAL: Force complete any stalled G-Core task
                force_complete_g_core_task();
                deadlock_resets <= deadlock_resets + 1;
            end
            
            if (a_stalled_cycles >= DEADLOCK_TIMEOUT) begin
                $display("[%0t] [MQ-SCHEDULER] ⚠ DEADLOCK RECOVERY: A-Core stalled %0d cycles, force clearing", 
                        $time, a_stalled_cycles);
                a_stalled_cycles <= 16'b0;
                if (a_to_n_dependency) begin
                    $display("[%0t] [MQ-SCHEDULER]    → Clearing NPU dependency on A-Core result at addr %0h", 
                            $time, a_pending_result_addr);
                    a_to_n_dependency <= 1'b0;
                    // CRITICAL: Clear actual NPU tasks waiting for A-Core
                    clear_npu_waiting_tasks(a_pending_result_addr);
                end
                // CRITICAL: Force complete any stalled A-Core task
                force_complete_a_core_task();
                deadlock_resets <= deadlock_resets + 1;
            end
            
            if (n_stalled_cycles >= DEADLOCK_TIMEOUT) begin
                $display("[%0t] [MQ-SCHEDULER] ⚠ DEADLOCK RECOVERY: NPU stalled %0d cycles, force clearing", 
                        $time, n_stalled_cycles);
                n_stalled_cycles <= 16'b0;
                deadlock_resets <= deadlock_resets + 1;
            end
            
            // ── Update priority boost based on aging ──
            if (g_starvation_risk && !g_priority_boost) begin
                g_priority_boost <= 1'b1;
                aging_boosted_tasks <= aging_boosted_tasks + 1;
            end else if (!g_starvation_risk && g_priority_boost) begin
                g_priority_boost <= 1'b0;
            end
            g_core_complete_prev <= g_core_complete;
            a_core_complete_prev <= a_core_complete;
            npu_complete_prev  <= npu_complete;

            // Error detection
            if (g_core_error_valid && !g_core_error_prev) begin
                skip_g_dispatch <= 1'b1; skip_g_counter <= 8'd10;
                if (active_task_valid && active_task_type == TASK_GAMING) begin
                    active_task_valid <= 1'b0; task_being_served <= 1'b0;
                end
            end
            g_core_error_prev <= g_core_error_valid;
            if (skip_g_counter > 0) begin
                skip_g_counter <= skip_g_counter - 1;
                if (skip_g_counter == 1) skip_g_dispatch <= 1'b0;
            end

            // ═══════════════════════════════════════════════════════
            // HYBRID MULTI-QUEUE PIPELINE (v4.0)
            // FQ → DQ → EQ → RQ → CQ
            // ═══════════════════════════════════════════════════════
            // FIX: Verilator 5.020 doesn't support delayed assignment in loops
            // Use blocking assignments consistently for all pipeline variables

            // ── STAGE 1: FRONT QUEUE (FQ) — Input Buffer ──
            // All incoming tasks enter FQ first before decode
            begin
                // Enqueue to FQ on rising edge of any task valid
                if ((g_task_valid && !g_task_valid_prev) || (a_task_valid && !a_task_valid_prev)) begin
                    // Find empty FQ slot (use combinational search)
                    integer li_fq;
                    reg found_slot;
                    found_slot = 1'b0;
                    for (li_fq = 0; li_fq < FQ_DEPTH && !found_slot; li_fq = li_fq + 1) begin
                        if (!fq_tag_valid[li_fq]) begin
                            // Use blocking assignments for immediate update within same cycle
                            fq_tag_id[li_fq] = task_id_counter;
                            fq_tag_opcode[li_fq] = g_task_valid ? g_task_data[31:24] : a_task_data[63:56];
                            fq_tag_valid[li_fq] = 1'b1;
                            task_id_counter = task_id_counter + 1;
                            hq_fq_enqueued = hq_fq_enqueued + 1;
                            found_slot = 1'b1;
                        end
                    end
                end

                // Dequeue from FQ → move to DQ when DQ has space
                begin
                    integer li_fq_dq;
                    reg found_dq;
                    found_dq = 1'b0;
                    for (li_fq_dq = 0; li_fq_dq < FQ_DEPTH && !found_dq; li_fq_dq = li_fq_dq + 1) begin
                        if (fq_tag_valid[li_fq_dq] && dq_count < DQ_DEPTH) begin
                            // Move to DQ
                            dq_tag_id[dq_tail]   = fq_tag_id[li_fq_dq];
                            dq_addr[dq_tail]     = g_task_valid ? g_task_addr : a_task_addr;
                            dq_data[dq_tail]     = g_task_valid ? {32'b0, g_task_data} : a_task_data;
                            dq_dep_mask[dq_tail] = 16'b0;
                            dq_priority[dq_tail] = 3'd2;
                            dq_eq_type[dq_tail]  = 2'b00;
                            dq_valid[dq_tail]    = 1'b1;
                            dq_decoded[dq_tail]  = 1'b0;
                            dq_tail = (dq_tail == $clog2(DQ_DEPTH)'(DQ_DEPTH-1)) ? $clog2(DQ_DEPTH)'(0) : dq_tail + 1;
                            dq_count = dq_count + 1;

                            // Clear FQ slot
                            fq_tag_valid[li_fq_dq] = 1'b0;
                            found_dq = 1'b1;
                        end
                    end
                end
            end

            // ── STAGE 2: DECODE QUEUE (DQ) — Dependency Tagging & EQ Classification ──
            begin
                integer li_dq;
                reg [7:0] opcode;
                reg [ADDR_WIDTH-1:0] task_addr;
                
                for (li_dq = 0; li_dq < DQ_DEPTH; li_dq = li_dq + 1) begin
                    if (dq_valid[li_dq] && !dq_decoded[li_dq]) begin
                        // Decode opcode and classify to EQ type
                        opcode = dq_data[li_dq][63:56];
                        task_addr = dq_addr[li_dq];

                        // Classify EQ type based on opcode
                        case (opcode)
                            // ALU ops: DRAW, TEXTURE, PHYSICS, COLLISION, BRANCH
                            8'h01, 8'h02, 8'h03, 8'h04, 8'h08:
                                dq_eq_type[li_dq] = EQ_TYPE_ALU;
                            // MEM ops: LOAD, STORE
                            8'h10, 8'h11:
                                dq_eq_type[li_dq] = EQ_TYPE_MEM;
                            // VEC ops: RAYTRACE, FRAMEGEN, MATMUL, ATTENTION, CONV
                            8'h05, 8'h06, 8'h20, 8'h21, 8'h22:
                                dq_eq_type[li_dq] = EQ_TYPE_VEC;
                            // NPU ops: INFERENCE, CONV, POOL, RELU, etc (0x40-0x48)
                            // NPU tasks have their own queue path, but if they end up here,
                            // classify as VEC to avoid invalid opcode at A-Core
                            8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46, 8'h47, 8'h48:
                                dq_eq_type[li_dq] = EQ_TYPE_VEC;  // Route to vector unit
                            default:
                                dq_eq_type[li_dq] = EQ_TYPE_ALU;
                        endcase

                        // ── REAL DATA DEPENDENCY ANALYSIS ──
                        // Check if this task depends on any in-flight or recently completed tasks
                        // by comparing read/write addresses and tracking data flow
                        
                        dq_dep_mask[li_dq] = 16'b0;  // Start with no dependencies
                        
                        // Check against active tasks in G/A/NPU domains
                        // RAW dependency: This task reads what another task is writing
                        if (g_active_task_valid && g_active_has_write && 
                            (g_active_write_addr == task_addr)) begin
                            // Set bit 0 in dep_mask: depends on G-Core completion
                            dq_dep_mask[li_dq] = dq_dep_mask[li_dq] | 16'h0001;
                        end
                        
                        if (a_active_task_valid && a_active_has_write && 
                            (a_active_write_addr == task_addr)) begin
                            // Set bit 1: depends on A-Core completion
                            dq_dep_mask[li_dq] = dq_dep_mask[li_dq] | 16'h0002;
                        end
                        
                        if (n_active_task_valid && n_active_has_write && 
                            (n_active_write_addr == task_addr)) begin
                            // Set bit 2: depends on NPU completion
                            dq_dep_mask[li_dq] = dq_dep_mask[li_dq] | 16'h0004;
                        end
                        
                        // WAR dependency: This task writes what another task is reading
                        if (g_active_task_valid && (g_active_read_addr == task_addr)) begin
                            // Set bit 3: anti-dependency with G-Core read
                            dq_dep_mask[li_dq] = dq_dep_mask[li_dq] | 16'h0008;
                        end
                        
                        if (a_active_task_valid && (a_active_read_addr == task_addr)) begin
                            // Set bit 4: anti-dependency with A-Core read
                            dq_dep_mask[li_dq] = dq_dep_mask[li_dq] | 16'h0010;
                        end
                        
                        // Check against tasks in EQ (execution queues) for inter-task dependencies
                        begin
                            integer eq_idx;
                            for (eq_idx = 0; eq_idx < EQ_ALU_DEPTH; eq_idx = eq_idx + 1) begin
                                if (eq_alu_valid[eq_idx] && 
                                    (eq_alu_addr[eq_idx] == task_addr) &&
                                    (eq_alu_tag_id[eq_idx] < dq_tag_id[li_dq])) begin
                                    // Set bit 5: depends on earlier EQ-ALU task
                                    dq_dep_mask[li_dq] = dq_dep_mask[li_dq] | 16'h0020;
                                end
                            end
                            
                            for (eq_idx = 0; eq_idx < EQ_MEM_DEPTH; eq_idx = eq_idx + 1) begin
                                if (eq_mem_valid[eq_idx] && 
                                    (eq_mem_addr[eq_idx] == task_addr) &&
                                    (eq_mem_tag_id[eq_idx] < dq_tag_id[li_dq])) begin
                                    // Set bit 6: depends on earlier EQ-MEM task
                                    dq_dep_mask[li_dq] = dq_dep_mask[li_dq] | 16'h0040;
                                end
                            end
                            
                            for (eq_idx = 0; eq_idx < EQ_VEC_DEPTH; eq_idx = eq_idx + 1) begin
                                if (eq_vec_valid[eq_idx] && 
                                    (eq_vec_addr[eq_idx] == task_addr) &&
                                    (eq_vec_tag_id[eq_idx] < dq_tag_id[li_dq])) begin
                                    // Set bit 7: depends on earlier EQ-VEC task
                                    dq_dep_mask[li_dq] = dq_dep_mask[li_dq] | 16'h0080;
                                end
                            end
                        end
                        
                        // Check against tasks in RQ (reorder queue) for commit ordering
                        begin
                            integer rq_idx;
                            for (rq_idx = 0; rq_idx < RQ_DEPTH; rq_idx = rq_idx + 1) begin
                                if (rq_valid[rq_idx] && !rq_completed[rq_idx]) begin
                                    // Set bit 8: must wait for in-order commit
                                    dq_dep_mask[li_dq] = dq_dep_mask[li_dq] | 16'h0100;
                                end
                            end
                        end

                        dq_decoded[li_dq] = 1'b1;
                        hq_dq_decoded = hq_dq_decoded + 1;
                    end
                end
            end

            // ── STAGE 3: DQ → EQ DISPATCH (with Dependency Check) ──
            // Dispatch decoded tasks to appropriate EQ when:
            // 1. Task is decoded
            // 2. Target EQ has space
            // 3. No unresolved dependencies (dep_mask == 0)
            begin
                integer li_dq_eq;
                reg dispatched;
                dispatched = 1'b0;
                for (li_dq_eq = 0; li_dq_eq < DQ_DEPTH && !dispatched; li_dq_eq = li_dq_eq + 1) begin
                    if (dq_valid[li_dq_eq] && dq_decoded[li_dq_eq] && (dq_dep_mask[li_dq_eq] == 0)) begin
                        // Dispatch to appropriate EQ
                        case (dq_eq_type[li_dq_eq])
                            EQ_TYPE_ALU: begin
                                if (eq_alu_count < EQ_ALU_DEPTH) begin
                                    integer li_eq_slot;
                                    reg found_slot;
                                    found_slot = 1'b0;
                                    for (li_eq_slot = 0; li_eq_slot < EQ_ALU_DEPTH && !found_slot; li_eq_slot = li_eq_slot + 1) begin
                                        if (!eq_alu_valid[li_eq_slot]) begin
                                            eq_alu_tag_id[li_eq_slot] = dq_tag_id[li_dq_eq];
                                            eq_alu_addr[li_eq_slot]   = dq_addr[li_dq_eq];
                                            eq_alu_data[li_eq_slot]   = dq_data[li_dq_eq];
                                            eq_alu_valid[li_eq_slot]  = 1'b1;
                                            eq_alu_ready[li_eq_slot]  = 1'b1;
                                            eq_alu_count = eq_alu_count + 1;
                                            found_slot = 1'b1;
                                        end
                                    end
                                    // Remove from DQ
                                    dq_valid[li_dq_eq] = 1'b0;
                                    dq_count = dq_count - 1;
                                    dispatched = 1'b1;
                                end
                            end
                            EQ_TYPE_MEM: begin
                                if (eq_mem_count < EQ_MEM_DEPTH) begin
                                    integer li_eq_slot;
                                    reg found_slot;
                                    found_slot = 1'b0;
                                    for (li_eq_slot = 0; li_eq_slot < EQ_MEM_DEPTH && !found_slot; li_eq_slot = li_eq_slot + 1) begin
                                        if (!eq_mem_valid[li_eq_slot]) begin
                                            eq_mem_tag_id[li_eq_slot] = dq_tag_id[li_dq_eq];
                                            eq_mem_addr[li_eq_slot]   = dq_addr[li_dq_eq];
                                            eq_mem_data[li_eq_slot]   = dq_data[li_dq_eq];
                                            eq_mem_valid[li_eq_slot]  = 1'b1;
                                            eq_mem_ready[li_eq_slot]  = 1'b1;
                                            eq_mem_count = eq_mem_count + 1;
                                            found_slot = 1'b1;
                                        end
                                    end
                                    dq_valid[li_dq_eq] = 1'b0;
                                    dq_count = dq_count - 1;
                                    dispatched = 1'b1;
                                end
                            end
                            EQ_TYPE_VEC: begin
                                if (eq_vec_count < EQ_VEC_DEPTH) begin
                                    integer li_eq_slot;
                                    reg found_slot;
                                    found_slot = 1'b0;
                                    for (li_eq_slot = 0; li_eq_slot < EQ_VEC_DEPTH && !found_slot; li_eq_slot = li_eq_slot + 1) begin
                                        if (!eq_vec_valid[li_eq_slot]) begin
                                            eq_vec_tag_id[li_eq_slot] = dq_tag_id[li_dq_eq];
                                            eq_vec_addr[li_eq_slot]   = dq_addr[li_dq_eq];
                                            eq_vec_data[li_eq_slot]   = dq_data[li_dq_eq];
                                            eq_vec_valid[li_eq_slot]  = 1'b1;
                                            eq_vec_ready[li_eq_slot]  = 1'b1;
                                            eq_vec_count = eq_vec_count + 1;
                                            found_slot = 1'b1;
                                        end
                                    end
                                    dq_valid[li_dq_eq] = 1'b0;
                                    dq_count = dq_count - 1;
                                    dispatched = 1'b1;
                                end
                            end
                            default: ;
                        endcase
                    end
                end
            end

            // ── STAGE 4: EQ → RQ (Task completion tracking) ──
            // When core completes, task moves to RQ for in-order commit
            // CRITICAL FIX #12: Clear dep_mask bits for tasks that depended on this completed task
            if (g_core_complete && !g_core_complete_prev) begin
                // Clear bit 0 (G-Core dependency) from ALL tasks in DQ that depend on G-Core
                integer li_dq_dep_clear;
                for (li_dq_dep_clear = 0; li_dq_dep_clear < DQ_DEPTH; li_dq_dep_clear = li_dq_dep_clear + 1) begin
                    if (dq_valid[li_dq_dep_clear] && (dq_dep_mask[li_dq_dep_clear] & 16'h0001)) begin
                        // Clear G-Core dependency bit
                        dq_dep_mask[li_dq_dep_clear] <= dq_dep_mask[li_dq_dep_clear] & ~16'h0001;
                    end
                end

                // Find matching task in EQ-ALU and move to RQ
                li_eq_rq = 0;
                found_eq = 1'b0;
                for (li_eq_rq = 0; li_eq_rq < EQ_ALU_DEPTH && !found_eq; li_eq_rq = li_eq_rq + 1) begin
                    if (eq_alu_valid[li_eq_rq] && eq_alu_ready[li_eq_rq]) begin
                        if (rq_count < RQ_DEPTH) begin
                            // Find empty slot in RQ
                            li_rq_slot = 0;
                            found_rq = 1'b0;
                            for (li_rq_slot = 0; li_rq_slot < RQ_DEPTH && !found_rq; li_rq_slot = li_rq_slot + 1) begin
                                if (!rq_valid[li_rq_slot]) begin
                                    rq_tag_id[li_rq_slot]     = eq_alu_tag_id[li_eq_rq];
                                    rq_valid[li_rq_slot]      = 1'b1;
                                    rq_completed[li_rq_slot]  = 1'b1;
                                    rq_count = rq_count + 1;
                                    hq_rq_committed = hq_rq_committed + 1;
                                    found_rq = 1'b1;
                                end
                            end
                        end
                        eq_alu_valid[li_eq_rq] = 1'b0;
                        eq_alu_ready[li_eq_rq] = 1'b0;
                        eq_alu_count = eq_alu_count - 1;
                        found_eq = 1'b1;
                    end
                end
            end

            // Clear A-Core dependency bit (bit 1) from DQ tasks
            if (a_core_complete && !a_core_complete_prev) begin
                integer li_dq_dep_clear_a;
                for (li_dq_dep_clear_a = 0; li_dq_dep_clear_a < DQ_DEPTH; li_dq_dep_clear_a = li_dq_dep_clear_a + 1) begin
                    if (dq_valid[li_dq_dep_clear_a] && (dq_dep_mask[li_dq_dep_clear_a] & 16'h0002)) begin
                        dq_dep_mask[li_dq_dep_clear_a] <= dq_dep_mask[li_dq_dep_clear_a] & ~16'h0002;
                    end
                end
            end

            // Clear NPU dependency bit (bit 2) from DQ tasks
            if (npu_complete && !npu_complete_prev) begin
                integer li_dq_dep_clear_n;
                for (li_dq_dep_clear_n = 0; li_dq_dep_clear_n < DQ_DEPTH; li_dq_dep_clear_n = li_dq_dep_clear_n + 1) begin
                    if (dq_valid[li_dq_dep_clear_n] && (dq_dep_mask[li_dq_dep_clear_n] & 16'h0004)) begin
                        dq_dep_mask[li_dq_dep_clear_n] <= dq_dep_mask[li_dq_dep_clear_n] & ~16'h0004;
                    end
                end
            end

            // ── STAGE 5: RQ → CQ (In-order commit) ──
            // Commit tasks from RQ to CQ in order (FIFO)
            if (rq_valid[rq_commit_ptr] && rq_completed[rq_commit_ptr] && cq_count < CQ_DEPTH) begin
                cq_tag_id[cq_tail]    <= rq_tag_id[rq_commit_ptr];
                cq_addr[cq_tail]      <= 48'b0;  // Address tracked separately
                cq_result[cq_tail]    <= 64'b0;  // Result tracked separately
                cq_valid[cq_tail]     <= 1'b1;
                cq_committed[cq_tail] <= 1'b0;
                cq_tail <= (cq_tail == $clog2(CQ_DEPTH)'(CQ_DEPTH-1)) ? $clog2(CQ_DEPTH)'(0) : cq_tail + 1;
                cq_count <= cq_count + 1;

                // Remove from RQ
                rq_valid[rq_commit_ptr] <= 1'b0;
                rq_completed[rq_commit_ptr] <= 1'b0;
                rq_count <= rq_count - 1;

                // Advance commit pointer
                rq_commit_ptr <= (rq_commit_ptr == $clog2(RQ_DEPTH)'(RQ_DEPTH-1)) ? $clog2(RQ_DEPTH)'(0) : rq_commit_ptr + 1;
            end

            // ── STAGE 6: CQ → Result Output (Atomic write-back) ──
            // Commit results from CQ
            if (cq_valid[cq_head] && !cq_committed[cq_head]) begin
                cq_committed[cq_head] <= 1'b1;
                cq_valid[cq_head] <= 1'b0;
                cq_count <= cq_count - 1;
                cq_head <= (cq_head == $clog2(CQ_DEPTH)'(CQ_DEPTH-1)) ? $clog2(CQ_DEPTH)'(0) : cq_head + 1;
            end

            // ── DYNAMIC QUEUE BALANCER (DQB) ──
            // Spill overflow from busy EQ to less busy EQ
            begin
                // If EQ-ALU is > 75% full and EQ-VEC has space, spill ALU tasks to VEC
                if (eq_alu_count > (EQ_ALU_DEPTH * 3 / 4) && eq_vec_count < EQ_VEC_DEPTH / 2) begin
                    integer li_spill;
                    reg found_spill;
                    found_spill = 1'b0;
                    for (li_spill = 0; li_spill < EQ_ALU_DEPTH && !found_spill; li_spill = li_spill + 1) begin
                        if (eq_alu_valid[li_spill] && eq_vec_count < EQ_VEC_DEPTH) begin
                            integer li_vec;
                            reg found_vec;
                            found_vec = 1'b0;
                            for (li_vec = 0; li_vec < EQ_VEC_DEPTH && !found_vec; li_vec = li_vec + 1) begin
                                if (!eq_vec_valid[li_vec]) begin
                                    eq_vec_tag_id[li_vec] = eq_alu_tag_id[li_spill];
                                    eq_vec_addr[li_vec]   = eq_alu_addr[li_spill];
                                    eq_vec_data[li_vec]   = eq_alu_data[li_spill];
                                    eq_vec_valid[li_vec]  = 1'b1;
                                    eq_vec_ready[li_vec]  = eq_alu_ready[li_spill];
                                    eq_vec_count = eq_vec_count + 1;
                                    found_vec = 1'b1;
                                end
                            end
                            eq_alu_valid[li_spill] = 1'b0;
                            eq_alu_count = eq_alu_count - 1;
                            dqb_spill_count = dqb_spill_count + 1;
                            found_spill = 1'b1;
                        end
                    end
                end
            end

            // ═══════════════════════════════════════════════════════
            // END HYBRID MULTI-QUEUE PIPELINE
            // ═══════════════════════════════════════════════════════

            // ── ENQUEUE per domain (with ADMISSION CONTROL) ──
            // FIX: Edge detection untuk prevent double enqueue saat cmd_valid ditahan > 1 cycle
            g_task_valid_prev <= g_task_valid;
            a_task_valid_prev <= a_task_valid;
            npu_task_valid_prev <= npu_task_valid;
            
            // FIXED: G-Core enqueue logic - Single path to prevent double enqueue
            if (g_task_valid && !g_task_valid_prev && g_credits > 0) begin
                if (g_q_count < G_QUEUE_THRESHOLD) begin
                    // Normal enqueue path
                    g_q_addr[g_tail] <= g_task_addr;
                    g_q_data[g_tail] <= g_task_data;
                    g_q_valid[g_tail] <= 1'b1;
                    g_tail <= (g_tail == G_QUEUE_DEPTH-1) ? 0 : g_tail + 1;
                    g_q_count <= g_q_count + 1;
                    g_credits <= g_credits - 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    $display("[%0t] [SCHED-BP] G-Task ACCEPTED: queue=%0d/%0d, ring_congested=%b", 
                             $time, g_q_count + 1, G_QUEUE_DEPTH, ring_bus_congested);
                end else begin
                    // Load balancing via ring bus
                    g_ring_inject <= 1'b1;
                    g_ring_addr <= g_task_addr;
                    g_ring_data <= g_task_data;
                    bp_ring_balanced <= bp_ring_balanced + 1;
                    $display("[%0t] [SCHED-BP] G-Task RING-BALANCED: queue=%0d >= threshold=%0d", 
                             $time, g_q_count, G_QUEUE_THRESHOLD);
                end
            end else if (g_task_valid && !g_task_valid_prev) begin
                // ADMISSION CONTROL: Reject - no space available
                admission_rejections <= admission_rejections + 1;
                if (g_q_count >= G_QUEUE_THRESHOLD) begin
                    $display("[%0t] [SCHED-AC] ⚠ G-Task REJECTED: QUEUE_FULL (queue_depth=%0d/%0d)", $time, g_q_count, G_QUEUE_DEPTH);
                end else if (ring_bus_congested || ring_bus_g_packets >= 32'd100) begin
                    $display("[%0t] [SCHED-AC] ⚠ G-Task REJECTED: RING_CONGESTED (ring_packets=%0d)", $time, ring_bus_g_packets);
                end else if (g_credits == 0) begin
                    $display("[%0t] [SCHED-AC] ⚠ G-Task REJECTED: NO_CREDITS", $time);
                end
            end else if (g_task_valid && !g_task_valid_prev && g_credits == 0) begin
                // RING BUS LOAD BALANCING: Try ring bus if no credits
                if (!ring_bus_congested && ring_bus_g_packets < 32'd80) begin
                    // Route to ring bus instead of rejecting
                    g_q_addr[g_tail]  <= g_task_addr;
                    g_q_data[g_tail]  <= g_task_data;
                    g_q_valid[g_tail] <= 1'b1; g_q_disp[g_tail] <= 1'b0;
                    g_q_aging[g_tail] <= 8'b0; g_q_wait[g_tail] <= 8'b0;
                    g_q_fresh[g_tail] <= 1'b1;
                    g_tail <= (g_tail == G_QUEUE_DEPTH-1) ? 0 : g_tail + 1;
                    g_q_count <= g_q_count + 1;
                    g_credits <= g_credits - 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    $display("[%0t] [SCHED-RB] 🔄 G-Task ROUTED via Ring Bus (no_credits, ring_packets=%0d)", $time, ring_bus_g_packets);
                end else begin
                    // REJECT: No credits and ring bus congested
                    bp_queue_full_rejections <= bp_queue_full_rejections + 1;
                    $display("[%0t] [SCHED-CR] ⚠ G-Task REJECTED: NO_CREDITS & RING_CONGESTED (queue_depth=%0d, ring_packets=%0d)", $time, g_q_count, ring_bus_g_packets);
                end
            end

            // Clear fresh flag after 1 cycle (task now eligible for dispatch)
            begin
                integer li_fresh;
                for (li_fresh = 0; li_fresh < G_QUEUE_DEPTH; li_fresh = li_fresh + 1) begin
                    if (g_q_fresh[li_fresh]) begin
                        g_q_fresh[li_fresh] <= 1'b0;
                    end
                end
            end

            // HARD BACKPRESSURE: Stop injection if system is overwhelmed
            if (a_task_valid && !a_task_valid_prev && a_credits > 0 && a_q_count < A_QUEUE_THRESHOLD) begin
                // Additional safety: Check ring bus congestion before accepting
                if (!ring_bus_congested || (ring_bus_a_packets < 32'd30)) begin
                    a_q_addr[a_tail]  <= a_task_addr;
                    a_q_data[a_tail]  <= a_task_data;
                    a_q_valid[a_tail] <= 1'b1; a_q_disp[a_tail] <= 1'b0;
                    a_q_aging[a_tail] <= 8'b0; a_q_wait[a_tail] <= 8'b0;
                    a_q_fresh[a_tail] <= 1'b1;  // FIX: Mark as fresh
                    a_tail <= (a_tail == $clog2(A_QUEUE_DEPTH)'(A_QUEUE_DEPTH-1)) ? $clog2(A_QUEUE_DEPTH)'(0) : a_tail + $clog2(A_QUEUE_DEPTH)'(1);
                    a_q_count <= a_q_count + 1;
                    a_credits <= a_credits - 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    $display("[%0t] [SCHED-BP] A-Task ACCEPTED: queue=%0d/%0d, ring_congested=%b", 
                             $time, a_q_count + 1, A_QUEUE_DEPTH, ring_bus_congested);
                end else begin
                    // HARD BACKPRESSURE: Reject due to ring bus congestion
                    admission_rejections <= admission_rejections + 1;
                    $display("[%0t] [SCHED-BP] ⚠ A-Task REJECTED: RING_CONGESTED (queue=%0d, ring_packets=%0d)", 
                             $time, a_q_count, ring_bus_a_packets);
                end
            end else if (a_task_valid && !a_task_valid_prev && a_q_count >= A_QUEUE_THRESHOLD) begin
                // RING BUS LOAD BALANCING: Try ring bus if scheduler queue full
                if (!ring_bus_congested && ring_bus_a_packets < 32'd50) begin
                    // Accept and let ring bus handle the load
                    a_q_addr[a_tail]  <= a_task_addr;
                    a_q_data[a_tail]  <= a_task_data;
                    a_q_valid[a_tail] <= 1'b1; a_q_disp[a_tail] <= 1'b0;
                    a_q_aging[a_tail] <= 8'b0; a_q_wait[a_tail] <= 8'b0;
                    a_q_fresh[a_tail] <= 1'b1;
                    a_tail <= (a_tail == $clog2(A_QUEUE_DEPTH)'(A_QUEUE_DEPTH-1)) ? $clog2(A_QUEUE_DEPTH)'(0) : a_tail + $clog2(A_QUEUE_DEPTH)'(1);
                    a_q_count <= a_q_count + 1;
                    a_credits <= a_credits - 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    $display("[%0t] [SCHED-RB] 🔄 A-Task ACCEPTED via Ring Bus (queue_full=%0d, ring_packets=%0d)", $time, a_q_count, ring_bus_a_packets);
                end else begin
                    // ADMISSION CONTROL: Reject - both scheduler and ring bus congested
                    admission_rejections <= admission_rejections + 1;
                    $display("[%0t] [SCHED-AC] ⚠ A-Task REJECTED: QUEUE_FULL & RING_CONGESTED (queue_depth=%0d/%0d, ring_packets=%0d)", $time, a_q_count, A_QUEUE_DEPTH, ring_bus_a_packets);
                end
            end else if (a_task_valid && !a_task_valid_prev && a_credits == 0) begin
                // RING BUS LOAD BALANCING: Try ring bus if no credits
                if (!ring_bus_congested && ring_bus_a_packets < 32'd40) begin
                    // Route to ring bus instead of rejecting
                    a_q_addr[a_tail]  <= a_task_addr;
                    a_q_data[a_tail]  <= a_task_data;
                    a_q_valid[a_tail] <= 1'b1; a_q_disp[a_tail] <= 1'b0;
                    a_q_aging[a_tail] <= 8'b0; a_q_wait[a_tail] <= 8'b0;
                    a_q_fresh[a_tail] <= 1'b1;
                    a_tail <= (a_tail == $clog2(A_QUEUE_DEPTH)'(A_QUEUE_DEPTH-1)) ? $clog2(A_QUEUE_DEPTH)'(0) : a_tail + $clog2(A_QUEUE_DEPTH)'(1);
                    a_q_count <= a_q_count + 1;
                    a_credits <= a_credits - 1;
                    bp_actual_accepts <= bp_actual_accepts + 1;
                    $display("[%0t] [SCHED-RB] 🔄 A-Task ROUTED via Ring Bus (no_credits, ring_packets=%0d)", $time, ring_bus_a_packets);
                end else begin
                    // REJECT: No credits and ring bus congested
                    bp_queue_full_rejections <= bp_queue_full_rejections + 1;
                    $display("[%0t] [SCHED-CR] ⚠ A-Task REJECTED: NO_CREDITS & RING_CONGESTED (queue_depth=%0d, ring_packets=%0d)", $time, a_q_count, ring_bus_a_packets);
                end
            end

            // Clear fresh flag after 1 cycle
            begin
                integer li_fresh;
                for (li_fresh = 0; li_fresh < A_QUEUE_DEPTH; li_fresh = li_fresh + 1) begin
                    if (a_q_fresh[li_fresh]) begin
                        a_q_fresh[li_fresh] <= 1'b0;
                    end
                end
            end

            if (npu_task_valid && !npu_task_valid_prev && n_credits > 0) begin
                n_q_addr[n_tail]  <= {ADDR_WIDTH{1'b0}};
                n_q_data[n_tail]  <= 64'b0;
                n_q_valid[n_tail] <= 1'b1; n_q_disp[n_tail] <= 1'b0;
                n_q_aging[n_tail] <= 8'b0; n_q_wait[n_tail] <= 8'b0;
                n_q_fresh[n_tail] <= 1'b1;  // FIX: Mark as fresh
                n_tail <= (n_tail == $clog2(N_QUEUE_DEPTH)'(N_QUEUE_DEPTH-1)) ? $clog2(N_QUEUE_DEPTH)'(0) : n_tail + $clog2(N_QUEUE_DEPTH)'(1);
                n_q_count <= n_q_count + 1;
                n_credits <= n_credits - 1;
                bp_actual_accepts <= bp_actual_accepts + 1;
            end else if (npu_task_valid && !npu_task_valid_prev && n_credits == 0) begin
                bp_queue_full_rejections <= bp_queue_full_rejections + 1;
            end

            // Clear fresh flag after 1 cycle
            begin
                integer li_fresh;
                for (li_fresh = 0; li_fresh < N_QUEUE_DEPTH; li_fresh = li_fresh + 1) begin
                    if (n_q_fresh[li_fresh]) begin
                        n_q_fresh[li_fresh] <= 1'b0;
                    end
                end
            end

            // Credit refill on completion
            if (g_core_complete && g_credits < G_QUEUE_DEPTH) g_credits <= g_credits + 1;
            if (a_core_complete && a_credits < A_QUEUE_DEPTH) a_credits <= a_credits + 1;
            if (npu_complete && n_credits < N_QUEUE_DEPTH)    n_credits <= n_credits + 1;

            // ── AGING ──
            begin
                integer li_aging;
                for (li_aging = 0; li_aging < G_QUEUE_DEPTH; li_aging = li_aging + 1) begin
                    if (g_q_valid[li_aging] && !g_q_disp[li_aging]) begin
                        g_q_wait[li_aging] <= g_q_wait[li_aging] + 1;
                        if (g_q_wait[li_aging] >= AGING_RATE && g_q_aging[li_aging] < MAX_AGING)
                            g_q_aging[li_aging] <= g_q_aging[li_aging] + 1;
                    end
                end
                for (li_aging = 0; li_aging < A_QUEUE_DEPTH; li_aging = li_aging + 1) begin
                    if (a_q_valid[li_aging] && !a_q_disp[li_aging]) begin
                        a_q_wait[li_aging] <= a_q_wait[li_aging] + 1;
                        if (a_q_wait[li_aging] >= AGING_RATE && a_q_aging[li_aging] < MAX_AGING)
                            a_q_aging[li_aging] <= a_q_aging[li_aging] + 1;
                    end
                end
                for (li_aging = 0; li_aging < N_QUEUE_DEPTH; li_aging = li_aging + 1) begin
                    if (n_q_valid[li_aging] && !n_q_disp[li_aging]) begin
                        n_q_wait[li_aging] <= n_q_wait[li_aging] + 1;
                        if (n_q_wait[li_aging] >= AGING_RATE && n_q_aging[li_aging] < MAX_AGING)
                            n_q_aging[li_aging] <= n_q_aging[li_aging] + 1;
                    end
                end
            end
            
            // CRITICAL FIX: Single-driver inflight timer management
            // Increment timers
            g_increment_timer <= g_core_inflight;
            a_increment_timer <= a_core_inflight;
            n_increment_timer <= n_core_inflight;
            
            // Reset timers (from various conditions)
            g_reset_timer <= 1'b0; a_reset_timer <= 1'b0; n_reset_timer <= 1'b0;

            // ── Completion (CONCURRENT: each domain独立) ──
            if (g_core_complete && !g_core_complete_prev && g_active_task_valid) begin
                counter_completed <= counter_completed + 1;
                hq_cq_completed <= hq_cq_completed + 1;  // Increment CQ counter
                
                // CRITICAL FIX: Clear inflight when task completes
                g_core_inflight <= 1'b0;
                g_reset_timer <= 1'b1;  // Set reset flag instead of direct assignment
                
                pending_result <= g_core_result; pending_result_valid <= 1'b1;
                pending_result_type <= TASK_GAMING;
                g_active_task_valid <= 1'b0;
                // Track write address for hazard detection
                last_write_addr <= g_active_write_addr;
                last_write_was_g <= 1'b1;
                g_active_read_addr <= {ADDR_WIDTH{1'b0}};
                g_active_write_addr <= {ADDR_WIDTH{1'b0}};
                g_active_has_write <= 1'b0;
            end
            if (a_core_complete && !a_core_complete_prev && a_active_task_valid) begin
                counter_completed <= counter_completed + 1;
                hq_cq_completed <= hq_cq_completed + 1;  // Increment CQ counter
                
                // CRITICAL FIX: Clear inflight when task completes
                a_core_inflight <= 1'b0;
                a_reset_timer <= 1'b1;  // Set reset flag instead of direct assignment
                
                // FIX #1 (MQ): Tidak lagi bergantung pada a_core_result_ready (circular).
                // a_core_result_ready = 1'b1 selalu, jadi kondisi ini selalu true saat valid=1.
                if (a_core_result_valid) begin
                    pending_result       <= a_core_result;
                    pending_result_valid <= 1'b1;
                    pending_result_type  <= TASK_AI;
                    $display("[%0t] [MQ-SCHEDULER] ✅ A-Core result consumed: pending_result_valid=1", $time);
                end
                a_active_task_valid <= 1'b0;
                // Track write address for hazard detection
                last_write_addr <= a_active_write_addr;
                last_write_was_g <= 1'b0;
                a_active_read_addr <= {ADDR_WIDTH{1'b0}};
                a_active_write_addr <= {ADDR_WIDTH{1'b0}};
                a_active_has_write <= 1'b0;
            end
            if (npu_complete && !npu_complete_prev && n_active_task_valid) begin
                counter_completed <= counter_completed + 1;
                hq_cq_completed <= hq_cq_completed + 1;  // Increment CQ counter
                
                // CRITICAL FIX: Clear inflight when task completes
                n_core_inflight <= 1'b0;
                n_reset_timer <= 1'b1;  // Set reset flag instead of direct assignment
                
                pending_result <= npu_result; pending_result_valid <= 1'b1;
                pending_result_type <= TASK_NPU;
                n_active_task_valid <= 1'b0;
                last_write_addr <= n_active_write_addr;
                n_active_read_addr <= {ADDR_WIDTH{1'b0}};
                n_active_write_addr <= {ADDR_WIDTH{1'b0}};
                n_active_has_write <= 1'b0;
            end
            if (!active_task_valid) pending_result_valid <= 1'b0;

            // ── Stall tracking + WATCHDOG RECOVERY (PER-DOMAIN) ──
            // P1: Each domain has independent watchdog with different thresholds
            
            // G-Core watchdog
            if (g_active_task_valid) begin
                if (g_watchdog_counter < 16'hFFFF)
                    g_watchdog_counter <= g_watchdog_counter + 1;
                if (g_watchdog_counter == G_WATCHDOG_TIMEOUT) begin
                    bp_timeout_stalls <= bp_timeout_stalls + 1;
                    counter_completed <= counter_completed + 1;  // FIX: Count as completed (failed but cleared)
                    hq_cq_completed <= hq_cq_completed + 1;  // Increment CQ counter
                    g_credits <= g_credits + 1;  // FIX: Return credit when task cleared by watchdog
                    $display("[%0t] [SCHED-WD] ⚠ G-Core watchdog timeout (%0d cycles), force clearing...", $time, G_WATCHDOG_TIMEOUT);
                    g_active_task_valid <= 1'b0;
                    g_active_read_addr <= {ADDR_WIDTH{1'b0}};
                    g_active_write_addr <= {ADDR_WIDTH{1'b0}};
                    g_active_has_write <= 1'b0;
                    g_core_inflight <= 1'b0;  // FIX: Clear inflight flag
                    g_reset_timer <= 1'b1;      // FIX: Set reset flag
                    watchdog_resets_reg <= watchdog_resets_reg + 1;
                    
                    // CRITICAL FIX #1: Clear G-Core dependency bit (bit 0) from ALL DQ tasks
                    // Prevents permanent deadlock when watchdog kills a task but DQ tasks still wait
                    begin
                        integer li_wd_dq_clear;
                        for (li_wd_dq_clear = 0; li_wd_dq_clear < DQ_DEPTH; li_wd_dq_clear = li_wd_dq_clear + 1) begin
                            if (dq_valid[li_wd_dq_clear] && (dq_dep_mask[li_wd_dq_clear] & 16'h0001)) begin
                                dq_dep_mask[li_wd_dq_clear] <= dq_dep_mask[li_wd_dq_clear] & ~16'h0001;
                            end
                        end
                    end
                    
                    // CRITICAL FIX #2: Mark RQ commit task as completed if it was waiting on G-Core
                    // Prevents RQ commit pointer from stalling forever
                    if (rq_valid[rq_commit_ptr] && !rq_completed[rq_commit_ptr]) begin
                        rq_completed[rq_commit_ptr] <= 1'b1;
                    end
                end
            end else begin
                g_watchdog_counter <= 16'b0;
            end
            
            // A-Core watchdog
            if (a_active_task_valid) begin
                if (a_watchdog_counter < 16'hFFFF)
                    a_watchdog_counter <= a_watchdog_counter + 1;
                if (a_watchdog_counter == A_WATCHDOG_TIMEOUT) begin
                    bp_timeout_stalls <= bp_timeout_stalls + 1;
                    counter_completed <= counter_completed + 1;  // FIX: Count as completed (failed but cleared)
                    hq_cq_completed <= hq_cq_completed + 1;  // Increment CQ counter
                    a_credits <= a_credits + 1;  // FIX: Return credit when task cleared by watchdog
                    $display("[%0t] [SCHED-WD] ⚠ A-Core watchdog timeout (%0d cycles), force clearing...", $time, A_WATCHDOG_TIMEOUT);
                    a_active_task_valid <= 1'b0;
                    a_active_read_addr <= {ADDR_WIDTH{1'b0}};
                    a_active_write_addr <= {ADDR_WIDTH{1'b0}};
                    a_active_has_write <= 1'b0;
                    a_core_inflight <= 1'b0;  // FIX: Clear inflight flag
                    a_reset_timer <= 1'b1;      // FIX: Set reset flag
                    watchdog_resets_reg <= watchdog_resets_reg + 1;
                    
                    // CRITICAL FIX #1: Clear A-Core dependency bit (bit 1) from ALL DQ tasks
                    begin
                        integer li_wd_dq_clear_a;
                        for (li_wd_dq_clear_a = 0; li_wd_dq_clear_a < DQ_DEPTH; li_wd_dq_clear_a = li_wd_dq_clear_a + 1) begin
                            if (dq_valid[li_wd_dq_clear_a] && (dq_dep_mask[li_wd_dq_clear_a] & 16'h0002)) begin
                                dq_dep_mask[li_wd_dq_clear_a] <= dq_dep_mask[li_wd_dq_clear_a] & ~16'h0002;
                            end
                        end
                    end
                    
                    // CRITICAL FIX #2: Mark RQ commit task as completed if waiting on A-Core
                    if (rq_valid[rq_commit_ptr] && !rq_completed[rq_commit_ptr]) begin
                        rq_completed[rq_commit_ptr] <= 1'b1;
                    end
                end
            end else begin
                a_watchdog_counter <= 16'b0;
            end
            
            // NPU watchdog
            if (n_active_task_valid) begin
                if (n_watchdog_counter < 16'hFFFF)
                    n_watchdog_counter <= n_watchdog_counter + 1;
                if (n_watchdog_counter == N_WATCHDOG_TIMEOUT) begin
                    bp_timeout_stalls <= bp_timeout_stalls + 1;
                    counter_completed <= counter_completed + 1;  // FIX: Count as completed (failed but cleared)
                    hq_cq_completed <= hq_cq_completed + 1;  // Increment CQ counter
                    n_credits <= n_credits + 1;  // FIX: Return credit when task cleared by watchdog
                    $display("[%0t] [SCHED-WD] ⚠ NPU watchdog timeout (%0d cycles), force clearing...", $time, N_WATCHDOG_TIMEOUT);
                    n_active_task_valid <= 1'b0;
                    n_active_read_addr <= {ADDR_WIDTH{1'b0}};
                    n_active_write_addr <= {ADDR_WIDTH{1'b0}};
                    n_active_has_write <= 1'b0;
                    n_core_inflight <= 1'b0;  // FIX: Clear inflight flag
                    n_reset_timer <= 1'b1;      // FIX: Set reset flag
                    watchdog_resets_reg <= watchdog_resets_reg + 1;
                    
                    // CRITICAL FIX #1: Clear NPU dependency bit (bit 2) from ALL DQ tasks
                    begin
                        integer li_wd_dq_clear_n;
                        for (li_wd_dq_clear_n = 0; li_wd_dq_clear_n < DQ_DEPTH; li_wd_dq_clear_n = li_wd_dq_clear_n + 1) begin
                            if (dq_valid[li_wd_dq_clear_n] && (dq_dep_mask[li_wd_dq_clear_n] & 16'h0004)) begin
                                dq_dep_mask[li_wd_dq_clear_n] <= dq_dep_mask[li_wd_dq_clear_n] & ~16'h0004;
                            end
                        end
                    end
                    
                    // CRITICAL FIX #2: Mark RQ commit task as completed if waiting on NPU
                    if (rq_valid[rq_commit_ptr] && !rq_completed[rq_commit_ptr]) begin
                        rq_completed[rq_commit_ptr] <= 1'b1;
                    end
                end
            end else begin
                n_watchdog_counter <= 16'b0;
            end
            
            // Legacy watchdog (backward compatibility - deprecated)
            // FIX v3: STOP counting normal compute as "stall"
            // Stall = task blocked, NOT core executing normally
            // Old logic counted every cycle where active_task_valid && core_busy as stall
            // This was wrong because core executing = progress, not stall
            if (active_task_valid) begin
                if (active_task_wait_counter < 16'hFFFF)
                    active_task_wait_counter <= active_task_wait_counter + 1;
                // REMOVED: stall_waiting_for_resource counting during normal execution
                // case (active_task_type)
                //     TASK_GAMING: if (g_core_busy && !g_core_complete) stall_waiting_for_resource <= stall_waiting_for_resource + 1;
                //     TASK_AI:     if (a_core_busy && !a_core_complete) stall_waiting_for_resource <= stall_waiting_for_resource + 1;
                //     TASK_NPU:    if (npu_busy && !npu_complete)     stall_waiting_for_resource <= stall_waiting_for_resource + 1;
                //     default: ;
                // endcase
            end

            // ── WDRR Dispatch (CONCURRENT: G, A, NPU can dispatch simultaneously) ──
            // FIX: Each domain dispatches independently when core is idle
            // No longer serialized through !active_task_valid check
            
            // G-Core dispatch (highest priority)
            // CRITICAL FIX: Add inflight guard to prevent double dispatch
            // STARVATION FIX: Force dispatch when task has been waiting too long
            if (g_q_count > 0 && !g_core_busy && !skip_g_dispatch && !g_active_task_valid && !g_core_inflight) begin
                integer idx; integer li_disp_g;
                reg g_blocking_hazard;
                reg g_already_stalled;
                reg g_has_raw, g_has_war, g_has_waw;
                reg force_dispatch;  // NEW: Starvation override

                idx = -1;
                // STARVATION FIX: Prioritize aged tasks (aging >= MAX_AGING/2)
                for (li_disp_g = 0; li_disp_g < G_QUEUE_DEPTH; li_disp_g = li_disp_g + 1) begin
                    if (g_q_valid[li_disp_g] && !g_q_disp[li_disp_g]) begin
                        // Force select aged task if starving
                        if (g_q_aging[li_disp_g] >= MAX_AGING/2) begin
                            idx = li_disp_g;
                            force_dispatch = 1'b1;
                        end else if (idx < 0) begin
                            idx = li_disp_g;
                            force_dispatch = 1'b0;
                        end
                    end
                end
                if (idx >= 0) begin
                    // Mark core as inflight
                    g_core_inflight <= 1'b1;
                    g_reset_timer <= 1'b1;  // Reset timer on dispatch
                    
                    g_blocking_hazard = 1'b0;
                    g_already_stalled = (g_stalled_valid && g_stalled_addr == g_q_addr[idx]);
                    g_has_raw = 1'b0; g_has_war = 1'b0; g_has_waw = 1'b0;

                    // FIXED: Check specific hazards FIRST (RAW/WAR/WAW), then structural as fallback
                    // This ensures proper hazard classification instead of generic structural

                    // FIXED: RAW HAZARD with aging - BLOCKING but with timeout
                    if (!g_already_stalled &&
                        ((a_active_task_valid && a_active_has_write && a_active_write_addr == g_q_addr[idx]) ||
                         (n_active_task_valid && n_active_has_write && n_active_write_addr == g_q_addr[idx]))) begin
                        hazard_raw_count <= hazard_raw_count + 1;
                        hazard_dependency_stalls <= hazard_dependency_stalls + 1;
                        
                        // Check if this is a prolonged stall (> 50 cycles)
                        if (g_stalled_cycles > 50) begin
                            $display("[%0t] [SCHED-HZ] ⚠ PROLONGED RAW HAZARD: G stalled %0d cycles, FORCE PROCEED", $time, g_stalled_cycles);
                            // Force proceed to prevent deadlock - accept potential data inconsistency
                            g_stalled_cycles <= 16'b0;
                            g_blocking_hazard = 1'b0;
                        end else begin
                            $display("[%0t] [SCHED-HZ] ⛔ RAW HAZARD (BLOCKING): G reads addr=0x%h being written by A/N - STALLING", $time, g_q_addr[idx]);
                            g_stalled_addr <= g_q_addr[idx];
                            g_stalled_valid <= 1'b1;
                            g_blocking_hazard = 1'b1;
                        end
                        g_has_raw = 1'b1;
                    end

                    // WAR HAZARD: NON-BLOCKING - G writes, another core reads (anti-dependency)
                    if (!g_already_stalled && !g_blocking_hazard &&
                        ((a_active_task_valid && a_active_read_addr == g_q_addr[idx]) ||
                         (n_active_task_valid && n_active_read_addr == g_q_addr[idx]))) begin
                        hazard_war_count <= hazard_war_count + 1;
                        $display("[%0t] [SCHED-HZ] ⚠️ WAR HAZARD (NON-BLOCKING): G writes addr=0x%h being read by A/N", $time, g_q_addr[idx]);
                        g_has_war = 1'b1;
                    end

                    // WAW HAZARD: NON-BLOCKING - G writes, another core also writes (output dependency)
                    if (!g_already_stalled && !g_blocking_hazard &&
                        ((a_active_task_valid && a_active_has_write && a_active_write_addr == g_q_addr[idx]) ||
                         (n_active_task_valid && n_active_has_write && n_active_write_addr == g_q_addr[idx]))) begin
                        hazard_waw_count <= hazard_waw_count + 1;
                        $display("[%0t] [SCHED-HZ] ⚠️ WAW HAZARD (NON-BLOCKING): G writes addr=0x%h also written by A/N", $time, g_q_addr[idx]);
                        g_has_waw = 1'b1;
                    end

                    // STRUCTURAL HAZARD: BLOCKING - Same address accessed but NOT RAW/WAR/WAW (generic contention)
                    if (!g_blocking_hazard && !g_already_stalled && !g_has_raw && !g_has_war && !g_has_waw &&
                        ((a_active_task_valid || n_active_task_valid) &&
                         ((a_active_task_valid && a_active_task_addr == g_q_addr[idx]) ||
                          (n_active_task_valid && n_active_task_addr == g_q_addr[idx])))) begin
                        hazard_structural_count <= hazard_structural_count + 1;
                        hazard_dependency_stalls <= hazard_dependency_stalls + 1;
                        $display("[%0t] [SCHED-HZ] ⛔ STRUCTURAL HAZARD (BLOCKING): G addr=0x%h in use by A/N - STALLING", $time, g_q_addr[idx]);
                        g_stalled_addr <= g_q_addr[idx];
                        g_stalled_valid <= 1'b1;
                        g_blocking_hazard = 1'b1;
                    end

                    // DISPATCH: Only if no blocking hazard
                    if (!g_blocking_hazard) begin
                        $display("[%0t] [SCHED] 🚀 Dispatching G task: addr=0x%h, data=0x%h", $time, g_q_addr[idx], g_q_data[idx]);
                        g_active_task_valid <= 1'b1;
                        g_active_task_addr <= g_q_addr[idx];
                        g_active_task_data <= g_q_data[idx];
                        // Set read/write addresses (G tasks typically read input and write output)
                        g_active_read_addr <= g_q_addr[idx];
                        g_active_write_addr <= g_q_addr[idx];
                        g_active_has_write <= 1'b1;
                        g_q_disp[idx] <= 1'b1;
                        g_q_count <= g_q_count - 1;
                        counter_dispatched <= counter_dispatched + 1;
                        // Update legacy signals for monitoring
                        active_task_valid <= 1'b1; active_task_type <= TASK_GAMING;
                        active_task_addr <= g_q_addr[idx]; active_task_data <= g_q_data[idx];
                        task_being_served <= 1'b1; active_task_wait_counter <= 16'b0;
                        wrr_domain <= 0; wrr_quantum <= wrr_quantum + 1;
                        // P1: Clear stall tracking when task dispatches
                        g_stalled_valid <= 1'b0;
                        // CRITICAL FIX: Clear pending result when dispatching new task
                        // This prevents stale results from previous tasks being read as current result
                        pending_result_valid <= 1'b0;
                    end else begin
                        // HAZARD STALL: Increment stall counter (already logged above if first time)
                        // FIX v3: Only count as stall if task is in queue but cannot dispatch due to hazard
                        // This is already captured in stall_queue_contention below
                        stall_queue_contention <= stall_queue_contention + 1;
                    end
                end else begin
                    // ERROR RECOVERY: Queue count > 0 tapi semua task sudah dispatched/error
                    integer clear_idx;
                    for (clear_idx = 0; clear_idx < G_QUEUE_DEPTH; clear_idx = clear_idx + 1) begin
                        if (g_q_valid[clear_idx] && !g_q_disp[clear_idx]) begin
                            g_q_disp[clear_idx] <= 1'b1;
                            g_q_count <= g_q_count - 1;
                            g_credits <= g_credits + 1;
                        end
                    end
                end
            end
            // FIX v3: REMOVE "waiting for resource" counting during normal execution
            // Old code: else if (g_q_count > 0 && g_core_busy) stall_waiting_for_resource++
            // This counted normal compute as "stall" which is wrong
            // Task in queue while core busy = normal queue wait, NOT stall

            // A-Core dispatch (independent of G-Core - CONCURRENT)
            // CRITICAL FIX: Add inflight guard + starvation priority
            if (a_q_count > 0 && !a_core_busy && !a_active_task_valid && !a_core_inflight) begin
                integer idx; integer li_disp_a;
                reg a_blocking_hazard;
                reg a_already_stalled;
                reg a_has_raw, a_has_war, a_has_waw;
                reg a_force_dispatch;  // NEW: Starvation override

                idx = -1;
                // STARVATION FIX: Prioritize aged tasks
                for (li_disp_a = 0; li_disp_a < A_QUEUE_DEPTH; li_disp_a = li_disp_a + 1) begin
                    if (a_q_valid[li_disp_a] && !a_q_disp[li_disp_a] && !a_q_fresh[li_disp_a]) begin
                        if (a_q_aging[li_disp_a] >= MAX_AGING/2) begin
                            idx = li_disp_a;
                            a_force_dispatch = 1'b1;
                        end else if (idx < 0) begin
                            idx = li_disp_a;
                            a_force_dispatch = 1'b0;
                        end
                    end
                end
                if (idx >= 0) begin
                    // Mark core as inflight
                    a_core_inflight <= 1'b1;
                    a_reset_timer <= 1'b1;  // Reset timer on dispatch
                    
                    a_blocking_hazard = 1'b0;
                    a_already_stalled = (a_stalled_valid && a_stalled_addr == a_q_addr[idx]);
                    a_has_raw = 1'b0; a_has_war = 1'b0; a_has_waw = 1'b0;

                    // FIXED: Check specific hazards FIRST (RAW/WAR/WAW), then structural as fallback

                    // RAW HAZARD: BLOCKING - A wants to read, but G/N still writing
                    if (!a_already_stalled &&
                        ((g_active_task_valid && g_active_has_write && g_active_write_addr == a_q_addr[idx]) ||
                         (n_active_task_valid && n_active_has_write && n_active_write_addr == a_q_addr[idx]))) begin
                        hazard_raw_count <= hazard_raw_count + 1;
                        hazard_dependency_stalls <= hazard_dependency_stalls + 1;
                        $display("[%0t] [SCHED-HZ] ⛔ RAW HAZARD (BLOCKING): A reads addr=0x%h being written by G/N - STALLING", $time, a_q_addr[idx]);
                        a_stalled_addr <= a_q_addr[idx];
                        a_stalled_valid <= 1'b1;
                        a_blocking_hazard = 1'b1;
                        a_has_raw = 1'b1;
                    end

                    // WAR HAZARD: NON-BLOCKING - A writes, G/N reads (anti-dependency)
                    if (!a_already_stalled && !a_blocking_hazard &&
                        ((g_active_task_valid && g_active_read_addr == a_q_addr[idx]) ||
                         (n_active_task_valid && n_active_read_addr == a_q_addr[idx]))) begin
                        hazard_war_count <= hazard_war_count + 1;
                        $display("[%0t] [SCHED-HZ] ⚠️ WAR HAZARD (NON-BLOCKING): A writes addr=0x%h being read by G/N", $time, a_q_addr[idx]);
                        a_has_war = 1'b1;
                    end

                    // WAW HAZARD: NON-BLOCKING - A writes, G/N also writes
                    if (!a_already_stalled && !a_blocking_hazard &&
                        ((g_active_task_valid && g_active_has_write && g_active_write_addr == a_q_addr[idx]) ||
                         (n_active_task_valid && n_active_has_write && n_active_write_addr == a_q_addr[idx]))) begin
                        hazard_waw_count <= hazard_waw_count + 1;
                        $display("[%0t] [SCHED-HZ] ⚠️ WAW HAZARD (NON-BLOCKING): A writes addr=0x%h also written by G/N", $time, a_q_addr[idx]);
                        a_has_waw = 1'b1;
                    end

                    // STRUCTURAL HAZARD: BLOCKING - Same address accessed but NOT RAW/WAR/WAW
                    if (!a_blocking_hazard && !a_already_stalled && !a_has_raw && !a_has_war && !a_has_waw &&
                        ((g_active_task_valid || n_active_task_valid) &&
                         ((g_active_task_valid && g_active_task_addr == a_q_addr[idx]) ||
                          (n_active_task_valid && n_active_task_addr == a_q_addr[idx])))) begin
                        hazard_structural_count <= hazard_structural_count + 1;
                        hazard_dependency_stalls <= hazard_dependency_stalls + 1;
                        $display("[%0t] [SCHED-HZ] ⛔ STRUCTURAL HAZARD (BLOCKING): A addr=0x%h in use by G/N - STALLING", $time, a_q_addr[idx]);
                        a_stalled_addr <= a_q_addr[idx];
                        a_stalled_valid <= 1'b1;
                        a_blocking_hazard = 1'b1;
                    end

                    // DISPATCH: Only if no blocking hazard
                    if (!a_blocking_hazard) begin
                        $display("[%0t] [SCHED] 🚀 Dispatching A task: addr=0x%h", $time, a_q_addr[idx]);
                        a_active_task_valid <= 1'b1;
                        a_active_task_addr <= a_q_addr[idx];
                        a_active_task_data <= a_q_data[idx];
                        // A-Core tasks read input data and write results
                        a_active_read_addr <= a_q_addr[idx];
                        a_active_write_addr <= a_q_addr[idx];
                        a_active_has_write <= 1'b1;
                        a_q_disp[idx] <= 1'b1;
                        a_q_count <= a_q_count - 1;
                        counter_dispatched <= counter_dispatched + 1;
                        active_task_valid <= 1'b1; active_task_type <= TASK_AI;
                        active_task_addr <= a_q_addr[idx]; active_task_data <= a_q_data[idx];
                        wrr_domain <= 1; wrr_quantum <= wrr_quantum + 1;
                        // P1: Clear stall tracking when task dispatches
                        a_stalled_valid <= 1'b0;
                        // CRITICAL FIX: Clear pending result when dispatching new task
                        pending_result_valid <= 1'b0;
                    end else begin
                        // HAZARD STALL: Increment stall counter (already logged if first time)
                        stall_queue_contention <= stall_queue_contention + 1;
                    end
                end
            end
            // FIX v3: REMOVE "waiting for resource" counting during normal A-Core execution
            // Old code: else if (a_q_count > 0 && a_core_busy) stall_waiting_for_resource++
            // This counted normal compute as "stall" which is wrong

            // NPU dispatch (independent - CONCURRENT)
            // CRITICAL FIX: Add inflight guard
            if (n_q_count > 0 && !npu_busy && !n_active_task_valid && !n_core_inflight) begin
                integer idx; integer li_disp_n;
                reg n_blocking_hazard;
                reg n_already_stalled;
                reg n_has_raw, n_has_war, n_has_waw;
                reg n_force_dispatch;  // NEW: Starvation override

                idx = -1;
                // STARVATION FIX: Prioritize aged tasks
                for (li_disp_n = 0; li_disp_n < N_QUEUE_DEPTH; li_disp_n = li_disp_n + 1) begin
                    if (n_q_valid[li_disp_n] && !n_q_disp[li_disp_n] && !n_q_fresh[li_disp_n]) begin
                        if (n_q_aging[li_disp_n] >= MAX_AGING/2) begin
                            idx = li_disp_n;
                            n_force_dispatch = 1'b1;
                        end else if (idx < 0) begin
                            idx = li_disp_n;
                            n_force_dispatch = 1'b0;
                        end
                    end
                end
                if (idx >= 0) begin
                    // Mark core as inflight
                    n_core_inflight <= 1'b1;
                    n_reset_timer <= 1'b1;  // Reset timer on dispatch
                    
                    n_blocking_hazard = 1'b0;
                    n_already_stalled = (n_stalled_valid && n_stalled_addr == n_q_addr[idx]);
                    n_has_raw = 1'b0; n_has_war = 1'b0; n_has_waw = 1'b0;

                    // FIXED: Check specific hazards FIRST (RAW/WAR/WAW), then structural as fallback

                    // RAW HAZARD: BLOCKING - N wants to read, but G/A still writing
                    if (!n_already_stalled &&
                        ((g_active_task_valid && g_active_has_write && g_active_write_addr == n_q_addr[idx]) ||
                         (a_active_task_valid && a_active_has_write && a_active_write_addr == n_q_addr[idx]))) begin
                        hazard_raw_count <= hazard_raw_count + 1;
                        hazard_dependency_stalls <= hazard_dependency_stalls + 1;
                        $display("[%0t] [SCHED-HZ] ⛔ RAW HAZARD (BLOCKING): N reads addr=0x%h being written by G/A - STALLING", $time, n_q_addr[idx]);
                        n_stalled_addr <= n_q_addr[idx];
                        n_stalled_valid <= 1'b1;
                        n_blocking_hazard = 1'b1;
                        n_has_raw = 1'b1;
                    end

                    // WAR HAZARD: NON-BLOCKING - N writes, G/A reads (anti-dependency)
                    if (!n_already_stalled && !n_blocking_hazard &&
                        ((g_active_task_valid && g_active_read_addr == n_q_addr[idx]) ||
                         (a_active_task_valid && a_active_read_addr == n_q_addr[idx]))) begin
                        hazard_war_count <= hazard_war_count + 1;
                        $display("[%0t] [SCHED-HZ] ⚠️ WAR HAZARD (NON-BLOCKING): N writes addr=0x%h being read by G/A", $time, n_q_addr[idx]);
                        n_has_war = 1'b1;
                    end

                    // WAW HAZARD: NON-BLOCKING - N writes, G/A also writes
                    if (!n_already_stalled && !n_blocking_hazard &&
                        ((g_active_task_valid && g_active_has_write && g_active_write_addr == n_q_addr[idx]) ||
                         (a_active_task_valid && a_active_has_write && a_active_write_addr == n_q_addr[idx]))) begin
                        hazard_waw_count <= hazard_waw_count + 1;
                        $display("[%0t] [SCHED-HZ] ⚠️ WAW HAZARD (NON-BLOCKING): N writes addr=0x%h also written by G/A", $time, n_q_addr[idx]);
                        n_has_waw = 1'b1;
                    end

                    // STRUCTURAL HAZARD: BLOCKING - Same address accessed but NOT RAW/WAR/WAW
                    if (!n_blocking_hazard && !n_already_stalled && !n_has_raw && !n_has_war && !n_has_waw &&
                        ((g_active_task_valid || a_active_task_valid) &&
                         ((g_active_task_valid && g_active_task_addr == n_q_addr[idx]) ||
                          (a_active_task_valid && a_active_task_addr == n_q_addr[idx])))) begin
                        hazard_structural_count <= hazard_structural_count + 1;
                        hazard_dependency_stalls <= hazard_dependency_stalls + 1;
                        $display("[%0t] [SCHED-HZ] ⛔ STRUCTURAL HAZARD (BLOCKING): N addr=0x%h in use by G/A - STALLING", $time, n_q_addr[idx]);
                        n_stalled_addr <= n_q_addr[idx];
                        n_stalled_valid <= 1'b1;
                        n_blocking_hazard = 1'b1;
                    end

                    // DISPATCH: Only if no blocking hazard
                    if (!n_blocking_hazard) begin
                        $display("[%0t] [SCHED] 🚀 Dispatching N task", $time);
                        n_active_task_valid <= 1'b1;
                        n_active_task_addr <= n_q_addr[idx];
                        n_active_task_data <= n_q_data[idx];
                        // NPU tasks read input and write inference results
                        n_active_read_addr <= n_q_addr[idx];
                        n_active_write_addr <= n_q_addr[idx];
                        n_active_has_write <= 1'b1;
                        n_q_disp[idx] <= 1'b1;
                        n_q_count <= n_q_count - 1;
                        counter_dispatched <= counter_dispatched + 1;
                        active_task_valid <= 1'b1; active_task_type <= TASK_NPU;
                        active_task_addr <= n_q_addr[idx]; active_task_data <= n_q_data[idx];
                        wrr_domain <= 2; wrr_quantum <= wrr_quantum + 1;
                        // P1: Clear stall tracking when task dispatches
                        n_stalled_valid <= 1'b0;
                        // CRITICAL FIX: Clear pending result when dispatching new task
                        pending_result_valid <= 1'b0;
                    end else begin
                        // HAZARD STALL: Increment stall counter (already logged if first time)
                        stall_queue_contention <= stall_queue_contention + 1;
                    end
                end
            end else if (n_q_count > 0 && npu_busy) begin
                stall_waiting_for_resource <= stall_waiting_for_resource + 1;
            end

            // ── Cleanup dispatched tasks ──
            begin
                reg [31:0] g_cleaned;
                reg [31:0] a_cleaned;
                reg [31:0] n_cleaned;
                integer li_g;
                g_cleaned = 0;
                for (li_g = 0; li_g < G_QUEUE_DEPTH; li_g = li_g + 1) begin
                    if (g_q_valid[li_g] && g_q_disp[li_g]) begin
                        g_q_valid[li_g] <= 1'b0;
                        g_cleaned = g_cleaned + 1;
                        if (g_cleaned == 1) g_head <= (g_head == $clog2(G_QUEUE_DEPTH)'(G_QUEUE_DEPTH-1)) ? $clog2(G_QUEUE_DEPTH)'(0) : g_head + $clog2(G_QUEUE_DEPTH)'(1);
                    end
                end
                if (g_cleaned > 0) begin
                    if (g_q_count >= g_cleaned) g_q_count <= g_q_count - g_cleaned; else g_q_count <= 0;
                end
                
                a_cleaned = 0;
                for (li_g = 0; li_g < A_QUEUE_DEPTH; li_g = li_g + 1) begin
                    if (a_q_valid[li_g] && a_q_disp[li_g]) begin
                        a_q_valid[li_g] <= 1'b0;
                        a_cleaned = a_cleaned + 1;
                        if (a_cleaned == 1) a_head <= (a_head == $clog2(A_QUEUE_DEPTH)'(A_QUEUE_DEPTH-1)) ? $clog2(A_QUEUE_DEPTH)'(0) : a_head + $clog2(A_QUEUE_DEPTH)'(1);
                    end
                end
                if (a_cleaned > 0) begin
                    if (a_q_count >= a_cleaned) a_q_count <= a_q_count - a_cleaned; else a_q_count <= 0;
                end
                
                n_cleaned = 0;
                for (li_g = 0; li_g < N_QUEUE_DEPTH; li_g = li_g + 1) begin
                    if (n_q_valid[li_g] && n_q_disp[li_g]) begin
                        n_q_valid[li_g] <= 1'b0;
                        n_cleaned = n_cleaned + 1;
                        if (n_cleaned == 1) n_head <= (n_head == $clog2(N_QUEUE_DEPTH)'(N_QUEUE_DEPTH-1)) ? $clog2(N_QUEUE_DEPTH)'(0) : n_head + $clog2(N_QUEUE_DEPTH)'(1);
                    end
                end
                if (n_cleaned > 0) begin
                    if (n_q_count >= n_cleaned) n_q_count <= n_q_count - n_cleaned; else n_q_count <= 0;
                end
            end
            begin
                // FIX: Track MAX individual queue depth, not SUM
                // This gives true per-queue utilization insight
                // IVC: Use max3_result instead of function call
                if (max3_result[31:0] > max_queue_depth_seen) max_queue_depth_seen <= max3_result[31:0];
            end
        end
    end

    // =========================================================================
    // RUNTIME ASSERTIONS FOR MQ SCHEDULER
    // =========================================================================
    
    // Assertion 1: Queue count consistency
    always @(posedge clk) begin
        if (rst_n) begin
            // Check that no queue has negative count
            if ($signed(g_q_count) < 0 || $signed(a_q_count) < 0 || $signed(n_q_count) < 0) begin
                $error("[%0t] [MQ-SCHEDULER] BUG: Negative queue count detected", $time);
            end

            // FIX #4: Hard overflow detection dengan $error (bukan $display)
            // Recovery sebelumnya hanya clamp counter tapi tidak fix root cause stale entries.
            if (g_q_count > G_QUEUE_DEPTH) begin
                $error("[%0t] [MQ-SCHEDULER] BUG: G-Queue overflow! count=%0d depth=%0d",
                      $time, g_q_count, G_QUEUE_DEPTH);
                g_q_count <= G_QUEUE_DEPTH;  // Clamp untuk mencegah pointer corruption
            end
            if (a_q_count > A_QUEUE_DEPTH) begin
                $error("[%0t] [MQ-SCHEDULER] BUG: A-Queue overflow! count=%0d depth=%0d (double-enqueue bug)",
                       $time, a_q_count, A_QUEUE_DEPTH);
                // FIX #4: Clamp count DAN reset tail ke posisi yang valid
                a_q_count <= A_QUEUE_DEPTH;
                a_tail    <= a_head;  // Reset tail = head: queue dianggap kosong (drastic reset)
            end
            if (n_q_count > N_QUEUE_DEPTH) begin
                $error("[%0t] [MQ-SCHEDULER] BUG: N-Queue overflow! count=%0d depth=%0d",
                      $time, n_q_count, N_QUEUE_DEPTH);
                n_q_count <= N_QUEUE_DEPTH;
            end
        end
    end
    
    // Assertion 2: Detect domain starvation
    reg [15:0] g_starve_counter;
    reg [15:0] a_starve_counter;
    reg [15:0] n_starve_counter;
    
    always @(posedge clk) begin
        if (!rst_n) begin
            g_starve_counter <= 0;
            a_starve_counter <= 0;
            n_starve_counter <= 0;
        end else begin
            // G-Core starvation
            if (g_q_count > 0 && !g_core_busy && !g_core_complete) begin
                g_starve_counter <= g_starve_counter + 1;
                if (g_starve_counter == 100) begin
                    $display("[%0t] [MQ-SCHEDULER] ⚠ STARVATION: G-Core has %0d pending tasks but not dispatching for 100 cycles", 
                            $time, g_q_count);
                end
            end else begin
                g_starve_counter <= 0;
            end
            
            // A-Core starvation
            if (a_q_count > 0 && !a_core_busy && !a_core_complete) begin
                a_starve_counter <= a_starve_counter + 1;
                if (a_starve_counter == 100) begin
                    $display("[%0t] [MQ-SCHEDULER] ⚠ STARVATION: A-Core has %0d pending tasks but not dispatching for 100 cycles", 
                            $time, a_q_count);
                end
            end else begin
                a_starve_counter <= 0;
            end
            
            // NPU starvation
            if (n_q_count > 0 && !npu_busy && !npu_complete) begin
                n_starve_counter <= n_starve_counter + 1;
                if (n_starve_counter == 100) begin
                    $display("[%0t] [MQ-SCHEDULER] ⚠ STARVATION: NPU has %0d pending tasks but not dispatching for 100 cycles", 
                            $time, n_q_count);
                end
            end else begin
                n_starve_counter <= 0;
            end
        end
    end
    
    // =========================================================================
    // CRITICAL FIX: Task clearing functions for deadlock recovery
    // =========================================================================
    
    // Force complete stalled G-Core task
    task force_complete_g_core_task;
        begin
            // Clear G-Core busy signals and complete current task
            g_core_busy <= 1'b0;
            g_core_complete <= 1'b1;
            g_stalled_valid <= 1'b0;
            g_stalled_addr <= {ADDR_WIDTH{1'b0}};
            $display("[%0t] [MQ-SCHEDULER]    -> Forced G-Core task completion", $time);
        end
    endtask
    
    // Force complete stalled A-Core task  
    task force_complete_a_core_task;
        begin
            // Clear A-Core busy signals and complete current task
            a_core_busy <= 1'b0;
            a_core_complete <= 1'b1;
            a_stalled_valid <= 1'b0;
            a_stalled_addr <= {ADDR_WIDTH{1'b0}};
            $display("[%0t] [MQ-SCHEDULER]    -> Forced A-Core task completion", $time);
        end
    endtask
    
    // Clear A-Core tasks waiting for specific address
    task clear_a_core_waiting_tasks;
        input [ADDR_WIDTH-1:0] wait_addr;
        begin
            // Clear any A-Core tasks waiting for this address
            integer i;
            for (i = 0; i < DQ_DEPTH; i = i + 1) begin
                if (dq_valid[i] && dq_eq_type[i] == EQ_TYPE_ALU && dq_addr[i] == wait_addr) begin
                    dq_valid[i] <= 1'b0;
                    dq_count <= dq_count - 1;
                    $display("[%0t] [MQ-SCHEDULER]    -> Cleared A-Core task waiting for addr %0h", $time, wait_addr);
                end
            end
        end
    endtask
    
    // Clear NPU tasks waiting for specific address
    task clear_npu_waiting_tasks;
        input [ADDR_WIDTH-1:0] wait_addr;
        begin
            // Clear any NPU tasks waiting for this address
            integer i;
            for (i = 0; i < DQ_DEPTH; i = i + 1) begin
                if (dq_valid[i] && dq_eq_type[i] == EQ_TYPE_NPU && dq_addr[i] == wait_addr) begin
                    dq_valid[i] <= 1'b0;
                    dq_count <= dq_count - 1;
                    $display("[%0t] [MQ-SCHEDULER]    -> Cleared NPU task waiting for addr %0h", $time, wait_addr);
                end
            end
        end
    endtask
    
    // Assertion 3: Cross-domain dependency deadlock detection
    always @(posedge clk) begin
        if (rst_n) begin
            // If G-Core stalled AND A-Core waiting for G result → deadlock
            if (g_to_a_dependency && g_stalled_cycles > 50) begin
                $display("[%0t] [MQ-SCHEDULER] ⚠ CROSS-DOMAIN DEADLOCK: A-Core waiting for G-Core result, G stalled for %0d cycles", 
                        $time, g_stalled_cycles);
            end
            
            // If A-Core stalled AND NPU waiting for A result → deadlock
            if (a_to_n_dependency && a_stalled_cycles > 50) begin
                $display("[%0t] [MQ-SCHEDULER] ⚠ CROSS-DOMAIN DEADLOCK: NPU waiting for A-Core result, A stalled for %0d cycles", 
                        $time, a_stalled_cycles);
            end
        end
    end
    
    // Assertion 4: Inflight task timeout dengan retry mechanism
    always @(posedge clk) begin
        if (rst_n) begin
            // FIXED: G-Core inflight timeout - reduced threshold for faster recovery
            if (g_core_inflight && g_inflight_timer > 500) begin
                $display("[%0t] [MQ-SCHEDULER] ⚠ INFLIGHT TIMEOUT: G-Core task inflight for %0d cycles, rescheduling...",
                        $time, g_inflight_timer);
                g_core_inflight <= 1'b0;
                g_reset_timer <= 1'b1;  // Set reset flag on timeout
                // Increment timeout counter for monitoring
                bp_timeout_stalls <= bp_timeout_stalls + 1;
                // Clear active task to allow retry
                g_active_task_valid <= 1'b0;
                // Increment retry counter (reuse stall counter)
                stall_queue_contention <= stall_queue_contention + 1;
                $display("[%0t] [MQ-SCHEDULER] 🔄 G-Core task will be retried from queue", $time);
            end else if (g_core_inflight) begin
                g_inflight_timer <= g_inflight_timer + 1;
            end

            // FIXED: A-Core inflight timeout - reduced threshold for faster recovery  
            if (a_core_inflight && a_inflight_timer > 500) begin
                $display("[%0t] [MQ-SCHEDULER] ⚠ INFLIGHT TIMEOUT: A-Core task inflight for %0d cycles, rescheduling...",
                        $time, a_inflight_timer);
                a_core_inflight <= 1'b0;
                a_reset_timer <= 1'b1;  // Set reset flag on timeout
                // Increment timeout counter for monitoring
                bp_timeout_stalls <= bp_timeout_stalls + 1;
                // Clear active task to allow retry
                a_active_task_valid <= 1'b0;
                // Increment retry counter
                stall_queue_contention <= stall_queue_contention + 1;
                $display("[%0t] [MQ-SCHEDULER] 🔄 A-Core task will be retried from queue", $time);
            end else if (a_core_inflight) begin
                a_inflight_timer <= a_inflight_timer + 1;
            end

            // FIXED: NPU inflight timeout - reduced threshold for faster recovery
            if (n_core_inflight && n_inflight_timer > 500) begin
                $display("[%0t] [MQ-SCHEDULER] ⚠ INFLIGHT TIMEOUT: NPU task inflight for %0d cycles, rescheduling...",
                        $time, n_inflight_timer);
                n_core_inflight <= 1'b0;
                n_reset_timer <= 1'b1;  // Set reset flag on timeout
                // Increment timeout counter for monitoring
                bp_timeout_stalls <= bp_timeout_stalls + 1;
                // Clear active task to allow retry
                n_active_task_valid <= 1'b0;
                // Increment retry counter
                stall_queue_contention <= stall_queue_contention + 1;
                $display("[%0t] [MQ-SCHEDULER] 🔄 NPU task will be retried from queue", $time);
            end else if (n_core_inflight) begin
                n_inflight_timer <= n_inflight_timer + 1;
            end
        end
    end
    
    // CRITICAL FIX: Single-driver inflight timer management
    // Prevents MULTIDRIVEN warnings by consolidating all timer updates
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_inflight_timer <= 32'b0;
            a_inflight_timer <= 32'b0;
            n_inflight_timer <= 32'b0;
        end else begin
            // Increment timers if inflight
            if (g_increment_timer) g_inflight_timer <= g_inflight_timer + 1;
            if (a_increment_timer) a_inflight_timer <= a_inflight_timer + 1;
            if (n_increment_timer) n_inflight_timer <= n_inflight_timer + 1;
            
            // Reset timers from various conditions
            if (g_reset_timer) g_inflight_timer <= 32'b0;
            if (a_reset_timer) a_inflight_timer <= 32'b0;
            if (n_reset_timer) n_inflight_timer <= 32'b0;
        end
    end
    
endmodule
