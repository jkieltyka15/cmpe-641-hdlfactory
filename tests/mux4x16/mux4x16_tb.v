`timescale 1ns/1ps

module mux4x16_tb;

    // Inputs to DUT
    reg [15:0] in0;
    reg [15:0] in1;
    reg [15:0] in2;
    reg [15:0] in3;
    reg [1:0]  sel;

    // Output from DUT
    wire [15:0] out;

    // Expected output
    reg [15:0] expected;

    // Testbench variables
    integer errors;
    integer test_count;
    integer i;

    // Instantiate DUT
    mux4x16 dut (
        .in0 (in0),
        .in1 (in1),
        .in2 (in2),
        .in3 (in3),
        .sel (sel),
        .out (out)
    );

    // Task to apply one test vector and check result
    task run_test;
        input [15:0] test_in0;
        input [15:0] test_in1;
        input [15:0] test_in2;
        input [15:0] test_in3;
        input [1:0]  test_sel;
        begin
            in0 = test_in0;
            in1 = test_in1;
            in2 = test_in2;
            in3 = test_in3;
            sel = test_sel;

            case (test_sel)
                2'b00: expected = test_in0;
                2'b01: expected = test_in1;
                2'b10: expected = test_in2;
                2'b11: expected = test_in3;
                default: expected = 16'h0000;
            endcase

            #1;

            test_count = test_count + 1;

            if (out !== expected) begin
                errors = errors + 1;
                $display("ERROR: test=%0d sel=%b in0=%h in1=%h in2=%h in3=%h | expected=%h got=%h",
                         test_count,
                         test_sel,
                         test_in0,
                         test_in1,
                         test_in2,
                         test_in3,
                         expected,
                         out);
            end
        end
    endtask

    initial begin
        errors = 0;
        test_count = 0;

        $display("Starting mux4x16 testbench...");

        // Basic select tests with unique values
        run_test(16'h0000, 16'h1111, 16'h2222, 16'h3333, 2'b00);
        run_test(16'h0000, 16'h1111, 16'h2222, 16'h3333, 2'b01);
        run_test(16'h0000, 16'h1111, 16'h2222, 16'h3333, 2'b10);
        run_test(16'h0000, 16'h1111, 16'h2222, 16'h3333, 2'b11);

        // Boundary values
        run_test(16'hFFFF, 16'h0000, 16'hAAAA, 16'h5555, 2'b00);
        run_test(16'hFFFF, 16'h0000, 16'hAAAA, 16'h5555, 2'b01);
        run_test(16'hFFFF, 16'h0000, 16'hAAAA, 16'h5555, 2'b10);
        run_test(16'hFFFF, 16'h0000, 16'hAAAA, 16'h5555, 2'b11);

        // Pattern tests
        run_test(16'h1234, 16'h5678, 16'h9ABC, 16'hDEF0, 2'b00);
        run_test(16'h1234, 16'h5678, 16'h9ABC, 16'hDEF0, 2'b01);
        run_test(16'h1234, 16'h5678, 16'h9ABC, 16'hDEF0, 2'b10);
        run_test(16'h1234, 16'h5678, 16'h9ABC, 16'hDEF0, 2'b11);

        // Same input values, should still pass for all selects
        run_test(16'hBEEF, 16'hBEEF, 16'hBEEF, 16'hBEEF, 2'b00);
        run_test(16'hBEEF, 16'hBEEF, 16'hBEEF, 16'hBEEF, 2'b01);
        run_test(16'hBEEF, 16'hBEEF, 16'hBEEF, 16'hBEEF, 2'b10);
        run_test(16'hBEEF, 16'hBEEF, 16'hBEEF, 16'hBEEF, 2'b11);

        // Walking 1s on each input
        for (i = 0; i < 16; i = i + 1) begin
            run_test(16'h0001 << i, 16'h0000,      16'h0000,      16'h0000,      2'b00);
            run_test(16'h0000,      16'h0001 << i, 16'h0000,      16'h0000,      2'b01);
            run_test(16'h0000,      16'h0000,      16'h0001 << i, 16'h0000,      2'b10);
            run_test(16'h0000,      16'h0000,      16'h0000,      16'h0001 << i, 2'b11);
        end

        // Random tests
        for (i = 0; i < 1000; i = i + 1) begin
            run_test($random, $random, $random, $random, 2'b00);
            run_test($random, $random, $random, $random, 2'b01);
            run_test($random, $random, $random, $random, 2'b10);
            run_test($random, $random, $random, $random, 2'b11);
        end

        // Final result
        if (errors == 0) begin
            $display("PASS: All %0d tests passed.", test_count);
        end else begin
            $display("FAIL: %0d errors out of %0d tests.", errors, test_count);
        end

        $finish;
    end

endmodule
