`timescale 1ns/1ps

module adder32_tb;

    // Inputs to DUT
    reg  [31:0] a;
    reg  [31:0] b;
    reg         cin;

    // Outputs from DUT
    wire [31:0] sum;
    wire        cout;

    // Expected result
    reg [32:0] expected;

    // Testbench variables
    integer errors;
    integer test_count;
    integer i;
    reg random_cin;

    // Instantiate the DUT
    adder32 dut (
        .a    (a),
        .b    (b),
        .cin  (cin),
        .sum  (sum),
        .cout (cout)
    );

    // Task to apply one test vector and check the result
    task run_test;
        input [31:0] test_a;
        input [31:0] test_b;
        input        test_cin;
        begin
            a   = test_a;
            b   = test_b;
            cin = test_cin;

            // Explicitly extend all operands to 33 bits
            expected = {1'b0, test_a} + {1'b0, test_b} + {32'b0, test_cin};

            #1;

            test_count = test_count + 1;

            if ({cout, sum} !== expected) begin
                errors = errors + 1;
                $display("ERROR: test=%0d a=%h b=%h cin=%b | expected cout=%b sum=%h | got cout=%b sum=%h",
                         test_count,
                         test_a,
                         test_b,
                         test_cin,
                         expected[32],
                         expected[31:0],
                         cout,
                         sum);
            end
        end
    endtask

    initial begin
        errors = 0;
        test_count = 0;

        $display("Starting adder32 testbench...");

        // Basic tests
        run_test(32'h00000000, 32'h00000000, 1'b0);
        run_test(32'h00000000, 32'h00000000, 1'b1);
        run_test(32'h00000001, 32'h00000001, 1'b0);
        run_test(32'h00000001, 32'h00000001, 1'b1);

        // Carry generation tests
        run_test(32'hFFFFFFFF, 32'h00000000, 1'b0);
        run_test(32'hFFFFFFFF, 32'h00000000, 1'b1);
        run_test(32'hFFFFFFFF, 32'h00000001, 1'b0);
        run_test(32'hFFFFFFFF, 32'h00000001, 1'b1);

        // Overflow and boundary tests
        run_test(32'h0000FFFF, 32'h00000001, 1'b0);
        run_test(32'h00FFFFFF, 32'h00000001, 1'b0);
        run_test(32'h7FFFFFFF, 32'h00000001, 1'b0);
        run_test(32'h80000000, 32'h80000000, 1'b0);
        run_test(32'hFFFFFFFF, 32'hFFFFFFFF, 1'b0);
        run_test(32'hFFFFFFFF, 32'hFFFFFFFF, 1'b1);

        // Pattern tests
        run_test(32'hAAAAAAAA, 32'h55555555, 1'b0);
        run_test(32'hAAAAAAAA, 32'h55555555, 1'b1);
        run_test(32'h12345678, 32'h87654321, 1'b0);
        run_test(32'h12345678, 32'h87654321, 1'b1);
        run_test(32'hDEADBEEF, 32'hCAFEBABE, 1'b0);
        run_test(32'hDEADBEEF, 32'hCAFEBABE, 1'b1);

        // Walking 1s on a
        for (i = 0; i < 32; i = i + 1) begin
            run_test(32'h00000001 << i, 32'h00000000, 1'b0);
            run_test(32'h00000001 << i, 32'h00000000, 1'b1);
        end

        // Walking 1s on b
        for (i = 0; i < 32; i = i + 1) begin
            run_test(32'h00000000, 32'h00000001 << i, 1'b0);
            run_test(32'h00000000, 32'h00000001 << i, 1'b1);
        end

        // Carry propagation tests
        for (i = 0; i < 32; i = i + 1) begin
            run_test((32'h00000001 << i) - 1, 32'h00000001, 1'b0);
            run_test((32'h00000001 << i) - 1, 32'h00000001, 1'b1);
        end

        // Random tests
        for (i = 0; i < 1000; i = i + 1) begin
            random_cin = ($random != 0);
            run_test($random, $random, random_cin);
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