`timescale 1ns / 1ps

//============================================================================
// Testbench for multi-port request_manager_top + age_arbiter
//
// Signal convention: drive on NEGEDGE, sample on NEGEDGE.
//
// KEY TEST: Two requests submitted in the same cycle to different
// destinations are inserted simultaneously, granted simultaneously by
// the arbiter, and cleared in the same cycle — true same-cycle
// multi-destination grants.
//============================================================================

module system_tb;

    localparam int TABLE_SIZE = 8;
    localparam int SRC_WIDTH  = 2;
    localparam int DST_WIDTH  = 2;
    localparam int DATA_WIDTH = 9;
    localparam int AGE_WIDTH  = 3;
    localparam int MAX_AGE    = 7;
    localparam int NUM_SRCS   = 1 << SRC_WIDTH;
    localparam int NUM_DSTS   = 1 << DST_WIDTH;

    logic                           clock, reset;

    // Multi-port request interface
    logic [NUM_SRCS-1:0]            new_req_valid;
    logic [DST_WIDTH-1:0]           new_req_dest  [NUM_SRCS-1:0];
    logic [DATA_WIDTH-1:0]          new_req_data  [NUM_SRCS-1:0];
    logic [NUM_SRCS-1:0]            new_req_ready;

    // Table + arbiter signals
    logic [TABLE_SIZE-1:0]          req_table_valid;
    logic [SRC_WIDTH-1:0]           req_table_source [TABLE_SIZE-1:0];
    logic [DST_WIDTH-1:0]           req_table_dest   [TABLE_SIZE-1:0];
    logic [DATA_WIDTH-1:0]          req_table_data   [TABLE_SIZE-1:0];
    logic [AGE_WIDTH-1:0]           req_table_age    [TABLE_SIZE-1:0];
    logic [TABLE_SIZE-1:0]          grant_vector;

    logic [TABLE_SIZE-1:0]          granted_valid;
    logic [SRC_WIDTH-1:0]           granted_source   [TABLE_SIZE-1:0];
    logic [DST_WIDTH-1:0]           granted_dest     [TABLE_SIZE-1:0];
    logic [DATA_WIDTH-1:0]          granted_data     [TABLE_SIZE-1:0];
    logic [TABLE_SIZE-1:0]          expired_valid;

    logic [$clog2(TABLE_SIZE+1)-1:0] num_active_reqs;
    logic                            table_full, age_overflow;

    // ---- DUT wiring ----
    request_manager_top #(
        .TABLE_SIZE(TABLE_SIZE), .REQ_WIDTH(16), .SRC_WIDTH(SRC_WIDTH),
        .DST_WIDTH(DST_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .AGE_WIDTH(AGE_WIDTH), .MAX_AGE(MAX_AGE)
    ) u_top (.*);

    age_arbiter #(
        .TABLE_SIZE(TABLE_SIZE), .DST_WIDTH(DST_WIDTH),
        .DATA_WIDTH(DATA_WIDTH), .AGE_WIDTH(AGE_WIDTH), .MAX_AGE(MAX_AGE)
    ) u_arbiter (
        .req_valid(req_table_valid),
        .req_dest(req_table_dest), .req_data(req_table_data),
        .req_age(req_table_age), .grant_vector(grant_vector)
    );

    initial clock = 0;
    always #5 clock = ~clock;

    // ---- Helpers ----
    task automatic idle();
        new_req_valid = '0;
        for (int s = 0; s < NUM_SRCS; s++) begin
            new_req_dest[s] = '0;
            new_req_data[s] = '0;
        end
    endtask

    // Submit a single request from one source
    task automatic drive1(logic [1:0] src, logic [1:0] dst, logic [8:0] data);
        new_req_valid[src] = 1'b1;
        new_req_dest[src]  = dst;
        new_req_data[src]  = data;
    endtask

    task automatic tick();
        @(posedge clock); @(negedge clock);
    endtask

    // Submit one request, wait for latch, idle
    task automatic submit_one(logic [1:0] src, logic [1:0] dst, logic [8:0] data);
        idle();
        drive1(src, dst, data);
        tick();
        idle();
    endtask

    task automatic do_reset();
        reset = 1; idle(); tick(); tick(); reset = 0; tick();
    endtask

    // ---- Scoreboard ----
    int pass_count = 0, fail_count = 0, test_id = 0;

    task automatic check(string desc, logic cond);
        test_id++;
        if (cond) begin $display("  TEST %0d PASS : %s", test_id, desc); pass_count++; end
        else      begin $display("  TEST %0d FAIL : %s", test_id, desc); fail_count++; end
    endtask

    function automatic int popcount(logic [TABLE_SIZE-1:0] v);
        int c = 0; for (int i = 0; i < TABLE_SIZE; i++) c += int'(v[i]); return c;
    endfunction

    function automatic int find_entry(logic [1:0] src, logic [1:0] dst);
        for (int i = 0; i < TABLE_SIZE; i++)
            if (req_table_valid[i] && req_table_source[i] == src && req_table_dest[i] == dst)
                return i;
        return -1;
    endfunction

    task automatic dump();
        $display("  [table] active=%0d grant_vec=%b granted=%b expired=%b",
                 num_active_reqs, grant_vector, granted_valid, expired_valid);
        for (int i = 0; i < TABLE_SIZE; i++)
            if (req_table_valid[i])
                $display("    [%0d] src=%0d dst=%0d data=%3d age=%0d",
                    i, req_table_source[i], req_table_dest[i],
                    req_table_data[i], req_table_age[i]);
    endtask

    // ---- Stimulus ----
    initial begin
        do_reset();

        // ==============================================================
        $display("\n=== 1: Same-cycle multi-insert and multi-grant ===");
        // ==============================================================
        // Submit src=1→dst=2 AND src=0→dst=3 in the SAME cycle.
        // Both should be inserted, granted, and cleared together.
        idle();
        drive1(2'd1, 2'd2, 9'd100);   // src=1 → dst=2
        drive1(2'd0, 2'd3, 9'd200);   // src=0 → dst=3
        tick();
        idle();

        // -- Cycle 0: both inserted, grant not yet applied --
        check("C0: 2 entries inserted simultaneously",
              num_active_reqs == 2);
        check("C0: grant_vector has 2 bits (comb)",
              popcount(grant_vector) == 2);
        check("C0: granted_valid not yet",
              granted_valid == '0);

        // Verify both entries exist with age 0
        begin
            int i1 = find_entry(2'd1, 2'd2);
            int i0 = find_entry(2'd0, 2'd3);
            check("C0: src=1→dst=2 present, age=0",
                  i1 >= 0 && req_table_age[i1] == 0);
            check("C0: src=0→dst=3 present, age=0",
                  i0 >= 0 && req_table_age[i0] == 0);
        end

        tick();
        // -- Cycle 1: both aged to 1, grant_reg captured --
        check("C1: both still alive",
              num_active_reqs == 2);
        check("C1: granted_valid still 0",
              granted_valid == '0);
        begin
            int i1 = find_entry(2'd1, 2'd2);
            int i0 = find_entry(2'd0, 2'd3);
            check("C1: src=1→dst=2 age=1",
                  i1 >= 0 && req_table_age[i1] == 1);
            check("C1: src=0→dst=3 age=1",
                  i0 >= 0 && req_table_age[i0] == 1);
        end

        tick();
        // -- Cycle 2: BOTH cleared in the SAME cycle --
        check("C2: both cleared simultaneously",
              num_active_reqs == 0);
        check("C2: granted_valid has 2 bits",
              popcount(granted_valid) == 2);

        // Verify granted data
        begin
            logic found_1to2 = 0;
            logic found_0to3 = 0;
            for (int i = 0; i < TABLE_SIZE; i++) begin
                if (granted_valid[i]) begin
                    if (granted_source[i] == 2'd1 && granted_dest[i] == 2'd2 &&
                        granted_data[i] == 9'd100)
                        found_1to2 = 1;
                    if (granted_source[i] == 2'd0 && granted_dest[i] == 2'd3 &&
                        granted_data[i] == 9'd200)
                        found_0to3 = 1;
                end
            end
            check("C2: granted src=1→dst=2 data=100", found_1to2);
            check("C2: granted src=0→dst=3 data=200", found_0to3);
        end

        tick();
        check("C3: granted_valid pulse cleared",
              granted_valid == '0);

        do_reset();

        // ==============================================================
        $display("\n=== 2: All 4 sources submit simultaneously ===");
        // ==============================================================
        // src=0→dst=1, src=1→dst=0, src=2→dst=3, src=3→dst=2
        // All unique dests — all should be granted and cleared together.
        idle();
        drive1(2'd0, 2'd1, 9'd10);
        drive1(2'd1, 2'd0, 9'd20);
        drive1(2'd2, 2'd3, 9'd30);
        drive1(2'd3, 2'd2, 9'd40);
        tick();
        idle();

        check("4 entries inserted",               num_active_reqs == 4);
        check("grant_vector has 4 bits",           popcount(grant_vector) == 4);

        tick();
        check("All 4 still alive at age 1",       num_active_reqs == 4);

        tick();
        check("All 4 cleared simultaneously",     num_active_reqs == 0);
        check("4 granted_valid bits",             popcount(granted_valid) == 4);

        do_reset();

        // ==============================================================
        $display("\n=== 3: Single-source pipeline (backward compat) ===");
        // ==============================================================
        submit_one(2'd0, 2'd1, 9'd100);

        check("C0: present, age=0",               num_active_reqs == 1 &&
                                                   req_table_age[0] == 0);
        tick();
        check("C1: alive, age=1",                 num_active_reqs == 1 &&
                                                   req_table_age[0] == 1);
        tick();
        check("C2: cleared",                      num_active_reqs == 0);
        check("C2: granted",                      granted_valid != '0);

        do_reset();

        // ==============================================================
        $display("\n=== 4: Self-request rejected per-source ===");
        // ==============================================================
        // Submit self-requests from all 4 sources simultaneously
        idle();
        drive1(2'd0, 2'd0, 9'd1);   // self
        drive1(2'd1, 2'd1, 9'd2);   // self
        drive1(2'd2, 2'd2, 9'd3);   // self
        drive1(2'd3, 2'd3, 9'd4);   // self
        tick();
        idle();

        check("All 4 self-requests rejected",     num_active_reqs == 0);
        check("All ready signals deasserted",     new_req_ready == '0);

        // Mix: 2 valid, 2 self-requests
        idle();
        drive1(2'd0, 2'd0, 9'd1);   // self (rejected)
        drive1(2'd1, 2'd2, 9'd2);   // valid
        drive1(2'd2, 2'd2, 9'd3);   // self (rejected)
        drive1(2'd3, 2'd0, 9'd4);   // valid
        tick();
        idle();

        check("2 valid accepted, 2 self rejected",
              num_active_reqs == 2);

        repeat (4) tick();
        check("Drained",                          num_active_reqs == 0);

        do_reset();

        // ==============================================================
        $display("\n=== 5: Destination conflict with same-cycle insert ===");
        // ==============================================================
        // Submit src=0→dst=1 and src=2→dst=1 simultaneously (same dest).
        // Both inserted, but arbiter can only grant one per cycle.
        idle();
        drive1(2'd0, 2'd1, 9'd10);
        drive1(2'd2, 2'd1, 9'd20);
        tick();
        idle();

        check("Both inserted (same dest)",        num_active_reqs == 2);
        // grant_vector should only have 1 bit (dest conflict)
        check("grant_vector: 1 winner for dst=1", popcount(grant_vector) == 1);

        tick();
        // Still both alive (grant_reg was 0 at insertion)
        check("Both still alive at age 1",        num_active_reqs == 2);

        tick();
        // One cleared (the one with lower table index wins tie at same age)
        check("One cleared (tie-break winner)",    num_active_reqs == 1);
        check("One granted",                       popcount(granted_valid) == 1);

        // Wait for the loser's pipeline
        tick(); tick();
        check("Second also cleared",              num_active_reqs == 0);

        do_reset();

        // ==============================================================
        $display("\n=== 6: Fill table — 4 sources × 2 rounds ===");
        // ==============================================================
        // Insert 4 in round 1, 4 in round 2 = 8 entries (TABLE_SIZE)
        idle();
        drive1(2'd0, 2'd1, 9'd1);
        drive1(2'd1, 2'd0, 9'd2);
        drive1(2'd2, 2'd3, 9'd3);
        drive1(2'd3, 2'd2, 9'd4);
        tick();

        // Round 1 entries get granted immediately, but cleared 2 cycles later.
        // Round 2: different dests to avoid conflicts with round 1
        idle();
        drive1(2'd0, 2'd2, 9'd5);
        drive1(2'd1, 2'd3, 9'd6);
        drive1(2'd2, 2'd0, 9'd7);
        drive1(2'd3, 2'd1, 9'd8);
        tick();
        idle();

        $display("  After 2 rounds: active=%0d", num_active_reqs);
        check("Multiple entries active",           num_active_reqs >= 4);

        // Drain
        repeat (10) tick();
        check("All drained",                      num_active_reqs == 0);

        do_reset();

        // ==============================================================
        $display("\n=== 7: Overflow + expiration ===");
        // ==============================================================
        // Use unit_expiration_tb for thorough expiration testing.
        // Here: verify system doesn't deadlock with sustained load.
        for (int n = 0; n < 10; n++) begin
            idle();
            for (int s = 0; s < NUM_SRCS; s++)
                drive1(2'(s), 2'((s+1) % NUM_DSTS), 9'(n*4+s));
            tick();
        end
        idle();

        $display("  After 10 rounds of 4: active=%0d", num_active_reqs);
        repeat (30) tick();
        check("System drained — no deadlock",     num_active_reqs == 0);

        do_reset();

        // ==============================================================
        $display("\n=== 8: Slot reuse after simultaneous clear ===");
        // ==============================================================
        // Insert 2, let them clear together, insert 2 more into freed slots.
        idle();
        drive1(2'd0, 2'd1, 9'd42);
        drive1(2'd1, 2'd0, 9'd43);
        tick(); idle();

        tick(); tick();  // both cleared after 2 cycles
        check("Both cleared",                     num_active_reqs == 0);

        // Insert 2 new entries — should reuse freed slots
        idle();
        drive1(2'd2, 2'd3, 9'd50);
        drive1(2'd3, 2'd2, 9'd51);
        tick(); idle();

        check("2 new entries in reused slots",    num_active_reqs == 2);

        tick(); tick();
        check("New entries also cleared",         num_active_reqs == 0);
        check("Granted output fired for new entries",
              popcount(granted_valid) == 2);

        // ==============================================================
        // Summary
        // ==============================================================
        $display("\n========================================");
        $display("  RESULTS: %0d passed, %0d failed out of %0d",
                 pass_count, fail_count, test_id);
        $display("========================================\n");
        $finish;
    end

endmodule
