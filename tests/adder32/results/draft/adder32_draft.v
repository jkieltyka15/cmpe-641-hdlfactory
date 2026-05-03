module adder32 (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        cin,
    output wire [31:0] sum,
    output wire        cout
);
    wire [32:0] result;
    assign result = {1'b0, a} + {1'b0, b} + {32'b0, cin};
    assign sum = result[31:0];
    assign cout = result[32];
endmodule
