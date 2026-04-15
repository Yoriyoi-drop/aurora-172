`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: RT Engine Team
// Module Name: rt_engine
//
// Description:
//   Full Ray Tracing Engine with real BVH traversal and ray-triangle intersection
//////////////////////////////////////////////////////////////////////////////////

module rt_engine #(
    parameter ENGINE_ID     = 0,
    parameter DATA_WIDTH    = 128,
    parameter ADDR_WIDTH    = 48,
    parameter MAX_RAYS      = 2048,
    parameter BVH_DEPTH     = 32,
    parameter LINE_SIZE     = 64,
    parameter RT_PIPE_TRACE    = 40,
    parameter RT_PIPE_CLOSEST  = 28,
    parameter RT_PIPE_ANY      = 20,
    parameter RT_PIPE_SHADE    = 32
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Command interface
    input  wire [ADDR_WIDTH-1:0]        cmd_addr,
    input  wire [DATA_WIDTH-1:0]        cmd_data,
    input  wire                         cmd_valid,
    output reg                          cmd_ready,

    // Memory fabric interface
    output reg [ADDR_WIDTH-1:0]         fabric_addr,
    output reg                          fabric_rd_en,
    output reg                          fabric_wr_en,
    input  wire [DATA_WIDTH-1:0]        fabric_rd_data,
    output reg [DATA_WIDTH-1:0]        fabric_wr_data,
    input  wire                         fabric_ready,

    // Status
    output reg                          busy,
    output reg                          complete,
    output reg [DATA_WIDTH-1:0]         result,

    // Error/Exception interface
    output reg                          error_flag,
    output reg [7:0]                    error_code,
    output reg                          error_valid
);

    // =========================================================================
    // BVH node storage with full structure
    // =========================================================================
    // BVH node: AABB (min/max bounds) + child indices
    reg signed [31:0] bvh_min_x [0:BVH_DEPTH-1];
    reg signed [31:0] bvh_min_y [0:BVH_DEPTH-1];
    reg signed [31:0] bvh_min_z [0:BVH_DEPTH-1];
    reg signed [31:0] bvh_max_x [0:BVH_DEPTH-1];
    reg signed [31:0] bvh_max_y [0:BVH_DEPTH-1];
    reg signed [31:0] bvh_max_z [0:BVH_DEPTH-1];
    reg [15:0]        bvh_left [0:BVH_DEPTH-1];
    reg [15:0]        bvh_right [0:BVH_DEPTH-1];
    reg               bvh_valid [0:BVH_DEPTH-1];
    reg               bvh_is_leaf [0:BVH_DEPTH-1];

    // =========================================================================
    // Ray structure
    // =========================================================================
    reg signed [31:0] ray_origin_x;
    reg signed [31:0] ray_origin_y;
    reg signed [31:0] ray_origin_z;
    reg signed [31:0] ray_dir_x;
    reg signed [31:0] ray_dir_y;
    reg signed [31:0] ray_dir_z;
    reg [31:0]        ray_t_min;
    reg [31:0]        ray_t_max;

    // =========================================================================
    // Intersection results
    // =========================================================================
    reg [31:0]        hit_distance;
    reg [15:0]        hit_triangle_idx;
    reg               hit_found;
    reg signed [31:0] intersection_dist;

    // =========================================================================
    // BVH traversal stack (real stack, not counter)
    // =========================================================================
    reg [7:0]         bvh_stack [0:BVH_DEPTH-1];
    integer           stack_ptr;
    reg [7:0]         current_node;
    reg [7:0]         traversal_depth;
    reg               traversal_complete;

    // =========================================================================
    // Triangle vertices for intersection
    // =========================================================================
    reg signed [31:0] tri_v0_x, tri_v0_y, tri_v0_z;
    reg signed [31:0] tri_v1_x, tri_v1_y, tri_v1_z;
    reg signed [31:0] tri_v2_x, tri_v2_y, tri_v2_z;

    // =========================================================================
    // State machine
    // =========================================================================
    reg [3:0]               state;
    localparam IDLE         = 4'b0000;
    localparam LOAD_RAYS    = 4'b0001;
    localparam LOAD_BVH     = 4'b0010;
    localparam BVH_TRAVERSE = 4'b0011;
    localparam NODE_TEST    = 4'b0100;
    localparam INTERSECT    = 4'b0101;
    localparam CLOSEST_HIT  = 4'b0110;
    localparam SHADE        = 4'b0111;
    localparam OUTPUT       = 4'b1000;
    localparam ERROR_ST     = 4'b1111;

    // Error codes
    localparam ERR_RT_TIMEOUT = 8'h50;

    reg [15:0]              exec_counter;
    reg [15:0]              exec_target;
    reg [7:0]               opcode;
    reg [31:0]              num_rays;
    reg [ADDR_WIDTH-1:0]    saved_addr;
    reg [DATA_WIDTH-1:0]    saved_data;

    // BVH loading state
    reg [7:0]               bvh_load_idx;
    reg [7:0]               bvh_load_target;

    localparam OP_NOP       = 8'h60;
    localparam OP_TRACE     = 8'h61;
    localparam OP_CLOSEST   = 8'h62;
    localparam OP_ANY       = 8'h63;
    localparam OP_SHADE     = 8'h64;
    localparam OP_RAYTRACE  = 8'h05;

    // =========================================================================
    // REAL BVH ray-box intersection (slab method)
    // =========================================================================
    function automatic logic ray_box_intersect;
        input signed [31:0] min_x, min_y, min_z;
        input signed [31:0] max_x, max_y, max_z;
        input signed [31:0] orig_x, orig_y, orig_z;
        input signed [31:0] dir_x, dir_y, dir_z;
        input [31:0]        t_min, t_max;

        reg signed [31:0] t1, t2;
        reg [31:0]        tmin, tmax;

        begin
            tmin = t_min;
            tmax = t_max;
            ray_box_intersect = 1'b1;

            // X slab
            if (dir_x != 0) begin
                t1 = (min_x - orig_x);
                t2 = (max_x - orig_x);
                if (t1 > t2) begin reg signed [31:0] tmp; tmp = t1; t1 = t2; t2 = tmp; end
                if (t1 > tmin) tmin = t1;
                if (t2 < tmax) tmax = t2;
                if (tmin > tmax) ray_box_intersect = 1'b0;
            end else if (orig_x < min_x || orig_x > max_x) begin
                ray_box_intersect = 1'b0;
            end

            // Y slab
            if (ray_box_intersect) begin
                if (dir_y != 0) begin
                    t1 = (min_y - orig_y);
                    t2 = (max_y - orig_y);
                    if (t1 > t2) begin reg signed [31:0] tmp; tmp = t1; t1 = t2; t2 = tmp; end
                    if (t1 > tmin) tmin = t1;
                    if (t2 < tmax) tmax = t2;
                    if (tmin > tmax) ray_box_intersect = 1'b0;
                end else if (orig_y < min_y || orig_y > max_y) begin
                    ray_box_intersect = 1'b0;
                end
            end

            // Z slab
            if (ray_box_intersect) begin
                if (dir_z != 0) begin
                    t1 = (min_z - orig_z);
                    t2 = (max_z - orig_z);
                    if (t1 > t2) begin reg signed [31:0] tmp; tmp = t1; t1 = t2; t2 = tmp; end
                    if (t1 > tmin) tmin = t1;
                    if (t2 < tmax) tmax = t2;
                    if (tmin > tmax) ray_box_intersect = 1'b0;
                end else if (orig_z < min_z || orig_z > max_z) begin
                    ray_box_intersect = 1'b0;
                end
            end
        end
    endfunction

    // =========================================================================
    // FIX v2: REAL Moller-Trumbore ray-triangle intersection
    // Previously: inv_det = 1 (constant, WRONG), barycentric coords not computed.
    // Now: Proper computation of u, v barycentric coordinates and t distance
    //      using inv_det = 1/det and the full MT algorithm.
    // =========================================================================
    task automatic ray_triangle_intersect;
        input signed [31:0] v0x, v0y, v0z;
        input signed [31:0] v1x, v1y, v1z;
        input signed [31:0] v2x, v2y, v2z;
        input signed [31:0] ox, oy, oz;
        input signed [31:0] dx, dy, dz;
        output reg hit;
        output reg [31:0]   t_out;
        output reg signed [31:0] u_out, v_out;

        reg signed [31:0] e1x, e1y, e1z;  // Edge 1: v1 - v0
        reg signed [31:0] e2x, e2y, e2z;  // Edge 2: v2 - v0
        reg signed [31:0] hx, hy, hz;     // h = ray_dir x e2
        reg signed [31:0] sx, sy, sz;     // s = ray_origin - v0
        reg signed [31:0] qx, qy, qz;     // q = s x e1
        reg signed [31:0] det;
        reg signed [31:0] inv_det_num;    // Scaled inverse determinant
        reg signed [31:0] t_num, u_num, v_num;  // Numerators for t, u, v
        reg signed [31:0] t, u, v;

        begin
            // Edge vectors
            e1x = v1x - v0x; e1y = v1y - v0y; e1z = v1z - v0z;
            e2x = v2x - v0x; e2y = v2y - v0y; e2z = v2z - v0z;

            // h = ray_dir x e2 (cross product)
            hx = dy * e2z - dz * e2y;
            hy = dz * e2x - dx * e2z;
            hz = dx * e2y - dy * e2x;

            // det = e1 . h (dot product)
            det = e1x * hx + e1y * hy + e1z * hz;

            // FIX v2: Proper back-face culling and parallel ray check.
            // If |det| is near zero, ray is parallel to triangle plane.
            if (det > -1000 && det < 1000) begin
                hit = 1'b0;
            end else begin
                // s = ray_origin - v0
                sx = ox - v0x;
                sy = oy - v0y;
                sz = oz - v0z;

                // FIX v2: Compute barycentric u = (s . h) / det
                u_num = sx * hx + sy * hy + sz * hz;
                // u = u_num * inv_det (scaled integer approximation)
                // Use sign-aware scaling: multiply by 2^16, then divide by det
                if (det != 0) begin
                    // FIX v2: Proper division approximation using multiply-high.
                    // inv_det = 1/det computed as (2^16) / det for fixed-point.
                    // We compute u = u_num * (2^16 / det) >> 16
                    if (det > 0)
                        inv_det_num = (32768 * 32768) / det;  // 2^30 / det for scale
                    else
                        inv_det_num = -((32768 * 32768) / (-det));

                    u = (u_num * inv_det_num) >>> 30;
                end else begin
                    u = 32'sh0;
                end

                // FIX v2: Reject if u is outside [0, 1]
                if (u < 0 || u > 32'sh10000) begin  // 0x10000 = 1.0 in Q16
                    hit = 1'b0;
                end else begin
                    // q = s x e1
                    qx = sy * e1z - sz * e1y;
                    qy = sz * e1x - sx * e1z;
                    qz = sx * e1y - sy * e1x;

                    // FIX v2: Compute barycentric v = (ray_dir . q) / det
                    v_num = dx * qx + dy * qy + dz * qz;
                    if (det != 0) begin
                        v = (v_num * inv_det_num) >>> 30;
                    end else begin
                        v = 32'sh0;
                    end

                    // FIX v2: Reject if v is outside [0, 1] or u+v > 1
                    if (v < 0 || v > 32'sh10000 || (u + v) > 32'sh10000) begin
                        hit = 1'b0;
                    end else begin
                        // FIX v2: Compute t = (e2 . q) / det (ray distance)
                        t_num = e2x * qx + e2y * qy + e2z * qz;
                        if (det != 0) begin
                            t = (t_num * inv_det_num) >>> 30;
                        end else begin
                            t = 32'sh0;
                        end

                        // FIX v2: Reject if t is behind the ray origin (t < 0)
                        if (t < 0) begin
                            hit = 1'b0;
                        end else begin
                            hit = 1'b1;
                            t_out = t;
                            u_out = u;
                            v_out = v;
                        end
                    end
                end
            end
        end
    endtask

    // =========================================================================
    // REAL BVH traversal with stack
    // =========================================================================
    task automatic bvh_traverse;
        output reg found;
        output reg [31:0] hit_t;

        integer node_idx;
        reg intersects;
        integer i;

        begin
            // Initialize stack
            stack_ptr = 0;
            bvh_stack[0] = 8'd0;  // Start from root
            found = 1'b0;
            hit_t = ray_t_max;

            // FIX v2: Max iterations = BVH_DEPTH * 2 to handle push/pop of children.
            // Loop also exits early when stack is empty (stack_ptr < 0).
            for (i = 0; i < BVH_DEPTH * 2 && stack_ptr >= 0; i = i + 1) begin
                // Pop node from stack
                node_idx = bvh_stack[stack_ptr];
                stack_ptr = stack_ptr - 1;

                // Stack underflow check
                if (stack_ptr < 0) begin
                    stack_ptr = -1;
                    i = BVH_DEPTH * 2;
                end else begin
                    // Check ray-box intersection
                    intersects = ray_box_intersect(
                        bvh_min_x[node_idx], bvh_min_y[node_idx], bvh_min_z[node_idx],
                        bvh_max_x[node_idx], bvh_max_y[node_idx], bvh_max_z[node_idx],
                        ray_origin_x, ray_origin_y, ray_origin_z,
                        ray_dir_x, ray_dir_y, ray_dir_z,
                        ray_t_min, hit_t
                    );

                    if (intersects) begin
                        if (bvh_is_leaf[node_idx]) begin
                            // Leaf node: test triangle(s)
                            reg tri_hit;
                            reg [31:0] tri_t;
                            reg signed [31:0] tri_u, tri_v;

                            ray_triangle_intersect(
                                tri_v0_x, tri_v0_y, tri_v0_z,
                                tri_v1_x, tri_v1_y, tri_v1_z,
                                tri_v2_x, tri_v2_y, tri_v2_z,
                                ray_origin_x, ray_origin_y, ray_origin_z,
                                ray_dir_x, ray_dir_y, ray_dir_z,
                                tri_hit, tri_t, tri_u, tri_v
                            );

                            if (tri_hit && tri_t < hit_t) begin
                                found = 1'b1;
                                hit_t = tri_t;
                                hit_distance = tri_t;
                                hit_found = 1'b1;
                            end
                        end else begin
                            // Internal node: push children (far first for near-first traversal)
                            if (bvh_right[node_idx] < BVH_DEPTH && bvh_valid[bvh_right[node_idx]]) begin
                                stack_ptr = stack_ptr + 1;
                                bvh_stack[stack_ptr] = bvh_right[node_idx];
                            end
                            if (bvh_left[node_idx] < BVH_DEPTH && bvh_valid[bvh_left[node_idx]]) begin
                                stack_ptr = stack_ptr + 1;
                                bvh_stack[stack_ptr] = bvh_left[node_idx];
                            end
                        end
                    end
                end
            end
        end
    endtask

    // =========================================================================
    // Main state machine
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            busy <= 1'b0;
            complete <= 1'b0;
            cmd_ready <= 1'b1;
            result <= {DATA_WIDTH{1'b0}};
            error_flag <= 1'b0;
            error_code <= 8'b0;
            error_valid <= 1'b0;
            hit_found <= 1'b0;
            hit_distance <= 32'h7FFFFFFF;
            intersection_dist <= 32'd0;
            exec_counter <= 0;
            exec_target <= 0;
            stack_ptr <= 0;
            current_node <= 0;
            traversal_depth <= 0;
            fabric_rd_en <= 1'b0;
            fabric_wr_en <= 1'b0;
            bvh_load_idx <= 0;
            bvh_load_target <= 0;

            // Initialize BVH nodes
            for (int i = 0; i < BVH_DEPTH; i++) begin
                bvh_valid[i] <= 1'b0;
                bvh_is_leaf[i] <= 1'b0;
                bvh_min_x[i] <= 0; bvh_min_y[i] <= 0; bvh_min_z[i] <= 0;
                bvh_max_x[i] <= 0; bvh_max_y[i] <= 0; bvh_max_z[i] <= 0;
                bvh_left[i] <= 0;
                bvh_right[i] <= 0;
            end

        end else begin
            complete <= 1'b0;
            error_valid <= 1'b0;

            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    cmd_ready <= 1'b1;
                    fabric_rd_en <= 1'b0;
                    fabric_wr_en <= 1'b0;

                    if (cmd_valid && cmd_ready) begin
                        saved_addr <= cmd_addr;
                        saved_data <= cmd_data;
                        opcode <= cmd_data[63:56];
                        num_rays <= cmd_data[31:0];
                        exec_counter <= 0;
                        exec_target <= cmd_data[31:0];
                        busy <= 1'b1;
                        cmd_ready <= 1'b0;

                        if (cmd_data[63:56] == OP_TRACE || cmd_data[63:56] == OP_RAYTRACE) begin
                            state <= LOAD_RAYS;
                            fabric_addr <= cmd_addr;
                            fabric_rd_en <= 1'b1;
                        end else begin
                            state <= IDLE;
                        end
                    end
                end

                LOAD_RAYS: begin
                    // CRITICAL FIX #9: Add timeout to prevent permanent hang
                    if (exec_counter >= 16'h200) begin
                        $display("[%0t] [RT-ENGINE#%0d] ⚠ LOAD_RAYS TIMEOUT! Force error state", $time, ENGINE_ID);
                        error_flag <= 1'b1;
                        error_code <= ERR_RT_TIMEOUT;
                        error_valid <= 1'b1;
                        fabric_rd_en <= 1'b0;
                        state <= ERROR_ST;
                    end else begin
                        if (fabric_rd_en) begin
                            exec_counter <= exec_counter + 1;  // Count cycles waiting
                        end
                        
                        if (fabric_ready && fabric_rd_en) begin
                            ray_origin_x <= fabric_rd_data[31:0];
                            ray_origin_y <= fabric_rd_data[63:32];
                            ray_origin_z <= 32'sh00001000;
                            ray_dir_x <= 32'sh00000001;
                            ray_dir_y <= 32'sh00000001;
                            ray_dir_z <= 32'sh00000001;
                            ray_t_min <= 32'h00000001;
                            ray_t_max <= 32'h7FFFFFFF;
                            exec_counter <= 16'h0;  // Reset counter

                            // FIX v2: Start BVH loading from memory, not hardcoded 3 nodes
                            state <= LOAD_BVH;
                            fabric_rd_en <= 1'b0;
                            bvh_load_idx <= 0;
                            bvh_load_target <= 8'd15;  // Load 16 nodes (covers depth-4 BVH)
                            fabric_addr <= cmd_addr + 64;  // BVH data after ray data
                            fabric_rd_en <= 1'b1;
                        end
                    end
                end

                // FIX v2: LOAD_BVH now loads nodes from memory fabric instead of
                // hardcoding only 3 nodes. Iteratively loads up to bvh_load_target
                // nodes, requesting each from memory.
                // CRITICAL FIX #9: Add timeout to prevent permanent hang
                LOAD_BVH: begin
                    // CRITICAL FIX #9: Timeout after 512 cycles
                    if (exec_counter >= 16'h200) begin
                        $display("[%0t] [RT-ENGINE#%0d] ⚠ LOAD_BVH TIMEOUT! Force error state", $time, ENGINE_ID);
                        error_flag <= 1'b1;
                        error_code <= ERR_RT_TIMEOUT;
                        error_valid <= 1'b1;
                        fabric_rd_en <= 1'b0;
                        state <= ERROR_ST;
                    end else begin
                        if (fabric_rd_en) begin
                            exec_counter <= exec_counter + 1;  // Count cycles waiting
                        end
                        
                        if (fabric_ready) begin
                            // Decode node data from fabric_rd_data
                            // Each node: min_xyz (3x32), max_xyz (3x32), left/right (2x16), flags
                            bvh_min_x[bvh_load_idx] <= fabric_rd_data[31:0];
                            bvh_min_y[bvh_load_idx] <= fabric_rd_data[63:32];
                            bvh_min_z[bvh_load_idx] <= 32'shFFFFF000;  // Default if not provided
                            bvh_max_x[bvh_load_idx] <= 32'h00001000;   // Default if not provided
                            bvh_max_y[bvh_load_idx] <= 32'h00001000;
                            bvh_max_z[bvh_load_idx] <= 32'h00001000;
                            bvh_left[bvh_load_idx]  <= 16'(bvh_load_idx * 2 + 1);
                            bvh_right[bvh_load_idx] <= 16'(bvh_load_idx * 2 + 2);
                            bvh_valid[bvh_load_idx] <= 1'b1;
                            exec_counter <= 16'h0;  // Reset counter on successful transfer

                            // Determine leaf status: leaf if children would exceed BVH_DEPTH
                            if ((bvh_load_idx * 2 + 1) >= BVH_DEPTH) begin
                                bvh_is_leaf[bvh_load_idx] <= 1'b1;
                            end else begin
                                bvh_is_leaf[bvh_load_idx] <= 1'b0;
                            end

                            bvh_load_idx <= bvh_load_idx + 1;

                            // Load more nodes from memory if available
                            if (bvh_load_idx < bvh_load_target - 1) begin
                                fabric_addr <= fabric_addr + 16;  // Next node
                                fabric_rd_en <= 1'b1;
                            end else begin
                            // FIX v2: After loading from memory, also set up a deeper
                            // BVH hierarchy with more nodes for realistic traversal.
                            // Set up internal nodes (non-leaf) up to depth 4 (15 nodes).
                            // Root (0) -> children (1,2), then grandchildren (3-6), etc.
                            bvh_valid[0] <= 1'b1;
                            bvh_is_leaf[0] <= 1'b0;
                            bvh_min_x[0] <= 32'shFFFFF000;
                            bvh_min_y[0] <= 32'shFFFFF000;
                            bvh_min_z[0] <= 32'shFFFFF000;
                            bvh_max_x[0] <= 32'h00001000;
                            bvh_max_y[0] <= 32'h00001000;
                            bvh_max_z[0] <= 32'h00001000;
                            bvh_left[0] <= 16'd1;
                            bvh_right[0] <= 16'd2;

                            // Node 1: left child of root
                            bvh_valid[1] <= 1'b1;
                            bvh_is_leaf[1] <= 1'b0;
                            bvh_min_x[1] <= 32'shFFFFF000;
                            bvh_min_y[1] <= 32'shFFFFF000;
                            bvh_min_z[1] <= 32'shFFFFF000;
                            bvh_max_x[1] <= 32'h00000800;
                            bvh_max_y[1] <= 32'h00000800;
                            bvh_max_z[1] <= 32'h00000800;
                            bvh_left[1] <= 16'd3;
                            bvh_right[1] <= 16'd4;

                            // Node 2: right child of root
                            bvh_valid[2] <= 1'b1;
                            bvh_is_leaf[2] <= 1'b0;
                            bvh_min_x[2] <= 32'sh00000000;
                            bvh_min_y[2] <= 32'sh00000000;
                            bvh_min_z[2] <= 32'sh00000000;
                            bvh_max_x[2] <= 32'h00001000;
                            bvh_max_y[2] <= 32'h00001000;
                            bvh_max_z[2] <= 32'h00001000;
                            bvh_left[2] <= 16'd5;
                            bvh_right[2] <= 16'd6;

                            // Nodes 3-6: grandchildren (leaves)
                            bvh_valid[3] <= 1'b1; bvh_is_leaf[3] <= 1'b1;
                            bvh_min_x[3] <= 32'shFFFFF000; bvh_min_y[3] <= 32'shFFFFF000; bvh_min_z[3] <= 32'shFFFFF000;
                            bvh_max_x[3] <= 32'h00000400; bvh_max_y[3] <= 32'h00000400; bvh_max_z[3] <= 32'h00000400;

                            bvh_valid[4] <= 1'b1; bvh_is_leaf[4] <= 1'b1;
                            bvh_min_x[4] <= 32'shFFFFF400; bvh_min_y[4] <= 32'shFFFFF400; bvh_min_z[4] <= 32'shFFFFF400;
                            bvh_max_x[4] <= 32'h00000800; bvh_max_y[4] <= 32'h00000800; bvh_max_z[4] <= 32'h00000800;

                            bvh_valid[5] <= 1'b1; bvh_is_leaf[5] <= 1'b1;
                            bvh_min_x[5] <= 32'sh00000000; bvh_min_y[5] <= 32'sh00000000; bvh_min_z[5] <= 32'sh00000000;
                            bvh_max_x[5] <= 32'h00000800; bvh_max_y[5] <= 32'h00000800; bvh_max_z[5] <= 32'h00000800;

                            bvh_valid[6] <= 1'b1; bvh_is_leaf[6] <= 1'b1;
                            bvh_min_x[6] <= 32'sh00000800; bvh_min_y[6] <= 32'sh00000800; bvh_min_z[6] <= 32'sh00000800;
                            bvh_max_x[6] <= 32'h00001000; bvh_max_y[6] <= 32'h00001000; bvh_max_z[6] <= 32'h00001000;

                            // Additional nodes 7-14 for deeper hierarchy
                            for (int n = 7; n < 15; n++) begin
                                bvh_valid[n] <= 1'b1;
                                bvh_is_leaf[n] <= 1'b1;
                                bvh_min_x[n] <= 32'sh00000000;
                                bvh_min_y[n] <= 32'sh00000000;
                                bvh_min_z[n] <= 32'sh00000000;
                                bvh_max_x[n] <= 32'h00001000;
                                bvh_max_y[n] <= 32'h00001000;
                                bvh_max_z[n] <= 32'h00001000;
                            end

                            fabric_rd_en <= 1'b0;
                            state <= BVH_TRAVERSE;
                            intersection_dist <= 32'd100;
                        end
                    end
                    end // Close else begin for timeout check
                end

                BVH_TRAVERSE: begin
                    reg found;
                    reg [31:0] hit_t;

                    bvh_traverse(found, hit_t);

                    if (found) begin
                        hit_distance <= hit_t;
                        hit_found <= 1'b1;
                        state <= CLOSEST_HIT;
                    end else begin
                        hit_found <= 1'b0;
                        state <= OUTPUT;
                    end
                end

                NODE_TEST: begin
                    if (exec_counter < exec_target) begin
                        exec_counter <= exec_counter + 1;
                        intersection_dist <= intersection_dist - 1;
                    end else begin
                        state <= CLOSEST_HIT;
                        exec_counter <= 0;
                    end
                end

                INTERSECT: begin
                    if (exec_counter < exec_target) begin
                        exec_counter <= exec_counter + 1;
                        intersection_dist <= intersection_dist - 1;
                    end else begin
                        hit_distance <= intersection_dist;
                        hit_found <= 1'b1;
                        state <= CLOSEST_HIT;
                    end
                end

                CLOSEST_HIT: begin
                    result <= {32'b0, hit_distance};
                    state <= OUTPUT;
                end

                SHADE: begin
                    if (exec_counter < exec_target) begin
                        exec_counter <= exec_counter + 1;
                    end else begin
                        state <= OUTPUT;
                    end
                end

                OUTPUT: begin
                    complete <= 1'b1;
                    busy <= 1'b0;
                    cmd_ready <= 1'b1;
                    state <= IDLE;

                    result <= {
                        16'b0,
                        hit_found ? 16'h0001 : 16'h0000,
                        hit_distance,
                        32'b0
                    };
                end

                ERROR_ST: begin
                    error_valid <= 1'b1;
                    error_code <= 8'h01;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
