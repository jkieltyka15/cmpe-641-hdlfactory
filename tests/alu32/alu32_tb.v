`timescale 1ns/1ps

module alu32_tb;

    // Inputs to DUT
    reg  [31:0] a;
    reg  [31:0] b;
    reg  [3:0]  op;

    // Outputs from DUT
    wire [31:0] result;
    wire        zero;
    wire        carry;
    wire        overflow;
    wire        negative;

    // Expected values
    reg [31:0] expected_result;
    reg        expected_zero;
    reg        expected_carry;
    reg        expected_overflow;
    reg        expected_negative;

    // Internal expected arithmetic values
    reg [32:0] expected_add;
    reg [32:0] expected_sub;

    // Testbench variables
    integer errors;
    integer test_count;
    integer i;

    // Instantiate DUT
    alu32 dut (
        .a        (a),
        .b        (b),
        .op       (op),
        .result   (result),
        .zero     (zero),
        .carry    (carry),
        .overflow (overflow),
        .negative (negative)
    );

    // Task to apply one test vector and check result
    task run_test;
        input [31:0] test_a;
        input [31:0] test_b;
        input [3:0]  test_op;
        begin
            a  = test_a;
            b  = test_b;
            op = test_op;

            expected_add = {1'b0, test_a} + {1'b0, test_b};
            expected_sub = {1'b0, test_a} + {1'b0, ~test_b} + 33'b1;

            case (test_op)
                4'b0000: expected_result = expected_add[31:0];
                4'b0001: expected_result = expected_sub[31:0];
                4'b0010: expected_result = test_a & test_b;
                4'b0011: expected_result = test_a | test_b;
                4'b0100: expected_result = test_a ^ test_b;
                4'b0101: expected_result = ~(test_a | test_b);
                4'b0110: expected_result = test_a << test_b[4:0];
                4'b0111: expected_result = test_a >> test_b[4:0];
                4'b1000: expected_result = $signed(test_a) >>> test_b[4:0];
                4'b1001: expected_result = ($signed(test_a) < $signed(test_b)) ? 32'h00000001 : 32'h00000000;
                4'b1010: expected_result = (test_a < test_b) ? 32'h00000001 : 32'h00000000;
                default: expected_result = 32'h00000000;
            endcase

            expected_zero     = (expected_result == 32'h00000000);
            expected_negative = expected_result[31];

            if (test_op == 4'b0000) begin
                expected_carry = expected_add[32];
                expected_overflow = ((test_a[31] == test_b[31]) &&
                                     (expected_result[31] != test_a[31]));
            end else if (test_op == 4'b0001) begin
                expected_carry = expected_sub[32];
                expected_overflow = ((test_a[31] != test_b[31]) &&
                                     (expected_result[31] != test_a[31]));
            end else begin
                expected_carry = 1'b0;
                expected_overflow = 1'b0;
            end

            #1;

            test_count = test_count + 1;

            if ((result   !== expected_result)   ||
                (zero     !== expected_zero)     ||
                (carry    !== expected_carry)    ||
                (overflow !== expected_overflow) ||
                (negative !== expected_negative)) begin

                errors = errors + 1;

                $display("ERROR: test=%0d op=%b a=%h b=%h", test_count, test_op, test_a, test_b);
                $display("       expected result=%h zero=%b carry=%b overflow=%b negative=%b",
                         expected_result,
                         expected_zero,
                         expected_carry,
                         expected_overflow,
                         expected_negative);
                $display("       got      result=%h zero=%b carry=%b overflow=%b negative=%b",
                         result,
                         zero,
                         carry,
                         overflow,
                         negative);
            end
        end
    endtask

    initial begin
        errors = 0;
        test_count = 0;

        $display("Starting alu32 testbench...");

        // ------------------------------------------------------------
        // ADD tests: op = 0000
        // ------------------------------------------------------------
        run_test(32'h00000000, 32'h00000000, 4'b0000);
        run_test(32'h00000001, 32'h00000001, 4'b0000);
        run_test(32'hFFFFFFFF, 32'h00000001, 4'b0000);
        run_test(32'hFFFFFFFF, 32'hFFFFFFFF, 4'b0000);
        run_test(32'h7FFFFFFF, 32'h00000001, 4'b0000);
        run_test(32'h80000000, 32'h80000000, 4'b0000);
        run_test(32'h12345678, 32'h87654321, 4'b0000);

        // ------------------------------------------------------------
        // SUB tests: op = 0001
        // ------------------------------------------------------------
        run_test(32'h00000000, 32'h00000000, 4'b0001);
        run_test(32'h00000005, 32'h00000003, 4'b0001);
        run_test(32'h00000003, 32'h00000005, 4'b0001);
        run_test(32'h00000000, 32'h00000001, 4'b0001);
        run_test(32'h80000000, 32'h00000001, 4'b0001);
        run_test(32'h7FFFFFFF, 32'hFFFFFFFF, 4'b0001);
        run_test(32'h12345678, 32'h00005678, 4'b0001);

        // ------------------------------------------------------------
        // AND tests: op = 0010
        // ------------------------------------------------------------
        run_test(32'hFFFFFFFF, 32'h00000000, 4'b0010);
        run_test(32'hFFFFFFFF, 32'hFFFFFFFF, 4'b0010);
        run_test(32'hAAAAAAAA, 32'h55555555, 4'b0010);
        run_test(32'h12345678, 32'h00FF00FF, 4'b0010);

        // ------------------------------------------------------------
        // OR tests: op = 0011
        // ------------------------------------------------------------
        run_test(32'hFFFFFFFF, 32'h00000000, 4'b0011);
        run_test(32'h00000000, 32'h00000000, 4'b0011);
        run_test(32'hAAAAAAAA, 32'h55555555, 4'b0011);
        run_test(32'h12345678, 32'h00FF00FF, 4'b0011);

        // ------------------------------------------------------------
        // XOR tests: op = 0100
        // ------------------------------------------------------------
        run_test(32'hFFFFFFFF, 32'hFFFFFFFF, 4'b0100);
        run_test(32'hAAAAAAAA, 32'h55555555, 4'b0100);
        run_test(32'h12345678, 32'h87654321, 4'b0100);
        run_test(32'h00000000, 32'hFFFFFFFF, 4'b0100);

        // ------------------------------------------------------------
        // NOR tests: op = 0101
        // ------------------------------------------------------------
        run_test(32'h00000000, 32'h00000000, 4'b0101);
        run_test(32'hFFFFFFFF, 32'h00000000, 4'b0101);
        run_test(32'hAAAAAAAA, 32'h55555555, 4'b0101);
        run_test(32'h12345678, 32'h87654321, 4'b0101);

        // ------------------------------------------------------------
        // SLL tests: op = 0110
        // ------------------------------------------------------------
        run_test(32'h00000001, 32'h00000000, 4'b0110);
        run_test(32'h00000001, 32'h00000001, 4'b0110);
        run_test(32'h00000001, 32'h0000001F, 4'b0110);
        run_test(32'h80000000, 32'h00000001, 4'b0110);
        run_test(32'h12345678, 32'h00000004, 4'b0110);

        // ------------------------------------------------------------
        // SRL tests: op = 0111
        // ------------------------------------------------------------
        run_test(32'h80000000, 32'h00000000, 4'b0111);
        run_test(32'h80000000, 32'h00000001, 4'b0111);
        run_test(32'h80000000, 32'h0000001F, 4'b0111);
        run_test(32'h12345678, 32'h00000004, 4'b0111);
        run_test(32'hFFFFFFFF, 32'h00000008, 4'b0111);

        // ------------------------------------------------------------
        // SRA tests: op = 1000
        // ------------------------------------------------------------
        run_test(32'h80000000, 32'h00000000, 4'b1000);
        run_test(32'h80000000, 32'h00000001, 4'b1000);
        run_test(32'h80000000, 32'h0000001F, 4'b1000);
        run_test(32'h7FFFFFFF, 32'h00000001, 4'b1000);
        run_test(32'hFFFFFFFF, 32'h00000004, 4'b1000);

        // ------------------------------------------------------------
        // SLT signed tests: op = 1001
        // ------------------------------------------------------------
        run_test(32'h00000001, 32'h00000002, 4'b1001);
        run_test(32'h00000002, 32'h00000001, 4'b1001);
        run_test(32'hFFFFFFFF, 32'h00000001, 4'b1001); // -1 < 1
        run_test(32'h00000001, 32'hFFFFFFFF, 4'b1001); // 1 < -1 false
        run_test(32'h80000000, 32'h7FFFFFFF, 4'b1001);

        // ------------------------------------------------------------
        // SLTU unsigned tests: op = 1010
        // ------------------------------------------------------------
        run_test(32'h00000001, 32'h00000002, 4'b1010);
        run_test(32'h00000002, 32'h00000001, 4'b1010);
        run_test(32'hFFFFFFFF, 32'h00000001, 4'b1010);
        run_test(32'h00000001, 32'hFFFFFFFF, 4'b1010);
        run_test(32'h80000000, 32'h7FFFFFFF, 4'b1010);

        // ------------------------------------------------------------
        // Invalid/default op tests
        // ------------------------------------------------------------
        run_test(32'hFFFFFFFF, 32'hFFFFFFFF, 4'b1011);
        run_test(32'h12345678, 32'h87654321, 4'b1100);
        run_test(32'hAAAAAAAA, 32'h55555555, 4'b1101);
        run_test(32'h00000001, 32'h00000002, 4'b1110);
        run_test(32'hDEADBEEF, 32'hCAFEBABE, 4'b1111);

        // ------------------------------------------------------------
        // Random tests for all op values
        // ------------------------------------------------------------
        for (i = 0; i < 1000; i = i + 1) begin
            run_test($random, $random, 4'b0000);
            run_test($random, $random, 4'b0001);
            run_test($random, $random, 4'b0010);
            run_test($random, $random, 4'b0011);
            run_test($random, $random, 4'b0100);
            run_test($random, $random, 4'b0101);
            run_test($random, $random, 4'b0110);
            run_test($random, $random, 4'b0111);
            run_test($random, $random, 4'b1000);
            run_test($random, $random, 4'b1001);
            run_test($random, $random, 4'b1010);
            run_test($random, $random, 4'b1011);
            run_test($random, $random, 4'b1100);
            run_test($random, $random, 4'b1101);
            run_test($random, $random, 4'b1110);
            run_test($random, $random, 4'b1111);
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
