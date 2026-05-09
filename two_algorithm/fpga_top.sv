//============================================================================
// FPGA Top-Level Wrapper for Basys 3
//
// Dual-arbiter version: both age_arbiter and round_robin_arbiter are
// instantiated.  A button toggles between them, and the seven-segment
// display shows "00" (age) or "01" (round-robin).
//
// UART PROTOCOL
// -------------
//   0x01           Reset           -> 0xA1
//   0x02           Tick            -> 0xA2 NUM GV GVAL EVAL FLAGS ALG
//   0x03 SD DD     Submit request  -> 0xA3 READY
//   0x04           Query status    -> 0xA4 NUM GV GVAL EVAL FLAGS ALG
//   0x05           Dump table      -> 0xA5 [VSD D]x8  (16 bytes)
//   0x06           Clear staged    -> 0xA6
//   0x07           Query algorithm -> 0xA7 ALG
//   0x08 AA        Set algorithm   -> 0xA8 ALG  (AA: 0=age, 1=rr)
//============================================================================

module fpga_top (
    input  wire         clk_100mhz,        // W5  -- 100 MHz oscillator
    input  wire         btnC,              // U18 -- centre push-button (reset)
    input  wire         btnU,              // T18 -- upper push-button (toggle algorithm)
    input  wire         uart_rxd,          // B18 -- USB-UART RX (PC -> FPGA)
    output wire         uart_txd,          // A18 -- USB-UART TX (FPGA -> PC)
    output wire [15:0]  led,               // status LEDs
    output reg  [6:0]   seg,               // seven-segment cathodes (active low)
    output reg  [3:0]   an                 // seven-segment anodes (active low)
);

    // ================================================================
    // Parameters
    // ================================================================
    localparam TABLE_SIZE   = 8;
    localparam SRC_WIDTH    = 2;
    localparam DST_WIDTH    = 2;
    localparam DATA_WIDTH   = 9;
    localparam AGE_WIDTH    = 3;
    localparam MAX_AGE      = 7;
    localparam NUM_SRCS     = 1 << SRC_WIDTH;
    localparam CLKS_PER_BIT = 868;   // 100 MHz / 115200

    // ================================================================
    // System reset -- debounce btnC
    // ================================================================
    reg [19:0] debounce_cnt = 0;
    reg        btn_sync1 = 0, btn_sync2 = 0;
    wire       sys_rst;

    always @(posedge clk_100mhz) begin
        btn_sync1 <= btnC;
        btn_sync2 <= btn_sync1;
    end

    always @(posedge clk_100mhz) begin
        if (btn_sync2)
            debounce_cnt <= (debounce_cnt < 20'hF_FFFF) ? debounce_cnt + 1 : debounce_cnt;
        else
            debounce_cnt <= 0;
    end
    assign sys_rst = (debounce_cnt >= 20'hF_0000);

    // ================================================================
    // Algorithm toggle -- debounce btnU, toggle on rising edge
    // ================================================================
    reg [19:0] alg_debounce = 0;
    reg        alg_sync1 = 0, alg_sync2 = 0;
    wire       alg_btn_stable;
    reg        alg_btn_prev = 0;
    reg        alg_sel = 0;           // 0 = age, 1 = round-robin

    // Handoff signals: FSM requests an algorithm change via pulse
    reg        uart_alg_set = 0;     // single-cycle pulse from FSM
    reg        uart_alg_val = 0;     // desired value

    always @(posedge clk_100mhz) begin
        alg_sync1 <= btnU;
        alg_sync2 <= alg_sync1;
    end

    always @(posedge clk_100mhz) begin
        if (alg_sync2)
            alg_debounce <= (alg_debounce < 20'hF_FFFF) ? alg_debounce + 1 : alg_debounce;
        else
            alg_debounce <= 0;
    end
    assign alg_btn_stable = (alg_debounce >= 20'hF_0000);

    always @(posedge clk_100mhz) begin
        if (sys_rst) begin
            alg_sel      <= 1'b0;
            alg_btn_prev <= 1'b0;
        end else begin
            alg_btn_prev <= alg_btn_stable;
            // UART set takes priority over button toggle
            if (uart_alg_set)
                alg_sel <= uart_alg_val;
            else if (alg_btn_stable && !alg_btn_prev)
                alg_sel <= ~alg_sel;
        end
    end

    // ================================================================
    // Seven-segment display
    //
    // Shows "00" (age) or "01" (round-robin) on the rightmost two digits.
    // Leftmost two digits are blanked.
    //
    // The display is multiplexed: we cycle through the 4 anodes at
    // ~763 Hz (100 MHz / 2^17).
    // ================================================================
    reg [16:0] seg_refresh_cnt = 0;
    wire [1:0] seg_digit;

    always @(posedge clk_100mhz)
        seg_refresh_cnt <= seg_refresh_cnt + 1;

    assign seg_digit = seg_refresh_cnt[16:15];

    // Seven-segment patterns (active low): bit order = gfedcba
    //   0 -> 7'b1000000  (segments a,b,c,d,e,f on)
    //   1 -> 7'b1111001  (segments b,c on)
    //   blank -> 7'b1111111  (all off)
    localparam [6:0] SS_0     = 7'b1000000;
    localparam [6:0] SS_1     = 7'b1111001;
    localparam [6:0] SS_BLANK = 7'b1111111;

    always @(*) begin
        case (seg_digit)
            2'd0: begin  // rightmost digit: algorithm number (0 or 1)
                an  = 4'b1110;
                seg = alg_sel ? SS_1 : SS_0;
            end
            2'd1: begin  // second digit: always 0
                an  = 4'b1101;
                seg = SS_0;
            end
            2'd2: begin  // third digit: blank
                an  = 4'b1011;
                seg = SS_BLANK;
            end
            2'd3: begin  // fourth digit (leftmost): blank
                an  = 4'b0111;
                seg = SS_BLANK;
            end
        endcase
    end

    // ================================================================
    // UART
    // ================================================================
    wire [7:0] rx_data;
    wire       rx_valid;
    reg  [7:0] tx_data  = 0;
    reg        tx_start = 0;
    wire       tx_busy;

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
    // Gated design clock (BUFGCE)
    // ================================================================
    reg  do_step = 0;
    wire design_clk;

    BUFGCE u_bufgce (
        .I  (clk_100mhz),
        .CE (do_step),
        .O  (design_clk)
    );

    // ================================================================
    // Design reset
    // ================================================================
    reg        design_rst  = 1;
    reg  [3:0] rst_hold    = 4'd15;
    reg        rst_cmd     = 0;

    always @(posedge clk_100mhz) begin
        if (sys_rst) begin
            design_rst <= 1'b1;
            rst_hold   <= 4'd15;
        end else if (rst_cmd) begin
            design_rst <= 1'b1;
            rst_hold   <= 4'd15;
        end else if (rst_hold > 0) begin
            rst_hold <= rst_hold - 1;
        end else begin
            design_rst <= 1'b0;
        end
    end

    // ================================================================
    // Design inter-module wiring (ALL internal)
    // ================================================================

    // -- Staged request registers --
    reg  [NUM_SRCS-1:0]                     staged_valid = 0;
    reg  [NUM_SRCS*DST_WIDTH-1:0]           staged_dest_flat  = 0;
    reg  [NUM_SRCS*DATA_WIDTH-1:0]          staged_data_flat  = 0;

    // -- Manager <-> arbiter flat buses --
    wire [TABLE_SIZE-1:0]                   req_table_valid;
    wire [TABLE_SIZE*SRC_WIDTH-1:0]         req_table_source_flat;
    wire [TABLE_SIZE*DST_WIDTH-1:0]         req_table_dest_flat;
    wire [TABLE_SIZE*DATA_WIDTH-1:0]        req_table_data_flat;
    wire [TABLE_SIZE*AGE_WIDTH-1:0]         req_table_age_flat;

    // -- Grant vector: muxed from selected arbiter --
    wire [TABLE_SIZE-1:0]                   grant_vector;
    wire [TABLE_SIZE-1:0]                   age_grant_vector;
    wire [TABLE_SIZE-1:0]                   rr_grant_vector;

    assign grant_vector = alg_sel ? rr_grant_vector : age_grant_vector;

    wire [NUM_SRCS-1:0]                     new_req_ready;

    wire [TABLE_SIZE-1:0]                   granted_valid;
    wire [TABLE_SIZE*SRC_WIDTH-1:0]         granted_source_flat;
    wire [TABLE_SIZE*DST_WIDTH-1:0]         granted_dest_flat;
    wire [TABLE_SIZE*DATA_WIDTH-1:0]        granted_data_flat;

    wire [TABLE_SIZE-1:0]                   expired_valid;

    wire [$clog2(TABLE_SIZE+1)-1:0]         num_active_reqs;
    wire                                    table_full;
    wire                                    age_overflow;

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
        .clock                (design_clk),
        .reset                (design_rst),
        .new_req_valid        (staged_valid),
        .new_req_dest_flat    (staged_dest_flat),
        .new_req_data_flat    (staged_data_flat),
        .new_req_ready        (new_req_ready),
        .req_table_valid      (req_table_valid),
        .req_table_source_flat(req_table_source_flat),
        .req_table_dest_flat  (req_table_dest_flat),
        .req_table_data_flat  (req_table_data_flat),
        .req_table_age_flat   (req_table_age_flat),
        .grant_vector         (grant_vector),
        .granted_valid        (granted_valid),
        .granted_source_flat  (granted_source_flat),
        .granted_dest_flat    (granted_dest_flat),
        .granted_data_flat    (granted_data_flat),
        .expired_valid        (expired_valid),
        .num_active_reqs      (num_active_reqs),
        .table_full           (table_full),
        .age_overflow         (age_overflow)
    );

    // ================================================================
    // Dual arbiters -- both read the same table, only one drives grants
    // ================================================================
    age_arbiter #(
        .TABLE_SIZE (TABLE_SIZE),
        .DST_WIDTH  (DST_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .AGE_WIDTH  (AGE_WIDTH),
        .MAX_AGE    (MAX_AGE)
    ) u_age_arb (
        .req_valid     (req_table_valid),
        .req_dest_flat (req_table_dest_flat),
        .req_data_flat (req_table_data_flat),
        .req_age_flat  (req_table_age_flat),
        .grant_vector  (age_grant_vector)
    );

    round_robin_arbiter #(
        .TABLE_SIZE (TABLE_SIZE),
        .DST_WIDTH  (DST_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .AGE_WIDTH  (AGE_WIDTH),
        .MAX_AGE    (MAX_AGE)
    ) u_rr_arb (
        .clock         (design_clk),
        .reset         (design_rst),
        .req_valid     (req_table_valid),
        .req_dest_flat (req_table_dest_flat),
        .req_data_flat (req_table_data_flat),
        .req_age_flat  (req_table_age_flat),
        .grant_vector  (rr_grant_vector)
    );

    // ================================================================
    // LED status display
    //   [3:0]  num_active_reqs
    //   [4]    table_full
    //   [5]    age_overflow
    //   [6]    alg_sel (0=age, 1=rr)
    //   [7]    0
    //   [15:8] granted_valid
    // ================================================================
    assign led[3:0]  = num_active_reqs;
    assign led[4]    = table_full;
    assign led[5]    = age_overflow;
    assign led[6]    = alg_sel;
    assign led[7]    = 1'b0;
    assign led[15:8] = granted_valid;

    // ================================================================
    // Helper: unpack table fields for DUMP response
    // ================================================================
    wire                  tbl_valid [0:TABLE_SIZE-1];
    wire [SRC_WIDTH-1:0]  tbl_src   [0:TABLE_SIZE-1];
    wire [DST_WIDTH-1:0]  tbl_dst   [0:TABLE_SIZE-1];
    wire [DATA_WIDTH-1:0] tbl_data  [0:TABLE_SIZE-1];
    wire [AGE_WIDTH-1:0]  tbl_age   [0:TABLE_SIZE-1];

    genvar gk;
    generate
        for (gk = 0; gk < TABLE_SIZE; gk = gk + 1) begin : unpack_table
            assign tbl_valid[gk] = req_table_valid[gk];
            assign tbl_src[gk]   = req_table_source_flat[gk*SRC_WIDTH  +: SRC_WIDTH];
            assign tbl_dst[gk]   = req_table_dest_flat  [gk*DST_WIDTH  +: DST_WIDTH];
            assign tbl_data[gk]  = req_table_data_flat  [gk*DATA_WIDTH +: DATA_WIDTH];
            assign tbl_age[gk]   = req_table_age_flat   [gk*AGE_WIDTH  +: AGE_WIDTH];
        end
    endgenerate

    // ================================================================
    // Command Processor FSM
    // ================================================================
    localparam S_IDLE       = 4'd0;
    localparam S_RESET_HOLD = 4'd1;
    localparam S_STEP_PULSE = 4'd2;
    localparam S_SUB_BYTE1  = 4'd3;
    localparam S_SUB_BYTE2  = 4'd4;
    localparam S_FILL_RESP  = 4'd5;
    localparam S_TX_SEND    = 4'd6;
    localparam S_TX_WAIT    = 4'd7;
    localparam S_ALG_BYTE   = 4'd8;

    reg [3:0]  cmd_state   = S_IDLE;
    reg [7:0]  resp_buf [0:24];
    reg [4:0]  resp_len    = 0;
    reg [4:0]  resp_idx    = 0;
    reg [1:0]  sub_src     = 0;
    reg [1:0]  sub_dst     = 0;
    reg [3:0]  wait_cnt    = 0;
    reg [7:0]  pending_cmd = 0;

    integer ri;

    always @(posedge clk_100mhz) begin
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
            staged_valid     <= {NUM_SRCS{1'b0}};
            staged_dest_flat <= {(NUM_SRCS*DST_WIDTH){1'b0}};
            staged_data_flat <= {(NUM_SRCS*DATA_WIDTH){1'b0}};
            uart_alg_set     <= 1'b0;
            uart_alg_val     <= 1'b0;
        end else begin
            do_step  <= 1'b0;
            rst_cmd  <= 1'b0;
            tx_start <= 1'b0;
            uart_alg_set <= 1'b0;

            case (cmd_state)

                // =========================================== IDLE
                S_IDLE: begin
                    if (rx_valid) begin
                        pending_cmd <= rx_data;
                        case (rx_data)
                            8'h01: begin   // RESET
                                rst_cmd      <= 1'b1;
                                staged_valid <= {NUM_SRCS{1'b0}};
                                cmd_state    <= S_RESET_HOLD;
                                wait_cnt     <= 4'd15;
                            end
                            8'h02: begin   // TICK
                                do_step   <= 1'b1;
                                cmd_state <= S_STEP_PULSE;
                                wait_cnt  <= 4'd8;
                            end
                            8'h03: begin   // SUBMIT
                                cmd_state <= S_SUB_BYTE1;
                            end
                            8'h04: begin   // QUERY
                                cmd_state <= S_FILL_RESP;
                            end
                            8'h05: begin   // DUMP TABLE
                                cmd_state <= S_FILL_RESP;
                            end
                            8'h06: begin   // CLEAR STAGED
                                staged_valid <= {NUM_SRCS{1'b0}};
                                cmd_state    <= S_FILL_RESP;
                            end
                            8'h07: begin   // QUERY ALGORITHM
                                cmd_state <= S_FILL_RESP;
                            end
                            8'h08: begin   // SET ALGORITHM (1 more byte)
                                cmd_state <= S_ALG_BYTE;
                            end
                            default: begin
                                cmd_state <= S_IDLE;
                            end
                        endcase
                    end
                end

                // =========================================== RESET HOLD
                S_RESET_HOLD: begin
                    if (wait_cnt > 0)
                        wait_cnt <= wait_cnt - 1;
                    else
                        cmd_state <= S_FILL_RESP;
                end

                // =========================================== STEP PULSE
                S_STEP_PULSE: begin
                    if (wait_cnt > 0) begin
                        wait_cnt <= wait_cnt - 1;
                    end else begin
                        staged_valid <= {NUM_SRCS{1'b0}};
                        cmd_state    <= S_FILL_RESP;
                    end
                end

                // =========================================== SUBMIT byte 1
                S_SUB_BYTE1: begin
                    if (rx_valid) begin
                        sub_src   <= rx_data[3:2];
                        sub_dst   <= rx_data[1:0];
                        cmd_state <= S_SUB_BYTE2;
                    end
                end

                // =========================================== SUBMIT byte 2
                S_SUB_BYTE2: begin
                    if (rx_valid) begin
                        staged_valid[sub_src] <= 1'b1;
                        staged_dest_flat[sub_src*DST_WIDTH  +: DST_WIDTH]  <= sub_dst;
                        staged_data_flat[sub_src*DATA_WIDTH +: DATA_WIDTH] <= {1'b0, rx_data};
                        cmd_state <= S_FILL_RESP;
                    end
                end

                // =========================================== SET ALGORITHM byte
                S_ALG_BYTE: begin
                    if (rx_valid) begin
                        uart_alg_set <= 1'b1;
                        uart_alg_val <= rx_data[0];
                        cmd_state    <= S_FILL_RESP;
                    end
                end

                // =========================================== FILL RESPONSE
                S_FILL_RESP: begin
                    resp_idx <= 5'd0;
                    case (pending_cmd)
                        8'h01: begin   // RESET ack
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
                            resp_buf[6] <= {7'd0, alg_sel};
                            resp_len    <= 5'd7;
                        end
                        8'h03: begin   // SUBMIT ack
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
                            resp_buf[6] <= {7'd0, alg_sel};
                            resp_len    <= 5'd7;
                        end
                        8'h05: begin   // DUMP response
                            resp_buf[0] <= 8'hA5;
                            for (ri = 0; ri < TABLE_SIZE; ri = ri + 1) begin
                                resp_buf[1 + ri*2] <= {tbl_valid[ri],
                                                       tbl_src[ri],
                                                       tbl_dst[ri],
                                                       tbl_age[ri]};
                                resp_buf[2 + ri*2] <= tbl_data[ri][7:0];
                            end
                            resp_len <= 5'd17;
                        end
                        8'h06: begin   // CLEAR ack
                            resp_buf[0] <= 8'hA6;
                            resp_len    <= 5'd1;
                        end
                        8'h07: begin   // QUERY ALGORITHM
                            resp_buf[0] <= 8'hA7;
                            resp_buf[1] <= {7'd0, alg_sel};
                            resp_len    <= 5'd2;
                        end
                        8'h08: begin   // SET ALGORITHM ack
                            resp_buf[0] <= 8'hA8;
                            resp_buf[1] <= {7'd0, alg_sel};
                            resp_len    <= 5'd2;
                        end
                        default: begin
                            resp_buf[0] <= 8'hFF;
                            resp_len    <= 5'd1;
                        end
                    endcase
                    cmd_state <= S_TX_SEND;
                end

                // =========================================== TX SEND
                S_TX_SEND: begin
                    if (!tx_busy) begin
                        if (resp_idx < resp_len) begin
                            tx_data  <= resp_buf[resp_idx];
                            tx_start <= 1'b1;
                            resp_idx <= resp_idx + 1;
                            cmd_state <= S_TX_WAIT;
                        end else begin
                            cmd_state <= S_IDLE;
                        end
                    end
                end

                // =========================================== TX WAIT
                S_TX_WAIT: begin
                    if (tx_busy)
                        cmd_state <= S_TX_SEND;
                end

            endcase
        end
    end

endmodule
