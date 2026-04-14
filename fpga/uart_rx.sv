//============================================================================
// UART Receiver — 115200 baud, 8N1
//
// Synchronises the asynchronous RX line with a 2-FF synchroniser, then
// samples each bit at the centre of its period.  A single-cycle `valid`
// pulse is asserted when a complete byte has been received.
//============================================================================
module uart_rx #(
    parameter int CLKS_PER_BIT = 868   // 100 MHz / 115200 ≈ 868
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       rx,
    output logic [7:0] data,
    output logic       valid
);

    localparam int HALF_BIT = CLKS_PER_BIT / 2;
    localparam int CNT_W    = $clog2(CLKS_PER_BIT);

    typedef enum logic [1:0] { IDLE, START, DATA, STOP } state_t;
    state_t state;

    logic [CNT_W-1:0] clk_cnt;
    logic [2:0]        bit_idx;
    logic [7:0]        shift;
    logic              rx_s1, rx_s2;           // synchroniser

    // ---- 2-FF synchroniser ----
    always_ff @(posedge clk) begin
        rx_s1 <= rx;
        rx_s2 <= rx_s1;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state   <= IDLE;
            valid   <= 1'b0;
            data    <= 8'd0;
            clk_cnt <= '0;
            bit_idx <= 3'd0;
            shift   <= 8'd0;
        end else begin
            valid <= 1'b0;                     // default: no output

            case (state)
                // ------------------------------------------------ IDLE
                IDLE: begin
                    if (!rx_s2) begin          // falling edge → start bit
                        state   <= START;
                        clk_cnt <= '0;
                    end
                end

                // ------------------------------------------------ START
                // Wait half a bit period to reach the centre of the start bit.
                START: begin
                    if (clk_cnt == CNT_W'(HALF_BIT - 1)) begin
                        if (!rx_s2) begin      // still low → genuine start
                            state   <= DATA;
                            clk_cnt <= '0;
                            bit_idx <= 3'd0;
                        end else begin
                            state <= IDLE;     // glitch — abort
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // ------------------------------------------------ DATA
                // Sample each of the 8 data bits (LSB first).
                DATA: begin
                    if (clk_cnt == CNT_W'(CLKS_PER_BIT - 1)) begin
                        shift[bit_idx] <= rx_s2;
                        clk_cnt <= '0;
                        if (bit_idx == 3'd7)
                            state <= STOP;
                        else
                            bit_idx <= bit_idx + 1'b1;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // ------------------------------------------------ STOP
                STOP: begin
                    if (clk_cnt == CNT_W'(CLKS_PER_BIT - 1)) begin
                        if (rx_s2) begin       // valid stop bit
                            data  <= shift;
                            valid <= 1'b1;
                        end
                        state <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
