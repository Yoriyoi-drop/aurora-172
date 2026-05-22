module aurora_clock_domain #(
    parameter WIDTH = 1
) (
    input  wire             src_clk,
    input  wire             src_rst_n,
    input  wire             src_valid,
    input  wire [WIDTH-1:0] src_data,
    input  wire             dst_clk,
    input  wire             dst_rst_n,
    output wire [WIDTH-1:0] dst_data
);

    generate
        if (WIDTH == 1) begin : gen_single_bit
            reg sync_stage1;
            reg sync_stage2;

            always @(posedge dst_clk or negedge dst_rst_n) begin
                if (!dst_rst_n) begin
                    sync_stage1 <= 0;
                    sync_stage2 <= 0;
                end else begin
                    sync_stage1 <= src_data;
                    sync_stage2 <= sync_stage1;
                end
            end

            assign dst_data = sync_stage2;
        end else begin : gen_multi_bit
            reg [WIDTH-1:0] data_latch;
            reg src_toggle;
            reg dst_toggle_sync1, dst_toggle_sync2;
            reg dst_ack;
            reg src_ack_sync1, src_ack_sync2;

            always @(posedge src_clk or negedge src_rst_n) begin
                if (!src_rst_n) begin
                    data_latch <= 0;
                    src_toggle <= 0;
                end else if (src_valid && (src_ack_sync2 == src_toggle)) begin
                    data_latch <= src_data;
                    src_toggle <= ~src_toggle;
                end
            end

            always @(posedge dst_clk or negedge dst_rst_n) begin
                if (!dst_rst_n) begin
                    dst_toggle_sync1 <= 0;
                    dst_toggle_sync2 <= 0;
                    dst_ack <= 0;
                end else begin
                    dst_toggle_sync1 <= src_toggle;
                    dst_toggle_sync2 <= dst_toggle_sync1;
                    if (dst_toggle_sync2 != dst_ack) begin
                        dst_ack <= ~dst_ack;
                    end
                end
            end

            reg [WIDTH-1:0] dst_data_reg;
            always @(posedge dst_clk or negedge dst_rst_n) begin
                if (!dst_rst_n) begin
                    dst_data_reg <= 0;
                end else if (dst_toggle_sync2 != dst_ack) begin
                    dst_data_reg <= data_latch;
                end
            end

            always @(posedge src_clk or negedge src_rst_n) begin
                if (!src_rst_n) begin
                    src_ack_sync1 <= 0;
                    src_ack_sync2 <= 0;
                end else begin
                    src_ack_sync1 <= dst_ack;
                    src_ack_sync2 <= src_ack_sync1;
                end
            end

            assign dst_data = dst_data_reg;
        end
    endgenerate

endmodule
