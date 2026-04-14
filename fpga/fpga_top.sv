//============================================================================
// FPGA Top-Level Wrapper for Basys 3
//
// Instantiates request_manager_top and age_arbiter internally (solving the
// 324-port problem) and exposes only physical board I/O:
//   - 100 MHz board clock
//   - Centre button for reset
//   - USB-UART for laptop communication (115200 baud, 8N1)
//   - 16 LEDs for status at a glance
//
// CLOCK GATING
// ------------
// The design modules run on a gated clock produced by BUFGCE.  The clock
// only advances when the host sends a TICK command, allowing the user to
// single-step through the pipeline and observe every intermediate state.
//
// UART PROTOCOL
// -------------
//   Command           Bytes (PC→FPGA)         Response (FPGA→PC)
//   -------           ---------------         ------------------
//   0x01  Reset       1                       0xA1
//   0x02  Tick        1                       0xA2 NUM GV GVAL EVAL FLAGS
//   0x03  Submit      3  (0x03 SD DD)         0xA3 READY
//   0x04  Query       1                       0xA4 NUM GV GVAL EVAL FLAGS
//   0x05  Dump table  1                       0xA5 [VSD D]×8  (16 bytes)
//   0x06  Clear stage 1                       0xA6
//
//   SD   = {4'b0, src[1:0], dst[1:0]}
//   DD   = data[7:0]  (bit 8 is set to 0)
//   NUM  = num_active_reqs
//   GV   = grant_vector
//   GVAL = granted_valid
//   EVAL = expired_valid
//   FLAGS= {6'b0, table_full, age_overflow}
//   VSD  = {valid, src[1:0], dst[1:0], age[2:0]}
//   D    = data[7:0]
//============================================================================

module fpga_top (
    input  logic        clk_100mhz,        // W5   — 100 MHz oscillator
    input  logic        btnC,              // U18  — centre push-button (reset)
    input  logic        uart_rxd,          // B18  — USB-UART RX (PC → FPGA)
    output logic        uart_txd,          // A18  — USB-UART TX (FPGA → PC)
    output logic [15:0] led                // LEDs for quick status
);

    // ================================================================
    // Parameters — must match the uploaded design files
    // ================================================================
    localparam int TABLE_SIZE = 8;
    localparam int SRC_WIDTH  = 2;
    localparam int DST_WIDTH  = 2;
    localparam int DATA_WIDTH = 9;
    localparam int AGE_WIDTH  = 3;
    localparam int MAX_AGE    = 7;
    localparam int NUM_SRCS   = 1 << SRC_WIDTH;
    localparam int CLKS_PER_BIT = 868;     // 100 MHz / 115200

    // ================================================================
    // System reset — debounce btnC
    // ================================================================
    logic [19:0] debounce_cnt;
    logic        sys_rst;
    logic        btn_sync1, btn_sync2;

    always_ff @(posedge clk_100mhz) begin
        btn_sync1 <= btnC;
        btn_sync2 <= btn_sync1;
    end

    always_ff @(posedge clk_100mhz) begin
        if (btn_sync2) begin
            if (debounce_cnt < 20'hF_FFFF)
                debounce_cnt <= debounce_cnt + 1;
        end else begin
            debounce_cnt <= '0;
        end
    end
    assign sys_rst = (debounce_cnt >= 20'hF_0000);

    // ================================================================
    // UART instantiation
    // ================================================================
    logic [7:0] rx_data;
    logic       rx_valid;
    logic [7:0] tx_data;
    logic       tx_start;
    logic       tx_busy;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk   (clk_100mhz),
        .rst   (sys_rst),
        .rx    (uart_rxd),
        .data  (rx_data),
        .valid (rx_valid)
    );

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk   (clk_100mhz),
        .rst   (sys_rst),
        .data  (tx_data),
        .start (tx_start),
        .tx    (uart_txd),
        .busy  (tx_busy)
    );

    // ================================================================
    // Gated clock for design modules (BUFGCE)
    //
    // CE is asserted for one system clock cycle per TICK command.
    // With CE_TYPE="SYNC", this produces exactly one clean posedge
    // on design_clk, one system cycle after the CE pulse.
    // ================================================================
    logic do_step;              // single-cycle pulse from command FSM
    logic design_clk;

    BUFGCE #(
        .CE_TYPE ("SYNC"),
        .SIM_DEVICE ("7SERIES")
    ) u_bufgce (
        .I  (clk_100mhz),
        .CE (do_step),
        .O  (design_clk)
    );

    // ================================================================
    // Design reset (active-high, directly drives async reset)
    // ================================================================
    logic design_rst;
    logic [3:0] rst_hold_cnt;
    logic       rst_cmd;        // pulse from command FSM

    always_ff @(posedge clk_100mhz) begin
        if (sys_rst) begin
            design_rst   <= 1'b1;
            rst_hold_cnt <= 4'd15;
        end else if (rst_cmd) begin
            design_rst   <= 1'b1;
            rst_hold_cnt <= 4'd15;
        end else if (rst_hold_cnt > 0) begin
            rst_hold_cnt <= rst_hold_cnt - 1;
        end else begin
            design_rst <= 1'b0;
        end
    end

    // ================================================================
    // Design inter-module wiring (ALL internal — no top-level ports!)
    // ================================================================
    logic [NUM_SRCS-1:0]               new_req_valid;
    logic [DST_WIDTH-1:0]              new_req_dest   [NUM_SRCS-1:0];
    logic [DATA_WIDTH-1:0]             new_req_data   [NUM_SRCS-1:0];
    logic [NUM_SRCS-1:0]               new_req_ready;

    logic [TABLE_SIZE-1:0]             req_table_valid;
    logic [SRC_WIDTH-1:0]              req_table_source [TABLE_SIZE-1:0];
    logic [DST_WIDTH-1:0]              req_table_dest   [TABLE_SIZE-1:0];
    logic [DATA_WIDTH-1:0]             req_table_data   [TABLE_SIZE-1:0];
    logic [AGE_WIDTH-1:0]              req_table_age    [TABLE_SIZE-1:0];

    logic [TABLE_SIZE-1:0]             grant_vector;

    logic [TABLE_SIZE-1:0]             granted_valid;
    logic [SRC_WIDTH-1:0]              granted_source   [TABLE_SIZE-1:0];
    logic [DST_WIDTH-1:0]              granted_dest     [TABLE_SIZE-1:0];
    logic [DATA_WIDTH-1:0]             granted_data     [TABLE_SIZE-1:0];

    logic [TABLE_SIZE-1:0]             expired_valid;

    logic [$clog2(TABLE_SIZE+1)-1:0]   num_active_reqs;
    logic                              table_full;
    logic                              age_overflow;

    // ================================================================
    // Staged request registers (set by SUBMIT, applied on next TICK)
    // ================================================================
    logic [NUM_SRCS-1:0]               staged_valid;
    logic [DST_WIDTH-1:0]              staged_dest   [NUM_SRCS-1:0];
    logic [DATA_WIDTH-1:0]             staged_data   [NUM_SRCS-1:0];

    assign new_req_valid = staged_valid;
    assign new_req_dest  = staged_dest;
    assign new_req_data  = staged_data;

    // ================================================================
    // Design instantiation
    // ================================================================
    request_manager_top #(
        .TABLE_SIZE (TABLE_SIZE),
        .REQ_WIDTH  (16),
        .SRC_WIDTH  (SRC_WIDTH),
        .DST_WIDTH  (DST_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .AGE_WIDTH  (AGE_WIDTH),
        .MAX_AGE    (MAX_AGE)
    ) u_manager (
        .clock           (design_clk),
        .reset           (design_rst),
        .new_req_valid   (new_req_valid),
        .new_req_dest    (new_req_dest),
        .new_req_data    (new_req_data),
        .new_req_ready   (new_req_ready),
        .req_table_valid (req_table_valid),
        .req_table_source(req_table_source),
        .req_table_dest  (req_table_dest),
        .req_table_data  (req_table_data),
        .req_table_age   (req_table_age),
        .grant_vector    (grant_vector),
        .granted_valid   (granted_valid),
        .granted_source  (granted_source),
        .granted_dest    (granted_dest),
        .granted_data    (granted_data),
        .expired_valid   (expired_valid),
        .num_active_reqs (num_active_reqs),
        .table_full      (table_full),
        .age_overflow    (age_overflow)
    );

    age_arbiter #(
        .TABLE_SIZE (TABLE_SIZE),
        .DST_WIDTH  (DST_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .AGE_WIDTH  (AGE_WIDTH),
        .MAX_AGE    (MAX_AGE)
    ) u_arbiter (
        .req_valid    (req_table_valid),
        .req_dest     (req_table_dest),
        .req_data     (req_table_data),
        .req_age      (req_table_age),
        .grant_vector (grant_vector)
    );

    // ================================================================
    // LED status display
    // ================================================================
    //   LED[3:0]  = num_active_reqs
    //   LED[4]    = table_full
    //   LED[5]    = age_overflow
    //   LED[7:6]  = 0
    //   LED[15:8] = granted_valid
    assign led[3:0]  = num_active_reqs;
    assign led[4]    = table_full;
    assign led[5]    = age_overflow;
    assign led[7:6]  = 2'b0;
    assign led[15:8] = granted_valid;

    // ================================================================
    // Command Processor FSM
    // ================================================================
    typedef enum logic [3:0] {
        S_IDLE,
        S_RESET_HOLD,
        S_STEP_PULSE,
        S_STEP_WAIT,
        S_SUB_BYTE1,
        S_SUB_BYTE2,
        S_FILL_RESP,
        S_TX_SEND,
        S_TX_WAIT
    } cmd_state_t;

    cmd_state_t cmd_state;

    // Response buffer
    logic [7:0] resp_buf [0:24];    // max 25 bytes (dump = 1+16)
    logic [4:0] resp_len;           // number of bytes to send
    logic [4:0] resp_idx;           // current byte index

    // Temporary registers for multi-byte commands
    logic [1:0] sub_src;
    logic [1:0] sub_dst;

    // Wait counter for step settling
    logic [3:0] wait_cnt;

    // Response type tracking
    logic [7:0] pending_cmd;

    always_ff @(posedge clk_100mhz or posedge sys_rst) begin
        if (sys_rst) begin
            cmd_state    <= S_IDLE;
            do_step      <= 1'b0;
            rst_cmd      <= 1'b0;
            tx_start     <= 1'b0;
            tx_data      <= 8'd0;
            resp_len     <= 5'd0;
            resp_idx     <= 5'd0;
            wait_cnt     <= 4'd0;
            pending_cmd  <= 8'd0;
            staged_valid <= '0;
            for (int s = 0; s < NUM_SRCS; s++) begin
                staged_dest[s] <= '0;
                staged_data[s] <= '0;
            end
        end else begin
            // Default: deassert single-cycle pulses
            do_step  <= 1'b0;
            rst_cmd  <= 1'b0;
            tx_start <= 1'b0;

            case (cmd_state)

                // ============================================ IDLE
                S_IDLE: begin
                    if (rx_valid) begin
                        pending_cmd <= rx_data;
                        case (rx_data)
                            8'h01: begin                    // RESET
                                rst_cmd   <= 1'b1;
                                // Clear staged requests on reset
                                staged_valid <= '0;
                                cmd_state <= S_RESET_HOLD;
                                wait_cnt  <= 4'd15;
                            end
                            8'h02: begin                    // TICK
                                do_step   <= 1'b1;
                                cmd_state <= S_STEP_PULSE;
                                wait_cnt  <= 4'd8;
                            end
                            8'h03: begin                    // SUBMIT (need 2 more bytes)
                                cmd_state <= S_SUB_BYTE1;
                            end
                            8'h04: begin                    // QUERY
                                cmd_state <= S_FILL_RESP;
                            end
                            8'h05: begin                    // DUMP TABLE
                                cmd_state <= S_FILL_RESP;
                            end
                            8'h06: begin                    // CLEAR STAGED
                                staged_valid <= '0;
                                cmd_state    <= S_FILL_RESP;
                            end
                            default: begin
                                cmd_state <= S_IDLE;        // unknown — ignore
                            end
                        endcase
                    end
                end

                // ============================================ RESET
                // Wait for the reset hold counter to finish.
                S_RESET_HOLD: begin
                    if (wait_cnt > 0) begin
                        wait_cnt <= wait_cnt - 1;
                    end else begin
                        cmd_state <= S_FILL_RESP;
                    end
                end

                // ============================================ TICK
                // do_step was pulsed; now wait for the gated clock edge
                // to propagate and outputs to settle.
                S_STEP_PULSE: begin
                    if (wait_cnt > 0) begin
                        wait_cnt <= wait_cnt - 1;
                    end else begin
                        // Clear staged requests after they've been consumed
                        staged_valid <= '0;
                        cmd_state    <= S_FILL_RESP;
                    end
                end

                // ============================================ STEP_WAIT (unused, reserved)
                S_STEP_WAIT: begin
                    cmd_state <= S_FILL_RESP;
                end

                // ============================================ SUBMIT — byte 1
                S_SUB_BYTE1: begin
                    if (rx_valid) begin
                        sub_src   <= rx_data[3:2];
                        sub_dst   <= rx_data[1:0];
                        cmd_state <= S_SUB_BYTE2;
                    end
                end

                // ============================================ SUBMIT — byte 2
                S_SUB_BYTE2: begin
                    if (rx_valid) begin
                        staged_valid[sub_src]        <= 1'b1;
                        staged_dest[sub_src]         <= sub_dst;
                        staged_data[sub_src]         <= {1'b0, rx_data};  // 9 bits, MSB=0
                        cmd_state                    <= S_FILL_RESP;
                    end
                end

                // ============================================ FILL RESPONSE
                // Build the response buffer based on the command type.
                S_FILL_RESP: begin
                    resp_idx <= 5'd0;
                    case (pending_cmd)
                        8'h01: begin   // RESET response
                            resp_buf[0] <= 8'hA1;
                            resp_len    <= 5'd1;
                        end
                        8'h02: begin   // TICK response
                            resp_buf[0] <= 8'hA2;
                            resp_buf[1] <= {4'd0, num_active_reqs};
                            resp_buf[2] <= grant_vector;
                            resp_buf[3] <= granted_valid;
                            resp_buf[4] <= expired_valid;
                            resp_buf[5] <= {6'd0, table_full, age_overflow};
                            resp_len    <= 5'd6;
                        end
                        8'h03: begin   // SUBMIT response
                            resp_buf[0] <= 8'hA3;
                            resp_buf[1] <= {4'd0, new_req_ready};
                            resp_len    <= 5'd2;
                        end
                        8'h04: begin   // QUERY response
                            resp_buf[0] <= 8'hA4;
                            resp_buf[1] <= {4'd0, num_active_reqs};
                            resp_buf[2] <= grant_vector;
                            resp_buf[3] <= granted_valid;
                            resp_buf[4] <= expired_valid;
                            resp_buf[5] <= {6'd0, table_full, age_overflow};
                            resp_len    <= 5'd6;
                        end
                        8'h05: begin   // DUMP TABLE response
                            resp_buf[0] <= 8'hA5;
                            for (int i = 0; i < TABLE_SIZE; i++) begin
                                resp_buf[1 + i*2] <= {req_table_valid[i],
                                                      req_table_source[i],
                                                      req_table_dest[i],
                                                      req_table_age[i]};
                                resp_buf[2 + i*2] <= req_table_data[i][7:0];
                            end
                            resp_len <= 5'd17;
                        end
                        8'h06: begin   // CLEAR response
                            resp_buf[0] <= 8'hA6;
                            resp_len    <= 5'd1;
                        end
                        default: begin
                            resp_buf[0] <= 8'hFF;          // error
                            resp_len    <= 5'd1;
                        end
                    endcase
                    cmd_state <= S_TX_SEND;
                end

                // ============================================ TX SEND
                // Send the next byte from the response buffer.
                S_TX_SEND: begin
                    if (!tx_busy) begin
                        if (resp_idx < resp_len) begin
                            tx_data  <= resp_buf[resp_idx];
                            tx_start <= 1'b1;
                            resp_idx <= resp_idx + 1;
                            cmd_state <= S_TX_WAIT;
                        end else begin
                            cmd_state <= S_IDLE;           // all bytes sent
                        end
                    end
                end

                // ============================================ TX WAIT
                // Wait for the UART TX to pick up the byte (busy goes high),
                // then wait for it to finish (busy goes low).
                S_TX_WAIT: begin
                    if (tx_busy) begin
                        cmd_state <= S_TX_SEND;            // byte accepted, go queue next
                    end
                    // If not yet busy, stay here (one-cycle latency for busy)
                end

            endcase
        end
    end

endmodule
