//============================================================================
// UART Receiver -- 115200 baud, 8N1
//============================================================================
module uart_rx #(
    parameter CLKS_PER_BIT = 868   // 100 MHz / 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);

    localparam HALF_BIT = CLKS_PER_BIT / 2;
    localparam CNT_W    = $clog2(CLKS_PER_BIT);

    localparam ST_IDLE  = 2'd0;
    localparam ST_START = 2'd1;
    localparam ST_DATA  = 2'd2;
    localparam ST_STOP  = 2'd3;

    reg [1:0]        state   = ST_IDLE;
    reg [CNT_W-1:0]  clk_cnt = 0;
    reg [2:0]         bit_idx = 0;
    reg [7:0]         shift   = 0;
    reg               rx_s1 = 1, rx_s2 = 1;

    // 2-FF synchroniser
    always @(posedge clk) begin
        rx_s1 <= rx;
        rx_s2 <= rx_s1;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state   <= ST_IDLE;
            valid   <= 1'b0;
            data    <= 8'd0;
            clk_cnt <= 0;
            bit_idx <= 3'd0;
            shift   <= 8'd0;
        end else begin
            valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (!rx_s2) begin
                        state   <= ST_START;
                        clk_cnt <= 0;
                    end
                end

                ST_START: begin
                    if (clk_cnt == HALF_BIT - 1) begin
                        if (!rx_s2) begin
                            state   <= ST_DATA;
                            clk_cnt <= 0;
                            bit_idx <= 3'd0;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                ST_DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        shift[bit_idx] <= rx_s2;
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
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        if (rx_s2) begin
                            data  <= shift;
                            valid <= 1'b1;
                        end
                        state <= ST_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end
endmodule
