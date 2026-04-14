//============================================================================
// UART Transmitter — 115200 baud, 8N1
//
// Assert `start` for one clock cycle with the desired byte on `data`.
// The module shifts out a start bit, 8 data bits (LSB first), and a stop
// bit.  `busy` is high for the entire transmission.
//============================================================================
module uart_tx #(
    parameter int CLKS_PER_BIT = 868   // 100 MHz / 115200 ≈ 868
) (
    input  logic       clk,
    input  logic       rst,
    input  logic [7:0] data,
    input  logic       start,
    output logic       tx,
    output logic       busy
);

    localparam int CNT_W = $clog2(CLKS_PER_BIT);

    typedef enum logic [1:0] { IDLE, START_BIT, DATA_BITS, STOP_BIT } state_t;
    state_t state;

    logic [CNT_W-1:0] clk_cnt;
    logic [2:0]        bit_idx;
    logic [7:0]        shift;

    assign busy = (state != IDLE);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state   <= IDLE;
            tx      <= 1'b1;                   // idle line is high
            clk_cnt <= '0;
            bit_idx <= 3'd0;
            shift   <= 8'd0;
        end else begin
            case (state)
                // ------------------------------------------------ IDLE
                IDLE: begin
                    tx <= 1'b1;
                    if (start) begin
                        shift   <= data;
                        state   <= START_BIT;
                        clk_cnt <= '0;
                    end
                end

                // ------------------------------------------------ START
                START_BIT: begin
                    tx <= 1'b0;                // start bit = low
                    if (clk_cnt == CNT_W'(CLKS_PER_BIT - 1)) begin
                        state   <= DATA_BITS;
                        clk_cnt <= '0;
                        bit_idx <= 3'd0;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // ------------------------------------------------ DATA
                DATA_BITS: begin
                    tx <= shift[bit_idx];
                    if (clk_cnt == CNT_W'(CLKS_PER_BIT - 1)) begin
                        clk_cnt <= '0;
                        if (bit_idx == 3'd7)
                            state <= STOP_BIT;
                        else
                            bit_idx <= bit_idx + 1'b1;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // ------------------------------------------------ STOP
                STOP_BIT: begin
                    tx <= 1'b1;                // stop bit = high
                    if (clk_cnt == CNT_W'(CLKS_PER_BIT - 1)) begin
                        state <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
