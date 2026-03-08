// Testbench for Age-Based Crossbar Switch Arbiter
// Comprehensive test cases with automatic checking

`timescale 1ns/1ps

module tb_age_based_switch_arbiter;

    // Parameters matching DUT
    parameter int NUM_PORTS = 4;
    parameter int AGE_WIDTH = 8;
    parameter int CLK_PERIOD = 10; // 10ns clock period
    
    // DUT signals
    logic                                    clock;
    logic                                    reset;
    logic [NUM_PORTS-1:0][NUM_PORTS-1:0]     request;
    logic [NUM_PORTS-1:0][NUM_PORTS-1:0]     grant;
    logic [NUM_PORTS-1:0]                    ready;
    
    // Test control
    int test_number;
    int pass_count;
    int fail_count;
    string test_description;
    
    // Age counter monitoring (for waveform viewing)
    logic [AGE_WIDTH-1:0] age_input0;
    logic [AGE_WIDTH-1:0] age_input1;
    logic [AGE_WIDTH-1:0] age_input2;
    logic [AGE_WIDTH-1:0] age_input3;
    
    // Debug signals for understanding age behavior
    logic served_input0, served_input1, served_input2, served_input3;
    logic has_grant_input0, has_grant_input1, has_grant_input2, has_grant_input3;
    logic has_ungranted_input0, has_ungranted_input1, has_ungranted_input2, has_ungranted_input3;
    
    // Extract age counters from DUT for waveform visibility
    assign age_input0 = dut.age[0];
    assign age_input1 = dut.age[1];
    assign age_input2 = dut.age[2];
    assign age_input3 = dut.age[3];
    
    // Extract debug signals
    assign served_input0 = dut.input_fully_served[0];
    assign served_input1 = dut.input_fully_served[1];
    assign served_input2 = dut.input_fully_served[2];
    assign served_input3 = dut.input_fully_served[3];
    
    assign has_grant_input0 = dut.input_has_any_grant[0];
    assign has_grant_input1 = dut.input_has_any_grant[1];
    assign has_grant_input2 = dut.input_has_any_grant[2];
    assign has_grant_input3 = dut.input_has_any_grant[3];
    
    assign has_ungranted_input0 = dut.input_has_ungranted_request[0];
    assign has_ungranted_input1 = dut.input_has_ungranted_request[1];
    assign has_ungranted_input2 = dut.input_has_ungranted_request[2];
    assign has_ungranted_input3 = dut.input_has_ungranted_request[3];
    
    // DUT instantiation
    age_based_switch_arbiter #(
        .NUM_PORTS(NUM_PORTS),
        .AGE_WIDTH(AGE_WIDTH)
    ) dut (
        .clock(clock),
        .reset(reset),
        .request(request),
        .grant(grant),
        .ready(ready)
    );
    
    // Clock generation
    initial begin
        clock = 0;
        forever #(CLK_PERIOD/2) clock = ~clock;
    end
    
    //========================================================================
    // Check Task - Automatic Verification
    //========================================================================
    task automatic check_grant(
        input logic [NUM_PORTS-1:0][NUM_PORTS-1:0] expected,
        input string description
    );
        test_number++;
        test_description = description;
        
        #1; // Small delay for signals to settle
        
        if (grant === expected) begin
            pass_count++;
            $display("[PASS] Test %0d: %s", test_number, description);
        end else begin
            fail_count++;
            $display("[FAIL] Test %0d: %s", test_number, description);
            $display("  Expected grant matrix:");
            for (int i = 0; i < NUM_PORTS; i++) begin
                $display("    Input %0d -> Outputs: %04b", i, expected[i]);
            end
            $display("  Actual grant matrix:");
            for (int i = 0; i < NUM_PORTS; i++) begin
                $display("    Input %0d -> Outputs: %04b", i, grant[i]);
            end
            $display("  Ages: [0]=%0d, [1]=%0d, [2]=%0d, [3]=%0d", 
                     age_input0, age_input1, age_input2, age_input3);
        end
    endtask
    
    //========================================================================
    // Apply Stimulus Task
    //========================================================================
    task automatic apply_stimulus(
        input logic [NUM_PORTS-1:0][NUM_PORTS-1:0] req_in,
        input logic [NUM_PORTS-1:0] ready_in,
        input int cycles
    );
        request = req_in;
        ready = ready_in;
        repeat(cycles) @(posedge clock);
    endtask
    
    //========================================================================
    // Apply and Check Immediately (for equal-age scenarios)
    //========================================================================
    task automatic apply_and_check(
        input logic [NUM_PORTS-1:0][NUM_PORTS-1:0] req_in,
        input logic [NUM_PORTS-1:0] ready_in,
        input logic [NUM_PORTS-1:0][NUM_PORTS-1:0] expected,
        input string description
    );
        // Set inputs immediately  (at current time, right after reset's posedge)
        request = req_in;
        ready = ready_in;
        #1;  // Small delay for combinational logic
        test_number++;
        test_description = description;
        
        if (grant === expected) begin
            pass_count++;
            $display("[PASS] Test %0d: %s", test_number, description);
        end else begin
            fail_count++;
            $display("[FAIL] Test %0d: %s", test_number, description);
            $display("  Expected grant matrix:");
            for (int i = 0; i < NUM_PORTS; i++) begin
                $display("    Input %0d -> Outputs: %04b", i, expected[i]);
            end
            $display("  Actual grant matrix:");
            for (int i = 0; i < NUM_PORTS; i++) begin
                $display("    Input %0d -> Outputs: %04b", i, grant[i]);
            end
            $display("  Ages: [0]=%0d, [1]=%0d, [2]=%0d, [3]=%0d", 
                     age_input0, age_input1, age_input2, age_input3);
        end
    endtask
    
    //========================================================================
    // Reset Task
    //========================================================================
    task automatic apply_reset();
        reset = 1;
        request = '0;
        ready = '1;
        repeat(2) @(posedge clock);
        reset = 0;
        @(posedge clock);
        @(negedge clock);  // End at negedge, so next posedge is far away
    endtask
    
    //========================================================================
    // Main Test Sequence
    //========================================================================
    initial begin
        $display("TEST START");
        $display("========================================");
        $display("Age-Based Crossbar Switch Arbiter Testbench");
        $display("NUM_PORTS = %0d", NUM_PORTS);
        $display("AGE_WIDTH = %0d", AGE_WIDTH);
        $display("========================================");
        
        // Initialize
        test_number = 0;
        pass_count = 0;
        fail_count = 0;
        clock = 0;
        reset = 0;
        request = '0;
        ready = '1;
        
        // Apply reset
        apply_reset();
        
        //====================================================================
        // TEST CASE 1: No requests - no grants
        //====================================================================
        $display("\n--- Test Case 1: No Requests ---");
        apply_stimulus('0, '1, 1);
        check_grant('0, "No requests should yield no grants");
        
        //====================================================================
        // TEST CASE 2: Input 0 requests Output 0
        //====================================================================
        $display("\n--- Test Case 2: Single Request In0->Out0 ---");
        request[0] = 4'b0001;  // Input 0 requests Output 0
        apply_stimulus(request, '1, 1);
        grant = '0;
        grant[0][0] = 1'b1;
        check_grant(grant, "In0->Out0 should be granted");
        
        //====================================================================
        // TEST CASE 3: Input 1 requests Output 2
        //====================================================================
        $display("\n--- Test Case 3: Single Request In1->Out2 ---");
        apply_reset();
        request = '0;
        request[1] = 4'b0100;  // Input 1 requests Output 2
        apply_stimulus(request, '1, 1);
        grant = '0;
        grant[1][2] = 1'b1;
        check_grant(grant, "In1->Out2 should be granted");
        
        //====================================================================
        // TEST CASE 4: Parallel grants (no conflicts)
        //====================================================================
        $display("\n--- Test Case 4: Parallel Grants ---");
        apply_reset();
        request = '0;
        request[0] = 4'b0001;  // In0 -> Out0
        request[1] = 4'b0010;  // In1 -> Out1
        request[2] = 4'b0100;  // In2 -> Out2
        request[3] = 4'b1000;  // In3 -> Out3
        apply_stimulus(request, '1, 1);
        grant = '0;
        grant[0][0] = 1'b1;
        grant[1][1] = 1'b1;
        grant[2][2] = 1'b1;
        grant[3][3] = 1'b1;
        check_grant(grant, "All parallel requests should be granted");
        
        //====================================================================
        // TEST CASE 5: Two inputs request same output (equal age)
        //====================================================================
        $display("\n--- Test Case 5: Conflict Resolution - Equal Age ---");
        apply_reset();
        request = '0;
        request[0] = 4'b0100;  // In0 -> Out2
        request[1] = 4'b0100;  // In1 -> Out2 (conflict!)
        // Lower index (In0) should win
        grant = '0;
        grant[0][2] = 1'b1;
        apply_and_check(request, '1, grant, "In0 should win Out2 (lower index, equal age)");
        
        //====================================================================
        // TEST CASE 6: Age-based conflict resolution
        //====================================================================
        $display("\n--- Test Case 6: Age-Based Conflict Resolution ---");
        apply_reset();
        // In1 requests first and ages
        request = '0;
        request[1] = 4'b0010;  // In1 -> Out1
        ready = 4'b0000;  // Not ready, so age accumulates
        repeat(5) @(posedge clock);
        
        // Now In0 also requests Out1 (but In1 is older)
        request[0] = 4'b0010;  // In0 -> Out1 (conflict with In1)
        ready = '1;
        @(posedge clock);
        #1;
        grant = '0;
        grant[1][1] = 1'b1;  // In1 should win (older)
        check_grant(grant, "In1 should win Out1 (older age)");
        
        //====================================================================
        // TEST CASE 7: Multiple outputs requested by one input
        //====================================================================
        $display("\n--- Test Case 7: One Input Requests Multiple Outputs ---");
        apply_reset();
        request = '0;
        request[0] = 4'b0101;  // In0 requests Out0 AND Out2
        apply_stimulus(request, '1, 1);
        grant = '0;
        grant[0][0] = 1'b1;
        grant[0][2] = 1'b1;
        check_grant(grant, "In0 should get both Out0 and Out2");
        
        //====================================================================
        // TEST CASE 8: Complex scenario with multiple conflicts
        //====================================================================
        $display("\n--- Test Case 8: Complex Multi-Conflict ---");
        apply_reset();
        request = '0;
        request[0] = 4'b0001;  // In0 -> Out0
        request[1] = 4'b0001;  // In1 -> Out0 (conflict!)
        request[2] = 4'b0010;  // In2 -> Out1
        request[3] = 4'b0100;  // In3 -> Out2
        grant = '0;
        grant[0][0] = 1'b1;  // In0 wins Out0
        grant[2][1] = 1'b1;  // In2 gets Out1
        grant[3][2] = 1'b1;  // In3 gets Out2
        apply_and_check(request, '1, grant, "In0 wins Out0, In2 and In3 get their outputs");
        
        //====================================================================
        // TEST CASE 9: Three-way conflict for one output
        //====================================================================
        $display("\n--- Test Case 9: Three-Way Conflict ---");
        apply_reset();
        request = '0;
        request[0] = 4'b1000;  // In0 -> Out3
        request[1] = 4'b1000;  // In1 -> Out3
        request[2] = 4'b1000;  // In2 -> Out3 (three-way conflict!)
        grant = '0;
        grant[0][3] = 1'b1;  // In0 wins (lowest index)
        apply_and_check(request, '1, grant, "In0 wins three-way conflict for Out3");
        
        //====================================================================
        // TEST CASE 10: Request deasserted
        //====================================================================
        $display("\n--- Test Case 10: Request Deasserted ---");
        apply_reset();
        request = '0;
        request[0] = 4'b0001;
        apply_stimulus(request, '1, 2);
        request = '0;  // Deassert all requests
        apply_stimulus(request, '1, 1);
        check_grant('0, "No requests should yield no grants");
        
        //====================================================================
        // TEST CASE 11-20: More complex scenarios
        //====================================================================
        
        // Test 11: Aging with ready=0
        $display("\n--- Test Case 11: Age Accumulation with Ready=0 ---");
        apply_reset();
        request = '0;
        request[2] = 4'b0001;  // In2 -> Out0
        ready = 4'b0000;  // Not ready
        repeat(3) @(posedge clock);
        grant = '0;
        grant[2][0] = 1'b1;
        check_grant(grant, "In2 granted but ready=0");
        
        // Test 12: Reset clears ages
        $display("\n--- Test Case 12: Reset Clears Ages ---");
        apply_reset();
        request = '0;
        request[0] = 4'b0010;
        request[1] = 4'b0010;
        grant = '0;
        grant[0][1] = 1'b1;
        apply_and_check(request, '1, grant, "After reset, In0 wins (equal age)");
        
        // Test 13: All inputs request all outputs
        $display("\n--- Test Case 13: All Request All Outputs ---");
        apply_reset();
        for (int i = 0; i < NUM_PORTS; i++) begin
            request[i] = 4'b1111;  // All inputs request all outputs
        end
        grant = '0;
        // When all ages are equal, In0 (lowest index) wins all outputs
        grant[0][0] = 1'b1;  // In0 wins Out0
        grant[0][1] = 1'b1;  // In0 wins Out1
        grant[0][2] = 1'b1;  // In0 wins Out2
        grant[0][3] = 1'b1;  // In0 wins Out3
        apply_and_check(request, '1, grant, "In0 wins all outputs (lowest index, equal age)");
        
        // Test 14-20: Additional edge cases
        $display("\n--- Test Case 14: Input 3 Ages, Then Wins ---");
        apply_reset();
        request = '0;
        request[3] = 4'b0001;  // In3 -> Out0, ages
        ready = 4'b0000;
        repeat(7) @(posedge clock);
        request[0] = 4'b0001;  // In0 now also requests Out0
        ready = '1;
        @(posedge clock);
        #1;
        grant = '0;
        grant[3][0] = 1'b1;  // In3 should win (older)
        check_grant(grant, "In3 wins Out0 (much older than In0)");
        
        $display("\n--- Test Case 15: Partial Overlap ---");
        apply_reset();
        request = '0;
        request[0] = 4'b0011;  // In0 -> Out0, Out1
        request[1] = 4'b0110;  // In1 -> Out1, Out2 (Out1 conflict!)
        grant = '0;
        grant[0][0] = 1'b1;  // In0 gets Out0
        grant[0][1] = 1'b1;  // In0 wins Out1 (lower index)
        grant[1][2] = 1'b1;  // In1 gets Out2
        apply_and_check(request, '1, grant, "In0 wins overlap, In1 gets non-conflicting");
        
        $display("\n--- Test Case 16-20: Rapid sequences ---");
        for (int tc = 16; tc <= 20; tc++) begin
            $display("\n--- Test Case %0d: Rapid Sequence %0d ---", tc, tc-15);
            apply_reset();
            request = '0;
            request[tc % NUM_PORTS] = 1 << (tc % NUM_PORTS);
            grant = '0;
            grant[tc % NUM_PORTS][tc % NUM_PORTS] = 1'b1;
            apply_and_check(request, '1, grant, $sformatf("In%0d->Out%0d granted", tc % NUM_PORTS, tc % NUM_PORTS));
        end
        
        //====================================================================
        // Final Results
        //====================================================================
        $display("\n========================================");
        $display("Test Summary");
        $display("========================================");
        $display("Total Tests: %0d", test_number);
        $display("Passed:      %0d", pass_count);
        $display("Failed:      %0d", fail_count);
        $display("========================================");
        
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("TEST FAILED");
        end
        
        $finish(0);
    end
    
    // Timeout watchdog
    initial begin
        #200000; // 200us timeout
        $display("ERROR: Testbench timeout!");
        $fatal(1, "Simulation exceeded maximum time");
    end
    
    // Waveform dump
    initial begin
        $dumpfile("dumpfile.fst");
        $dumpvars(0);
    end

endmodule
