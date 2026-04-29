//============================================================================
// UART Transmitter -- 115200 baud, 8N1
//============================================================================
module uart_tx #(
    parameter CLKS_PER_BIT = 868   // 100 MHz / 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       start,
    output reg        tx,
    output wire       busy
);

    localparam CNT_W = $clog2(CLKS_PER_BIT);

    localparam ST_IDLE  = 2'd0;
    localparam ST_START = 2'd1;
    localparam ST_DATA  = 2'd2;
    localparam ST_STOP  = 2'd3;

    reg [1:0]        state   = ST_IDLE;
    reg [CNT_W-1:0]  clk_cnt = 0;
    reg [2:0]         bit_idx = 0;
    reg [7:0]         shift   = 0;

    assign busy = (state != ST_IDLE);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state   <= ST_IDLE;
            tx      <= 1'b1;
            clk_cnt <= 0;
            bit_idx <= 3'd0;
            shift   <= 8'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    tx <= 1'b1;
                    if (start) begin
                        shift   <= data;
                        state   <= ST_START;
                        clk_cnt <= 0;
                    end
                end

                ST_START: begin
                    tx <= 1'b0;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        state   <= ST_DATA;
                        clk_cnt <= 0;
                        bit_idx <= 3'd0;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                ST_DATA: begin
                    tx <= shift[bit_idx];
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        if (bit_idx == 3'd7)
                            state <= ST_STOP;
                        else
                            bit_idx <= bit_idx + 1;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                ST_STOP: begin
                    tx <= 1'b1;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        state <= ST_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end
endmodule
