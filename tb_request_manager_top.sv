// Cycle-Accurate Testbench for Request Manager Top Module
// Tests request insertion, aging, congestion detection, and grant handling

module tb_request_manager_top;

    // Parameters matching DUT
    localparam int TABLE_SIZE = 8;
    localparam int SRC_WIDTH = 2;
    localparam int DST_WIDTH = 2;
    localparam int DATA_WIDTH = 9;
    localparam int AGE_WIDTH = 3;
    localparam int MAX_AGE = 7;
    localparam int NUM_CYCLES = 40;
    localparam int MIN_REQUESTS = 20;
    
    // Testbench signals
    logic                           clock;
    logic                           reset;
    logic                           new_req_valid;
    logic [SRC_WIDTH-1:0]           new_req_source;
    logic [DST_WIDTH-1:0]           new_req_dest;
    logic [DATA_WIDTH-1:0]          new_req_data;
    logic                           new_req_ready;
    logic [TABLE_SIZE-1:0]          req_table_valid;
    logic [SRC_WIDTH-1:0]           req_table_source [TABLE_SIZE-1:0];
    logic [DST_WIDTH-1:0]           req_table_dest   [TABLE_SIZE-1:0];
    logic [DATA_WIDTH-1:0]          req_table_data   [TABLE_SIZE-1:0];
    logic [AGE_WIDTH-1:0]           req_table_age    [TABLE_SIZE-1:0];
    logic [TABLE_SIZE-1:0]          grant_vector;
    logic [$clog2(TABLE_SIZE+1)-1:0] num_active_reqs;
    logic                           table_full;
    logic                           age_overflow;
    
    // State capture for cycle-accurate verification
    logic [TABLE_SIZE-1:0]          prev_valid;
    logic [SRC_WIDTH-1:0]           prev_source [TABLE_SIZE-1:0];
    logic [DST_WIDTH-1:0]           prev_dest   [TABLE_SIZE-1:0];
    logic [DATA_WIDTH-1:0]          prev_data   [TABLE_SIZE-1:0];
    logic [AGE_WIDTH-1:0]           prev_age    [TABLE_SIZE-1:0];
    
    // Request tracking for insertion verification
    logic [SRC_WIDTH-1:0]           expected_source;
    logic [DST_WIDTH-1:0]           expected_dest;
    logic [DATA_WIDTH-1:0]          expected_data;
    logic                           expect_insertion;
    int                             expected_insert_slot;
    
    // Test statistics
    int cycle_count;
    int total_requests_attempted;
    int total_requests_inserted;
    int total_requests_granted;
    int total_age_saturations;
    int test_errors;
    
    // DUT instantiation
    request_manager_top #(
        .TABLE_SIZE(TABLE_SIZE),
        .SRC_WIDTH(SRC_WIDTH),
        .DST_WIDTH(DST_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .AGE_WIDTH(AGE_WIDTH),
        .MAX_AGE(MAX_AGE)
    ) dut (
        .clock(clock),
        .reset(reset),
        .new_req_valid(new_req_valid),
        .new_req_source(new_req_source),
        .new_req_dest(new_req_dest),
        .new_req_data(new_req_data),
        .new_req_ready(new_req_ready),
        .req_table_valid(req_table_valid),
        .req_table_source(req_table_source),
        .req_table_dest(req_table_dest),
        .req_table_data(req_table_data),
        .req_table_age(req_table_age),
        .grant_vector(grant_vector),
        .num_active_reqs(num_active_reqs),
        .table_full(table_full),
        .age_overflow(age_overflow)
    );
    
    // Clock generation - 10ns period
    initial begin
        clock = 0;
        forever #5 clock = ~clock;
    end
    
    // Task: Capture current DUT state before clock edge
    task capture_state();
        prev_valid = req_table_valid;
        for (int i = 0; i < TABLE_SIZE; i++) begin
            prev_source[i] = req_table_source[i];
            prev_dest[i]   = req_table_dest[i];
            prev_data[i]   = req_table_data[i];
            prev_age[i]    = req_table_age[i];
        end
    endtask
    
    // Task: Find expected insertion slot matching DUT's free-slot logic
    // DUT free slot rule: free_slots[i] = ~valid_reg[i] || grant_vector[i]
    // NO EXPIRATION - age==MAX_AGE does NOT free slots
    task find_insert_slot();
        logic slot_is_free;
        
        expected_insert_slot = -1;
        
        for (int i = 0; i < TABLE_SIZE; i++) begin
            // Slot is free if:
            // 1. Currently not valid, OR
            // 2. Being granted this cycle
            // NOTE: age==MAX_AGE does NOT make slot free
            slot_is_free = !prev_valid[i] || grant_vector[i];
            
            // Take first free slot (priority encoder)
            if (slot_is_free && expected_insert_slot == -1) begin
                expected_insert_slot = i;
            end
        end
    endtask
    
    // Task: Verify state after clock edge
    task verify_state();
        logic expected_overflow;
        
        // 1. Verify granted requests were removed
        for (int i = 0; i < TABLE_SIZE; i++) begin
            if (grant_vector[i] && prev_valid[i]) begin
                total_requests_granted++;
                if (req_table_valid[i] && !(expect_insertion && expected_insert_slot == i)) begin
                    $display("LOG: %0t : ERROR : tb_request_manager_top : dut.valid_reg[%0d] : expected_value: 1'b0 actual_value: 1'b1 (grant not processed)", 
                             $time, i);
                    test_errors++;
                end else begin
                    $display("LOG: %0t : INFO : tb_request_manager_top : dut.valid_reg[%0d] : expected_value: 1'b0 actual_value: 1'b0 (granted)", 
                             $time, i);
                end
            end
        end
        
        // 2. Verify age increments or saturation for remaining entries
        for (int i = 0; i < TABLE_SIZE; i++) begin
            if (prev_valid[i] && !grant_vector[i]) begin
                if (prev_age[i] < MAX_AGE) begin
                    // Age should increment
                    if (req_table_valid[i]) begin
                        if (req_table_age[i] == (prev_age[i] + 1)) begin
                            $display("LOG: %0t : INFO : tb_request_manager_top : dut.age_reg[%0d] : expected_value: %0d actual_value: %0d (age incremented)", 
                                     $time, i, prev_age[i] + 1, req_table_age[i]);
                        end else begin
                            $display("LOG: %0t : ERROR : tb_request_manager_top : dut.age_reg[%0d] : expected_value: %0d actual_value: %0d (age increment failed)", 
                                     $time, i, prev_age[i] + 1, req_table_age[i]);
                            test_errors++;
                        end
                    end else begin
                        $display("LOG: %0t : WARNING : tb_request_manager_top : dut.valid_reg[%0d] : expected_value: 1'b1 actual_value: 1'b0 (unexpected removal)", 
                                 $time, i);
                    end
                end else if (prev_age[i] == MAX_AGE) begin
                    // Age should saturate at MAX_AGE
                    if (req_table_valid[i]) begin
                        if (req_table_age[i] == MAX_AGE) begin
                            $display("LOG: %0t : INFO : tb_request_manager_top : dut.age_reg[%0d] : expected_value: %0d actual_value: %0d (age saturated at MAX)", 
                                     $time, i, MAX_AGE, req_table_age[i]);
                            total_age_saturations++;
                        end else begin
                            $display("LOG: %0t : ERROR : tb_request_manager_top : dut.age_reg[%0d] : expected_value: %0d actual_value: %0d (saturation failed)", 
                                     $time, i, MAX_AGE, req_table_age[i]);
                            test_errors++;
                        end
                    end else begin
                        $display("LOG: %0t : ERROR : tb_request_manager_top : dut.valid_reg[%0d] : expected_value: 1'b1 actual_value: 1'b0 (request at MAX_AGE was removed!)", 
                                 $time, i);
                        test_errors++;
                    end
                end
            end
        end
        
        // 3. Verify age_overflow flag
        expected_overflow = 1'b0;
        for (int i = 0; i < TABLE_SIZE; i++) begin
            if (req_table_valid[i] && req_table_age[i] == MAX_AGE) begin
                expected_overflow = 1'b1;
            end
        end
        if (age_overflow != expected_overflow) begin
            $display("LOG: %0t : ERROR : tb_request_manager_top : dut.age_overflow : expected_value: %0b actual_value: %0b", 
                     $time, expected_overflow, age_overflow);
            test_errors++;
        end else if (age_overflow) begin
            $display("LOG: %0t : INFO : tb_request_manager_top : dut.age_overflow : expected_value: 1'b1 actual_value: 1'b1 (congestion detected)", 
                     $time);
        end
        
        // 4. Verify insertion if expected
        if (expect_insertion && expected_insert_slot >= 0) begin
            if (req_table_valid[expected_insert_slot]) begin
                // Check all fields
                if (req_table_source[expected_insert_slot] == expected_source &&
                    req_table_dest[expected_insert_slot] == expected_dest &&
                    req_table_data[expected_insert_slot] == expected_data &&
                    req_table_age[expected_insert_slot] == 0) begin
                    $display("LOG: %0t : INFO : tb_request_manager_top : dut.entry[%0d] : expected_value: valid=1,src=%0d,dst=%0d,data=%0h,age=0 actual_value: MATCH (insertion successful)", 
                             $time, expected_insert_slot, expected_source, expected_dest, expected_data);
                    total_requests_inserted++;
                end else begin
                    $display("LOG: %0t : ERROR : tb_request_manager_top : dut.entry[%0d] : expected_value: src=%0d,dst=%0d,data=%0h,age=0 actual_value: src=%0d,dst=%0d,data=%0h,age=%0d (content mismatch)", 
                             $time, expected_insert_slot, expected_source, expected_dest, expected_data,
                             req_table_source[expected_insert_slot], req_table_dest[expected_insert_slot], 
                             req_table_data[expected_insert_slot], req_table_age[expected_insert_slot]);
                    test_errors++;
                end
            end else begin
                $display("LOG: %0t : ERROR : tb_request_manager_top : dut.valid_reg[%0d] : expected_value: 1'b1 actual_value: 1'b0 (insertion failed)", 
                         $time, expected_insert_slot);
                test_errors++;
            end
        end
    endtask
    
    // Main test stimulus - cycle accurate
    initial begin
        $display("TEST START");
        
        // Initialize
        reset = 1;
        new_req_valid = 0;
        new_req_source = 0;
        new_req_dest = 0;
        new_req_data = 0;
        grant_vector = 0;
        cycle_count = 0;
        total_requests_attempted = 0;
        total_requests_inserted = 0;
        total_requests_granted = 0;
        total_age_saturations = 0;
        test_errors = 0;
        expect_insertion = 0;
        
        // Reset pulse
        @(posedge clock);
        @(posedge clock);
        reset = 0;
        @(posedge clock);
        
        $display("INFO: Starting cycle-accurate test - %0d cycles, minimum %0d requests", NUM_CYCLES, MIN_REQUESTS);
        
        // Run test for specified cycles
        for (cycle_count = 1; cycle_count <= NUM_CYCLES; cycle_count++) begin
            
            // === BEFORE CLOCK EDGE: Set inputs and capture state ===
            
            // Randomly decide whether to insert a request this cycle
            if ($urandom_range(0, 2) > 0) begin  // ~67% chance
                new_req_valid = 1;
                new_req_source = $urandom_range(0, 3);
                new_req_dest = $urandom_range(0, 3);
                new_req_data = $urandom_range(0, 511);
                total_requests_attempted++;
                
                // Store expected values for verification
                expected_source = new_req_source;
                expected_dest = new_req_dest;
                expected_data = new_req_data;
            end else begin
                new_req_valid = 0;
            end
            
            // Set grant vector - randomly grant some entries
            grant_vector = 0;
            for (int i = 0; i < TABLE_SIZE; i++) begin
                if (req_table_valid[i] && ($urandom_range(0, 3) == 0)) begin  // ~25% chance each
                    grant_vector[i] = 1;
                end
            end
            
            // Capture current state before clock edge
            capture_state();
            
            // Check if handshake will succeed BEFORE clock edge
            expect_insertion = new_req_valid && new_req_ready;
            if (expect_insertion) begin
                find_insert_slot();
                $display("INFO: Cycle %0d - Attempt to insert request #%0d (src=%0d, dst=%0d, data=%0h) -> ready=%0b, slot=%0d", 
                         cycle_count, total_requests_attempted, new_req_source, new_req_dest, new_req_data, new_req_ready, expected_insert_slot);
            end else if (new_req_valid) begin
                $display("INFO: Cycle %0d - Request #%0d rejected (ready=%0b, age_overflow=%0b, table_full=%0b)", 
                         cycle_count, total_requests_attempted, new_req_ready, age_overflow, table_full);
            end
            
            // === CLOCK EDGE ===
            @(posedge clock);
            
            // === AFTER CLOCK EDGE: Verify state ===
            verify_state();
            
            // Display table status
            if (cycle_count % 5 == 0 || cycle_count <= 5) begin
                $display("INFO: === Cycle %0d Status ===", cycle_count);
                $display("INFO: Active requests: %0d, Table full: %0b, Age overflow: %0b", num_active_reqs, table_full, age_overflow);
                for (int i = 0; i < TABLE_SIZE; i++) begin
                    if (req_table_valid[i]) begin
                        $display("INFO: Entry[%0d]: valid=1, src=%0d, dst=%0d, data=%0h, age=%0d%s", 
                                 i, req_table_source[i], req_table_dest[i], req_table_data[i], req_table_age[i],
                                 (req_table_age[i] == MAX_AGE) ? " [SATURATED]" : "");
                    end
                end
            end
        end
        
        // Final statistics
        $display("INFO: ========================================");
        $display("INFO: Test Complete - Final Statistics");
        $display("INFO: ========================================");
        $display("INFO: Total DUT cycles run: %0d", cycle_count);
        $display("INFO: Total requests attempted: %0d", total_requests_attempted);
        $display("INFO: Total requests inserted: %0d", total_requests_inserted);
        $display("INFO: Total requests granted: %0d", total_requests_granted);
        $display("INFO: Total age saturations detected: %0d", total_age_saturations);
        $display("INFO: Final active requests: %0d", num_active_reqs);
        $display("INFO: Final age_overflow status: %0b", age_overflow);
        $display("INFO: Test errors detected: %0d", test_errors);
        
        // Check if we met the minimum request requirement
        if (total_requests_attempted < MIN_REQUESTS) begin
            $display("LOG: %0t : ERROR : tb_request_manager_top : total_requests_attempted : expected_value: >=%0d actual_value: %0d", 
                     $time, MIN_REQUESTS, total_requests_attempted);
            test_errors++;
        end else begin
            $display("LOG: %0t : INFO : tb_request_manager_top : total_requests_attempted : expected_value: >=%0d actual_value: %0d", 
                     $time, MIN_REQUESTS, total_requests_attempted);
        end
        
        // Final pass/fail
        if (test_errors == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("TEST FAILED");
            $error("Test failed with %0d errors", test_errors);
        end
        
        $finish(0);
    end
    
    // Timeout watchdog
    initial begin
        #5000;
        $display("ERROR: Test timeout!");
        $display("TEST FAILED");
        $fatal(1, "Simulation timeout");
    end
    
    // Waveform dump
    initial begin
        $dumpfile("dumpfile.fst");
        $dumpvars(0);
    end

endmodule
