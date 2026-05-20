module aurora_clock_domain #(
    parameter WIDTH = 1
) (
    input  wire             src_clk,
    input  wire             src_rst_n,
    input  wire [WIDTH-1:0] src_data,
    input  wire             dst_clk,
    input  wire             dst_rst_n,
    output wire [WIDTH-1:0] dst_data
);

    reg [WIDTH-1:0] sync_stage1;
    reg [WIDTH-1:0] sync_stage2;

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

endmodule
