`timescale 1ns/1ps

module decoder3x8_tb;

    // Inputs to DUT
    reg  [2:0] in;
    reg        en;

    // Output from DUT
    wire [7:0] out;

    // Expected output
    reg [7:0] expected;

    // Testbench variables
    integer errors;
    integer test_count;
    integer i;

    // Instantiate DUT
    decoder3x8 dut (
        .in  (in),
        .en  (en),
        .out (out)
    );

    // Task to apply one test vector and check result
    task run_test;
        input [2:0] test_in;
        input       test_en;
        begin
            in = test_in;
            en = test_en;

            if (test_en == 1'b1) begin
                expected = 8'b00000001 << test_in;
            end else begin
                expected = 8'b00000000;
            end

            #1;

            test_count = test_count + 1;

            if (out !== expected) begin
                errors = errors + 1;
                $display("ERROR: test=%0d in=%b en=%b | expected=%b got=%b",
                         test_count,
                         test_in,
                         test_en,
                         expected,
                         out);
            end
        end
    endtask

    initial begin
        errors = 0;
        test_count = 0;

        $display("Starting decoder3x8 testbench...");

        // Disabled tests: all outputs should be zero
        run_test(3'b000, 1'b0);
        run_test(3'b001, 1'b0);
        run_test(3'b010, 1'b0);
        run_test(3'b011, 1'b0);
        run_test(3'b100, 1'b0);
        run_test(3'b101, 1'b0);
        run_test(3'b110, 1'b0);
        run_test(3'b111, 1'b0);

        // Enabled tests: one-hot output
        run_test(3'b000, 1'b1);
        run_test(3'b001, 1'b1);
        run_test(3'b010, 1'b1);
        run_test(3'b011, 1'b1);
        run_test(3'b100, 1'b1);
        run_test(3'b101, 1'b1);
        run_test(3'b110, 1'b1);
        run_test(3'b111, 1'b1);

        // Exhaustive loop over all inputs and enable values
        for (i = 0; i < 8; i = i + 1) begin
            run_test(i[2:0], 1'b0);
            run_test(i[2:0], 1'b1);
        end

        // Repeated toggle tests
        run_test(3'b000, 1'b1);
        run_test(3'b000, 1'b0);
        run_test(3'b111, 1'b1);
        run_test(3'b111, 1'b0);
        run_test(3'b101, 1'b1);
        run_test(3'b101, 1'b0);
        run_test(3'b010, 1'b1);
        run_test(3'b010, 1'b0);

        // Final result
        if (errors == 0) begin
            $display("PASS: All %0d tests passed.", test_count);
        end else begin
            $display("FAIL: %0d errors out of %0d tests.", errors, test_count);
        end

        $finish;
    end

endmodule
