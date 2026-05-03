module alu32 (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,
    output wire [31:0] result,
    output wire        zero,
    output wire        carry,
    output wire        overflow,
    output wire        negative
);

wire [32:0] add_result;
wire [32:0] sub_result;
wire [31:0] add_out;
wire [31:0] sub_out;
wire [31:0] and_out;
wire [31:0] or_out;
wire [31:0] xor_out;
wire [31:0] nor_out;
wire [31:0] sll_out;
wire [31:0] srl_out;
wire [31:0] sra_out;
wire [31:0] slt_out;
wire [31:0] sltu_out;

assign add_result = {1'b0, a} + {1'b0, b};
assign sub_result = {1'b0, a} + {1'b0, ~b} + 33'b1;
assign add_out  = add_result[31:0];
assign sub_out  = sub_result[31:0];
assign and_out  = a & b;
assign or_out   = a | b;
assign xor_out  = a ^ b;
assign nor_out  = ~(a | b);
assign sll_out  = a << b[4:0];
assign srl_out  = a >> b[4:0];
assign sra_out  = $signed(a) >>> b[4:0];
assign slt_out  = ($signed(a) < $signed(b)) ? 32'h00000001 : 32'h00000000;
assign sltu_out = (a < b) ? 32'h00000001 : 32'h00000000;

assign result = (op == 4'b0000) ? add_out  :
                (op == 4'b0001) ? sub_out  :
                (op == 4'b0010) ? and_out  :
                (op == 4'b0011) ? or_out   :
                (op == 4'b0100) ? xor_out  :
                (op == 4'b0101) ? nor_out  :
                (op == 4'b0110) ? sll_out  :
                (op == 4'b0111) ? srl_out  :
                (op == 4'b1000) ? sra_out  :
                (op == 4'b1001) ? slt_out  :
                (op == 4'b1010) ? sltu_out : 32'h00000000;

assign zero = (result == 32'h00000000);
assign negative = result[31];
assign carry = (op == 4'b0000) ? add_result[32] :
               (op == 4'b0001) ? sub_result[32] : 1'b0;
assign overflow = (op == 4'b0000) ? ((a[31] == b[31]) && (result[31] != a[31])) :
                  (op == 4'b0001) ? ((a[31] != b[31]) && (result[31] != a[31])) : 1'b0;

endmodule
