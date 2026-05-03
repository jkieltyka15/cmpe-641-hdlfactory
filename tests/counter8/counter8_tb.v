`timescale 1ns/1ps

module counter8_tb;

    // Inputs to DUT
    reg       clk;
    reg       rst_n;
    reg       en;
    reg       load;
    reg [7:0] load_value;

    // Output from DUT
    wire [7:0] count;

    // Expected output
    reg [7:0] expected_count;

    // Testbench variables
    integer errors;
    integer test_count;
    integer i;

    // Instantiate DUT
    counter8 dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (en),
        .load       (load),
        .load_value (load_value),
        .count      (count)
    );

    // Clock generation
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Check current count against expected value
    task check_count;
        input [8*80-1:0] test_name;
        begin
            #1;
            test_count = test_count + 1;

            if (count !== expected_count) begin
                errors = errors + 1;
                $display("ERROR: test=%0d %0s | expected count=%h got count=%h",
                         test_count,
                         test_name,
                         expected_count,
                         count);
            end
        end
    endtask

    // Wait for one rising clock edge, then check result
    task clock_and_check;
        input [8*80-1:0] test_name;
        begin
            @(posedge clk);
            #1;
            test_count = test_count + 1;

            if (count !== expected_count) begin
                errors = errors + 1;
                $display("ERROR: test=%0d %0s | expected count=%h got count=%h",
                         test_count,
                         test_name,
                         expected_count,
                         count);
            end
        end
    endtask

    initial begin
        errors = 0;
        test_count = 0;

        rst_n = 1'b1;
        en = 1'b0;
        load = 1'b0;
        load_value = 8'h00;
        expected_count = 8'h00;

        $display("Starting counter8 testbench...");

        // ------------------------------------------------------------
        // Asynchronous reset test
        // ------------------------------------------------------------
        rst_n = 1'b0;
        expected_count = 8'h00;
        check_count("async reset drives count to zero");

        rst_n = 1'b1;
        en = 1'b0;
        load = 1'b0;
        load_value = 8'hAA;
        expected_count = 8'h00;
        clock_and_check("hold after reset release");

        // ------------------------------------------------------------
        // Hold behavior
        // ------------------------------------------------------------
        en = 1'b0;
        load = 1'b0;
        load_value = 8'h55;
        expected_count = 8'h00;
        clock_and_check("hold with en=0 load=0");

        // ------------------------------------------------------------
        // Load behavior
        // ------------------------------------------------------------
        load = 1'b1;
        en = 1'b0;
        load_value = 8'h12;
        expected_count = 8'h12;
        clock_and_check("load 12 with en=0");

        load = 1'b1;
        en = 1'b1;
        load_value = 8'h34;
        expected_count = 8'h34;
        clock_and_check("load has priority over enable");

        // ------------------------------------------------------------
        // Increment behavior
        // ------------------------------------------------------------
        load = 1'b0;
        en = 1'b1;
        expected_count = 8'h35;
        clock_and_check("increment from 34 to 35");

        expected_count = 8'h36;
        clock_and_check("increment from 35 to 36");

        expected_count = 8'h37;
        clock_and_check("increment from 36 to 37");

        // ------------------------------------------------------------
        // Hold after increments
        // ------------------------------------------------------------
        en = 1'b0;
        load = 1'b0;
        expected_count = 8'h37;
        clock_and_check("hold after increments");

        // ------------------------------------------------------------
        // Wraparound behavior
        // ------------------------------------------------------------
        load = 1'b1;
        en = 1'b0;
        load_value = 8'hFE;
        expected_count = 8'hFE;
        clock_and_check("load FE");

        load = 1'b0;
        en = 1'b1;
        expected_count = 8'hFF;
        clock_and_check("increment FE to FF");

        expected_count = 8'h00;
        clock_and_check("increment FF to 00 wraparound");

        expected_count = 8'h01;
        clock_and_check("increment 00 to 01 after wraparound");

        // ------------------------------------------------------------
        // Async reset while clock is running and not aligned to edge
        // ------------------------------------------------------------
        #2;
        rst_n = 1'b0;
        expected_count = 8'h00;
        check_count("async reset between clock edges");

        #3;
        rst_n = 1'b1;
        en = 1'b1;
        load = 1'b0;
        expected_count = 8'h01;
        clock_and_check("increment after async reset release");

        // ------------------------------------------------------------
        // Multiple load values
        // ------------------------------------------------------------
        load = 1'b1;
        en = 1'b0;
        load_value = 8'hA5;
        expected_count = 8'hA5;
        clock_and_check("load A5");

        load_value = 8'h5A;
        expected_count = 8'h5A;
        clock_and_check("load 5A");

        load_value = 8'h00;
        expected_count = 8'h00;
        clock_and_check("load 00");

        load_value = 8'hFF;
        expected_count = 8'hFF;
        clock_and_check("load FF");

        // ------------------------------------------------------------
        // Randomized deterministic-style sequence
        // ------------------------------------------------------------
        load = 1'b1;
        en = 1'b0;
        load_value = 8'h10;
        expected_count = 8'h10;
        clock_and_check("random sequence seed load");

        load = 1'b0;
        en = 1'b1;

        for (i = 0; i < 20; i = i + 1) begin
            expected_count = expected_count + 8'h01;
            clock_and_check("random sequence increment");
        end

        en = 1'b0;
        load = 1'b0;
        clock_and_check("random sequence hold 1");
        clock_and_check("random sequence hold 2");

        load = 1'b1;
        en = 1'b1;
        load_value = 8'hC3;
        expected_count = 8'hC3;
        clock_and_check("random sequence load priority");

        load = 1'b0;
        en = 1'b1;

        for (i = 0; i < 10; i = i + 1) begin
            expected_count = expected_count + 8'h01;
            clock_and_check("random sequence post-load increment");
        end

        // ------------------------------------------------------------
        // Final result
        // ------------------------------------------------------------
        if (errors == 0) begin
            $display("PASS: All %0d tests passed.", test_count);
        end else begin
            $display("FAIL: %0d errors out of %0d tests.", errors, test_count);
        end

        $finish;
    end

endmodule