`timescale 1ns / 1ps
//
// MIT License
// 
// Copyright (c) 2020 Eric Pearson
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), 
// to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, 
// and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice (including the next paragraph) shall be included in all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS 
// IN THE SOFTWARE.
//

// Decode process a transform block
// Input: bitstream, block predictor, qpy,  and block index
// Output: recon, bitcount
module gg_iprocess
   #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
    )
    (
    input  logic clk,
    input  logic [0:15][11:0]  pred,
    output logic [0:15][7:0]   recon,
    input  logic [5:0] qpy,
    input  logic [2:0] cidx, // cidx={0-luma, 1-acluma, 2-cb, 3-cr, 4-dccb, 5-dccr, 6-dcy}
    input  logic [3:0] bidx, // block IDX in h264 order
    output logic [8:0] bitcount, // bitcount to code block
    input  logic [511:0] bits, // input bits (max 501
    input  logic [8:0] start_ofs, // start position of the bits
    output logic [4:0] num_coeff, // Count of non-zero block coeffs
    input  logic abv_out_of_pic,
    input  logic left_out_of_pic,
    output logic [6:0] overflow,
    output logic [4:0] error,
    // State I/O for external dc hold regs
    input  logic [15:0][15:0] dc_hold,
    output logic [15:0][15:0] dc_hold_dout,
    // State I/O for external neighbour nC Regs
    input  logic [0:3][7:0] above_nc_y,
    input  logic [0:1][7:0] above_nc_cb,
    input  logic [0:1][7:0] above_nc_cr,
    input  logic [0:3][7:0] left_nc_y,
    input  logic [0:1][7:0] left_nc_cb,
    input  logic [0:1][7:0] left_nc_cr,
    output logic [0:3][7:0] below_nc_y,
    output logic [0:1][7:0] below_nc_cb,
    output logic [0:1][7:0] below_nc_cr,
    output logic [0:3][7:0] right_nc_y,
    output logic [0:1][7:0] right_nc_cb,
    output logic [0:1][7:0] right_nc_cr
    );


    // Flags
	wire dc_flag = ( cidx[2:0] == 4 || cidx[2:0] == 5 || cidx[2:0] == 6) ? 1'b1 : 1'b0;
	wire ac_flag = ( cidx[2:0] == 1 || cidx[2:0] == 2 || cidx[2:0] == 3) ? 1'b1 : 1'b0;
	wire ch_flag = ( cidx[2:0] == 2 || cidx[2:0] == 3 || cidx[2:0] == 4 || cidx[2:0] == 5) ? 1'b1 :1'b 0;    
	wire cb_flag = ( cidx[2:0] == 2 || cidx[2:0] == 4 ) ? 1'b1 : 1'b0;
	wire cr_flag = ( cidx[2:0] == 3 || cidx[2:0] == 5 ) ? 1'b1 : 1'b0;
	wire y_flag  = ( cidx[2:0] == 0 || cidx[2:0] == 1 || cidx[2:0] == 6 ) ? 1'b1 : 1'b0;
	
	logic [8:0] coeff_token_len;
	logic [8:0] coeff_len[16];
	logic [8:0] total_zeros_len;
	logic [8:0] run_before_len[14];
	
	logic [8:0] coeff_token_ofs;
	logic [8:0] coeff_ofs[16];
	logic [8:0] total_zeros_ofs;
	logic [8:0] run_before_ofs[14];

	logic [31:0] coeff_token_bitword;
	logic [31:0] coeff_bitword[16];
	logic [31:0] total_zeros_bitword;
	logic [31:0] run_before_bitword[14];
	

	// Barrel Shifters for input bitword selection

	vld_shift_512 #( 16 ) _vshift_00 ( .in( bits ), .sel( coeff_token_ofs    ), .out( coeff_token_bitword    ) );
	vld_shift_512 #( 28 ) _vshift_01 ( .in( bits ), .sel( coeff_ofs[ 0]      ), .out( coeff_bitword[ 0]      ) );
	vld_shift_512 #( 28 ) _vshift_02 ( .in( bits ), .sel( coeff_ofs[ 1]      ), .out( coeff_bitword[ 1]      ) );
	vld_shift_512 #( 28 ) _vshift_03 ( .in( bits ), .sel( coeff_ofs[ 2]      ), .out( coeff_bitword[ 2]      ) );
	vld_shift_512 #( 28 ) _vshift_04 ( .in( bits ), .sel( coeff_ofs[ 3]      ), .out( coeff_bitword[ 3]      ) );
	vld_shift_512 #( 28 ) _vshift_05 ( .in( bits ), .sel( coeff_ofs[ 4]      ), .out( coeff_bitword[ 4]      ) );
	vld_shift_512 #( 28 ) _vshift_06 ( .in( bits ), .sel( coeff_ofs[ 5]      ), .out( coeff_bitword[ 5]      ) );
	vld_shift_512 #( 28 ) _vshift_07 ( .in( bits ), .sel( coeff_ofs[ 6]      ), .out( coeff_bitword[ 6]      ) );
	vld_shift_512 #( 28 ) _vshift_08 ( .in( bits ), .sel( coeff_ofs[ 7]      ), .out( coeff_bitword[ 7]      ) );
	vld_shift_512 #( 28 ) _vshift_09 ( .in( bits ), .sel( coeff_ofs[ 8]      ), .out( coeff_bitword[ 8]      ) );
	vld_shift_512 #( 28 ) _vshift_10 ( .in( bits ), .sel( coeff_ofs[ 9]      ), .out( coeff_bitword[ 9]      ) );
	vld_shift_512 #( 28 ) _vshift_11 ( .in( bits ), .sel( coeff_ofs[10]      ), .out( coeff_bitword[10]      ) );
	vld_shift_512 #( 28 ) _vshift_12 ( .in( bits ), .sel( coeff_ofs[11]      ), .out( coeff_bitword[11]      ) );
	vld_shift_512 #( 28 ) _vshift_13 ( .in( bits ), .sel( coeff_ofs[12]      ), .out( coeff_bitword[12]      ) );
	vld_shift_512 #( 28 ) _vshift_14 ( .in( bits ), .sel( coeff_ofs[13]      ), .out( coeff_bitword[13]      ) );
	vld_shift_512 #( 28 ) _vshift_15 ( .in( bits ), .sel( coeff_ofs[14]      ), .out( coeff_bitword[14]      ) );
	vld_shift_512 #( 28 ) _vshift_16 ( .in( bits ), .sel( coeff_ofs[15]      ), .out( coeff_bitword[15]      ) );
	vld_shift_512 #(  9 ) _vshift_17 ( .in( bits ), .sel( total_zeros_ofs    ), .out( total_zeros_bitword    ) );
    vld_shift_512 #( 28 ) _vshift_18 ( .in( bits ), .sel( run_before_ofs[ 0] ), .out( run_before_bitword[ 0] ) );
	vld_shift_512 #( 28 ) _vshift_19 ( .in( bits ), .sel( run_before_ofs[ 1] ), .out( run_before_bitword[ 1] ) );
	vld_shift_512 #( 28 ) _vshift_20 ( .in( bits ), .sel( run_before_ofs[ 2] ), .out( run_before_bitword[ 2] ) );
	vld_shift_512 #( 28 ) _vshift_21 ( .in( bits ), .sel( run_before_ofs[ 3] ), .out( run_before_bitword[ 3] ) );
	vld_shift_512 #( 28 ) _vshift_22 ( .in( bits ), .sel( run_before_ofs[ 4] ), .out( run_before_bitword[ 4] ) );
	vld_shift_512 #( 28 ) _vshift_23 ( .in( bits ), .sel( run_before_ofs[ 5] ), .out( run_before_bitword[ 5] ) );
	vld_shift_512 #( 28 ) _vshift_24 ( .in( bits ), .sel( run_before_ofs[ 6] ), .out( run_before_bitword[ 6] ) );
	vld_shift_512 #( 28 ) _vshift_25 ( .in( bits ), .sel( run_before_ofs[ 7] ), .out( run_before_bitword[ 7] ) );
	vld_shift_512 #( 28 ) _vshift_26 ( .in( bits ), .sel( run_before_ofs[ 8] ), .out( run_before_bitword[ 8] ) );
	vld_shift_512 #( 28 ) _vshift_27 ( .in( bits ), .sel( run_before_ofs[ 9] ), .out( run_before_bitword[ 9] ) );
	vld_shift_512 #( 28 ) _vshift_28 ( .in( bits ), .sel( run_before_ofs[10] ), .out( run_before_bitword[10] ) );
	vld_shift_512 #( 28 ) _vshift_29 ( .in( bits ), .sel( run_before_ofs[11] ), .out( run_before_bitword[11] ) );
	vld_shift_512 #( 28 ) _vshift_30 ( .in( bits ), .sel( run_before_ofs[12] ), .out( run_before_bitword[12] ) );
	vld_shift_512 #( 28 ) _vshift_31 ( .in( bits ), .sel( run_before_ofs[13] ), .out( run_before_bitword[13] ) );
	
	// Calculate the offsets (TODO: adder trees)
	
	assign coeff_token_ofs    = start_ofs;
    assign coeff_ofs[ 0]      = coeff_token_ofs    + coeff_token_len    ;	
    assign coeff_ofs[ 1]      = coeff_ofs[ 0]      + coeff_len[ 0]      ;
    assign coeff_ofs[ 2]      = coeff_ofs[ 1]      + coeff_len[ 1]      ;
    assign coeff_ofs[ 3]      = coeff_ofs[ 2]      + coeff_len[ 2]      ;
    assign coeff_ofs[ 4]      = coeff_ofs[ 3]      + coeff_len[ 3]      ;
    assign coeff_ofs[ 5]      = coeff_ofs[ 4]      + coeff_len[ 4]      ;
    assign coeff_ofs[ 6]      = coeff_ofs[ 5]      + coeff_len[ 5]      ;
    assign coeff_ofs[ 7]      = coeff_ofs[ 6]      + coeff_len[ 6]      ;
    assign coeff_ofs[ 8]      = coeff_ofs[ 7]      + coeff_len[ 7]      ;
    assign coeff_ofs[ 9]      = coeff_ofs[ 8]      + coeff_len[ 8]      ;
    assign coeff_ofs[10]      = coeff_ofs[ 9]      + coeff_len[ 9]      ;
    assign coeff_ofs[11]      = coeff_ofs[10]      + coeff_len[10]      ;
    assign coeff_ofs[12]      = coeff_ofs[11]      + coeff_len[11]      ;
    assign coeff_ofs[13]      = coeff_ofs[12]      + coeff_len[12]      ;
    assign coeff_ofs[14]      = coeff_ofs[13]      + coeff_len[13]      ;
    assign coeff_ofs[15]      = coeff_ofs[14]      + coeff_len[14]      ;
    assign total_zeros_ofs    = coeff_ofs[15]      + coeff_len[15]      ;
    assign run_before_ofs[ 0] = total_zeros_ofs    + total_zeros_len    ;
    assign run_before_ofs[ 1] = run_before_ofs[ 0] + run_before_len[ 0] ;
    assign run_before_ofs[ 2] = run_before_ofs[ 1] + run_before_len[ 1] ;
    assign run_before_ofs[ 3] = run_before_ofs[ 2] + run_before_len[ 2] ;
    assign run_before_ofs[ 4] = run_before_ofs[ 3] + run_before_len[ 3] ;
    assign run_before_ofs[ 5] = run_before_ofs[ 4] + run_before_len[ 4] ;
    assign run_before_ofs[ 6] = run_before_ofs[ 5] + run_before_len[ 5] ;
    assign run_before_ofs[ 7] = run_before_ofs[ 6] + run_before_len[ 6] ;
    assign run_before_ofs[ 8] = run_before_ofs[ 7] + run_before_len[ 7] ;
    assign run_before_ofs[ 9] = run_before_ofs[ 8] + run_before_len[ 8] ;
    assign run_before_ofs[10] = run_before_ofs[ 9] + run_before_len[ 9] ;
    assign run_before_ofs[11] = run_before_ofs[10] + run_before_len[10] ;
    assign run_before_ofs[12] = run_before_ofs[11] + run_before_len[11] ;
    assign run_before_ofs[13] = run_before_ofs[12] + run_before_len[12] ;
    assign bitcount           = run_before_ofs[13] + run_before_len[13] ;
     
    //////////////////////////////
    // coeff_token
    //////////////////////////////

    // determine coeff token table to parse with
    logic [2:0] coeff_idx;
    logic [7:0] na, nb;
    logic [4:0] nc;
    logic [5:0] nab;
    
    assign na = ( cb_flag && dc_flag ) ? left_nc_cb[0] :
                ( cr_flag && dc_flag ) ? left_nc_cr[0] :
                (  y_flag && dc_flag ) ? left_nc_y[0] :
                ( cb_flag            ) ? left_nc_cb[ bidx[1] ] :
                ( cr_flag            ) ? left_nc_cr[ bidx[1] ] :
                                         left_nc_y[ { bidx[3], bidx[1] } ];
                              
    assign nb = ( cb_flag && dc_flag  ) ? above_nc_cb[0] : // DC always before AC, use external above
                ( cr_flag && dc_flag  ) ? above_nc_cr[0] :
                (  y_flag && dc_flag  ) ? above_nc_y[ 0] :
                ( cb_flag             ) ? above_nc_cb[ bidx[0] ] :
                ( cr_flag             ) ? above_nc_cr[ bidx[0] ] :
                                          above_nc_y[ { bidx[2], bidx[0] } ];

    assign nab[5:0] = { 1'b0, na[4:0] } + { 1'b0, nb[4:0] } + 6'd1;
    
    assign nc = ( left_out_of_pic && abv_out_of_pic && bidx == 0 ) ? 5'd0 :
                ( left_out_of_pic && ( bidx == 0 || bidx == 2 || bidx == 8 || bidx == 10 ) ) ? nb[4:0] :
                ( abv_out_of_pic  && ( bidx == 0 || bidx == 1 || bidx == 4 || bidx == 5  ) ) ? na[4:0] : nab[5:1];
    
    assign coeff_idx = ( ch_flag && dc_flag ) ? 3'd4 :
                       ( |nc[4:3]           ) ? 3'd3 : // nc >= 8
                       ( nc[2]              ) ? 3'd2 : // 4 <= nc < 8
                       ( nc[1]              ) ? 3'd1 : // 2 <= nc < 4
                                                3'd0 ; // 0 <= nc < 2                                                
    logic [1:0] trailing_ones;
    
    always_comb begin 
        trailing_ones[1:0] = 2'd0;
        num_coeff[4:0] = 5'd0;
        coeff_token_len[8:0] = 9'd0;
        unique0 casez( { coeff_idx[2:0], coeff_token_bitword[31:16] } )
            // idx = 0
            { 3'd0, 16'b1??????????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd0 , 5'd1 };
            { 3'd0, 16'b000101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd1 , 5'd6 };
            { 3'd0, 16'b01?????????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd1 , 5'd2 };
            { 3'd0, 16'b00000111???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd2 , 5'd8 };
            { 3'd0, 16'b000100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd2 , 5'd6 };
            { 3'd0, 16'b001????????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd2 , 5'd3 };
            { 3'd0, 16'b000000111??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd3 , 5'd9 };
            { 3'd0, 16'b00000110???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd3 , 5'd8 };
            { 3'd0, 16'b0000101????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd3 , 5'd7 };
            { 3'd0, 16'b00011??????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd3 , 5'd5 };
            { 3'd0, 16'b0000000111?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd4 , 5'd10 };
            { 3'd0, 16'b000000110??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd4 , 5'd9 };
            { 3'd0, 16'b00000101???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd4 , 5'd8 };
            { 3'd0, 16'b000011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd4 , 5'd6 };
            { 3'd0, 16'b00000000111????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd5 , 5'd11 };
            { 3'd0, 16'b0000000110?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd5 , 5'd10 };
            { 3'd0, 16'b000000101??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd5 , 5'd9 };
            { 3'd0, 16'b0000100????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd5 , 5'd7 };
            { 3'd0, 16'b0000000001111??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd6 , 5'd13 };
            { 3'd0, 16'b00000000110????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd6 , 5'd11 };
            { 3'd0, 16'b0000000101?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd6 , 5'd10 };
            { 3'd0, 16'b00000100???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd6 , 5'd8 };
            { 3'd0, 16'b0000000001011??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd7 , 5'd13 };
            { 3'd0, 16'b0000000001110??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd7 , 5'd13 };
            { 3'd0, 16'b00000000101????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd7 , 5'd11 };
            { 3'd0, 16'b000000100??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd7 , 5'd9 };
            { 3'd0, 16'b0000000001000??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd8 , 5'd13 };
            { 3'd0, 16'b0000000001010??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd8 , 5'd13 };
            { 3'd0, 16'b0000000001101??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd8 , 5'd13 };
            { 3'd0, 16'b0000000100?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd8 , 5'd10 };
            { 3'd0, 16'b00000000001111?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd9 , 5'd14 };
            { 3'd0, 16'b00000000001110?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd9 , 5'd14 };
            { 3'd0, 16'b0000000001001??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd9 , 5'd13 };
            { 3'd0, 16'b00000000100????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd9 , 5'd11 };
            { 3'd0, 16'b00000000001011?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd10, 5'd14 };
            { 3'd0, 16'b00000000001010?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd10, 5'd14 };
            { 3'd0, 16'b00000000001101?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd10, 5'd14 };
            { 3'd0, 16'b0000000001100??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd10, 5'd13 };
            { 3'd0, 16'b000000000001111? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd11, 5'd15 };
            { 3'd0, 16'b000000000001110? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd11, 5'd15 };
            { 3'd0, 16'b00000000001001?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd11, 5'd14 };
            { 3'd0, 16'b00000000001100?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd11, 5'd14 };
            { 3'd0, 16'b000000000001011? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd12, 5'd15 };
            { 3'd0, 16'b000000000001010? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd12, 5'd15 };
            { 3'd0, 16'b000000000001101? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd12, 5'd15 };
            { 3'd0, 16'b00000000001000?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd12, 5'd14 };
            { 3'd0, 16'b0000000000001111 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd13, 5'd16 };
            { 3'd0, 16'b000000000000001? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd13, 5'd15 };
            { 3'd0, 16'b000000000001001? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd13, 5'd15 };
            { 3'd0, 16'b000000000001100? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd13, 5'd15 };
            { 3'd0, 16'b0000000000001011 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd14, 5'd16 };
            { 3'd0, 16'b0000000000001110 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd14, 5'd16 };
            { 3'd0, 16'b0000000000001101 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd14, 5'd16 };
            { 3'd0, 16'b000000000001000? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd14, 5'd15 };
            { 3'd0, 16'b0000000000000111 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd15, 5'd16 };
            { 3'd0, 16'b0000000000001010 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd15, 5'd16 };
            { 3'd0, 16'b0000000000001001 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd15, 5'd16 };
            { 3'd0, 16'b0000000000001100 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd15, 5'd16 };
            { 3'd0, 16'b0000000000000100 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd16, 5'd16 };
            { 3'd0, 16'b0000000000000110 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd16, 5'd16 };
            { 3'd0, 16'b0000000000000101 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd16, 5'd16 };
            { 3'd0, 16'b0000000000001000 } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd16, 5'd16 };
            // idx = 1
            { 3'd1, 16'b11?????????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd0 , 5'd2 };
            { 3'd1, 16'b001011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd1 , 5'd6 };
            { 3'd1, 16'b10?????????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd1 , 5'd2 };
            { 3'd1, 16'b000111?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd2 , 5'd6 };
            { 3'd1, 16'b00111??????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd2 , 5'd5 };
            { 3'd1, 16'b011????????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd2 , 5'd3 };
            { 3'd1, 16'b0000111????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd3 , 5'd7 };
            { 3'd1, 16'b001010?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd3 , 5'd6 };
            { 3'd1, 16'b001001?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd3 , 5'd6 };
            { 3'd1, 16'b0101???????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd3 , 5'd4 };
            { 3'd1, 16'b00000111???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd4 , 5'd8 };
            { 3'd1, 16'b000110?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd4 , 5'd6 };
            { 3'd1, 16'b000101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd4 , 5'd6 };
            { 3'd1, 16'b0100???????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd4 , 5'd4 };
            { 3'd1, 16'b00000100???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd5 , 5'd8 };
            { 3'd1, 16'b0000110????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd5 , 5'd7 };
            { 3'd1, 16'b0000101????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd5 , 5'd7 };
            { 3'd1, 16'b00110??????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd5 , 5'd5 };
            { 3'd1, 16'b000000111??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd6 , 5'd9 };
            { 3'd1, 16'b00000110???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd6 , 5'd8 };
            { 3'd1, 16'b00000101???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd6 , 5'd8 };
            { 3'd1, 16'b001000?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd6 , 5'd6 };
            { 3'd1, 16'b00000001111????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd7 , 5'd11 };
            { 3'd1, 16'b000000110??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd7 , 5'd9 };
            { 3'd1, 16'b000000101??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd7 , 5'd9 };
            { 3'd1, 16'b000100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd7 , 5'd6 };
            { 3'd1, 16'b00000001011????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd8 , 5'd11 };
            { 3'd1, 16'b00000001110????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd8 , 5'd11 };
            { 3'd1, 16'b00000001101????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd8 , 5'd11 };
            { 3'd1, 16'b0000100????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd8 , 5'd7 };
            { 3'd1, 16'b000000001111???? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd9 , 5'd12 };
            { 3'd1, 16'b00000001010????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd9 , 5'd11 };
            { 3'd1, 16'b00000001001????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd9 , 5'd11 };
            { 3'd1, 16'b000000100??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd9 , 5'd9 };
            { 3'd1, 16'b000000001011???? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd10, 5'd12 };
            { 3'd1, 16'b000000001110???? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd10, 5'd12 };
            { 3'd1, 16'b000000001101???? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd10, 5'd12 };
            { 3'd1, 16'b00000001100????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd10, 5'd11 };
            { 3'd1, 16'b000000001000???? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd11, 5'd12 };
            { 3'd1, 16'b000000001010???? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd11, 5'd12 };
            { 3'd1, 16'b000000001001???? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd11, 5'd12 };
            { 3'd1, 16'b00000001000????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd11, 5'd11 };
            { 3'd1, 16'b0000000001111??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd12, 5'd13 };
            { 3'd1, 16'b0000000001110??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd12, 5'd13 };
            { 3'd1, 16'b0000000001101??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd12, 5'd13 };
            { 3'd1, 16'b000000001100???? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd12, 5'd12 };
            { 3'd1, 16'b0000000001011??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd13, 5'd13 };
            { 3'd1, 16'b0000000001010??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd13, 5'd13 };
            { 3'd1, 16'b0000000001001??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd13, 5'd13 };
            { 3'd1, 16'b0000000001100??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd13, 5'd13 };
            { 3'd1, 16'b0000000000111??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd14, 5'd13 };
            { 3'd1, 16'b00000000001011?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd14, 5'd14 };
            { 3'd1, 16'b0000000000110??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd14, 5'd13 };
            { 3'd1, 16'b0000000001000??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd14, 5'd13 };
            { 3'd1, 16'b00000000001001?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd15, 5'd14 };
            { 3'd1, 16'b00000000001000?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd15, 5'd14 };
            { 3'd1, 16'b00000000001010?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd15, 5'd14 };
            { 3'd1, 16'b0000000000001??? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd15, 5'd13 };
            { 3'd1, 16'b00000000000111?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd16, 5'd14 };
            { 3'd1, 16'b00000000000110?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd16, 5'd14 };
            { 3'd1, 16'b00000000000101?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd16, 5'd14 };
            { 3'd1, 16'b00000000000100?? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd16, 5'd14 };
            // idx = 2
            { 3'd2, 16'b1111???????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd0 , 5'd4 };
            { 3'd2, 16'b001111?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd1 , 5'd6 };
            { 3'd2, 16'b1110???????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd1 , 5'd4 };
            { 3'd2, 16'b001011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd2 , 5'd6 };
            { 3'd2, 16'b01111??????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd2 , 5'd5 };
            { 3'd2, 16'b1101???????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd2 , 5'd4 };
            { 3'd2, 16'b001000?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd3 , 5'd6 };
            { 3'd2, 16'b01100??????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd3 , 5'd5 };
            { 3'd2, 16'b01110??????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd3 , 5'd5 };
            { 3'd2, 16'b1100???????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd3 , 5'd4 };
            { 3'd2, 16'b0001111????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd4 , 5'd7 };
            { 3'd2, 16'b01010??????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd4 , 5'd5 };
            { 3'd2, 16'b01011??????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd4 , 5'd5 };
            { 3'd2, 16'b1011???????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd4 , 5'd4 };
            { 3'd2, 16'b0001011????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd5 , 5'd7 };
            { 3'd2, 16'b01000??????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd5 , 5'd5 };
            { 3'd2, 16'b01001??????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd5 , 5'd5 };
            { 3'd2, 16'b1010???????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd5 , 5'd4 };
            { 3'd2, 16'b0001001????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd6 , 5'd7 };
            { 3'd2, 16'b001110?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd6 , 5'd6 };
            { 3'd2, 16'b001101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd6 , 5'd6 };
            { 3'd2, 16'b1001???????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd6 , 5'd4 };
            { 3'd2, 16'b0001000????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd7 , 5'd7 };
            { 3'd2, 16'b001010?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd7 , 5'd6 };
            { 3'd2, 16'b001001?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd7 , 5'd6 };
            { 3'd2, 16'b1000???????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd7 , 5'd4 };
            { 3'd2, 16'b00001111???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd8 , 5'd8 };
            { 3'd2, 16'b0001110????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd8 , 5'd7 };
            { 3'd2, 16'b0001101????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd8 , 5'd7 };
            { 3'd2, 16'b01101??????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd8 , 5'd5 };
            { 3'd2, 16'b00001011???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd9 , 5'd8 };
            { 3'd2, 16'b00001110???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd9 , 5'd8 };
            { 3'd2, 16'b0001010????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd9 , 5'd7 };
            { 3'd2, 16'b001100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd9 , 5'd6 };
            { 3'd2, 16'b000001111??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd10, 5'd9 };
            { 3'd2, 16'b00001010???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd10, 5'd8 };
            { 3'd2, 16'b00001101???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd10, 5'd8 };
            { 3'd2, 16'b0001100????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd10, 5'd7 };
            { 3'd2, 16'b000001011??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd11, 5'd9 };
            { 3'd2, 16'b000001110??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd11, 5'd9 };
            { 3'd2, 16'b00001001???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd11, 5'd8 };
            { 3'd2, 16'b00001100???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd11, 5'd8 };
            { 3'd2, 16'b000001000??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd12, 5'd9 };
            { 3'd2, 16'b000001010??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd12, 5'd9 };
            { 3'd2, 16'b000001101??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd12, 5'd9 };
            { 3'd2, 16'b00001000???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd12, 5'd8 };
            { 3'd2, 16'b0000001101?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd13, 5'd10 };
            { 3'd2, 16'b000000111??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd13, 5'd9 };
            { 3'd2, 16'b000001001??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd13, 5'd9 };
            { 3'd2, 16'b000001100??????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd13, 5'd9 };
            { 3'd2, 16'b0000001001?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd14, 5'd10 };
            { 3'd2, 16'b0000001100?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd14, 5'd10 };
            { 3'd2, 16'b0000001011?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd14, 5'd10 };
            { 3'd2, 16'b0000001010?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd14, 5'd10 };
            { 3'd2, 16'b0000000101?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd15, 5'd10 };
            { 3'd2, 16'b0000001000?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd15, 5'd10 };
            { 3'd2, 16'b0000000111?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd15, 5'd10 };
            { 3'd2, 16'b0000000110?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd15, 5'd10 };
            { 3'd2, 16'b0000000001?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd16, 5'd10 };
            { 3'd2, 16'b0000000100?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd16, 5'd10 };
            { 3'd2, 16'b0000000011?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd16, 5'd10 };
            { 3'd2, 16'b0000000010?????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd16, 5'd10 };
            // idx = 3
            { 3'd3, 16'b000011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd0 , 5'd6 };
            { 3'd3, 16'b000000?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd1 , 5'd6 };
            { 3'd3, 16'b000001?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd1 , 5'd6 };
            { 3'd3, 16'b000100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd2 , 5'd6 };
            { 3'd3, 16'b000101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd2 , 5'd6 };
            { 3'd3, 16'b000110?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd2 , 5'd6 };
            { 3'd3, 16'b001000?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd3 , 5'd6 };
            { 3'd3, 16'b001001?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd3 , 5'd6 };
            { 3'd3, 16'b001010?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd3 , 5'd6 };
            { 3'd3, 16'b001011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd3 , 5'd6 };
            { 3'd3, 16'b001100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd4 , 5'd6 };
            { 3'd3, 16'b001101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd4 , 5'd6 };
            { 3'd3, 16'b001110?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd4 , 5'd6 };
            { 3'd3, 16'b001111?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd4 , 5'd6 };
            { 3'd3, 16'b010000?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd5 , 5'd6 };
            { 3'd3, 16'b010001?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd5 , 5'd6 };
            { 3'd3, 16'b010010?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd5 , 5'd6 };
            { 3'd3, 16'b010011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd5 , 5'd6 };
            { 3'd3, 16'b010100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd6 , 5'd6 };
            { 3'd3, 16'b010101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd6 , 5'd6 };
            { 3'd3, 16'b010110?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd6 , 5'd6 };
            { 3'd3, 16'b010111?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd6 , 5'd6 };
            { 3'd3, 16'b011000?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd7 , 5'd6 };
            { 3'd3, 16'b011001?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd7 , 5'd6 };
            { 3'd3, 16'b011010?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd7 , 5'd6 };
            { 3'd3, 16'b011011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd7 , 5'd6 };
            { 3'd3, 16'b011100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd8 , 5'd6 };
            { 3'd3, 16'b011101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd8 , 5'd6 };
            { 3'd3, 16'b011110?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd8 , 5'd6 };
            { 3'd3, 16'b011111?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd8 , 5'd6 };
            { 3'd3, 16'b100000?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd9 , 5'd6 };
            { 3'd3, 16'b100001?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd9 , 5'd6 };
            { 3'd3, 16'b100010?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd9 , 5'd6 };
            { 3'd3, 16'b100011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd9 , 5'd6 };
            { 3'd3, 16'b100100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd10, 5'd6 };
            { 3'd3, 16'b100101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd10, 5'd6 };
            { 3'd3, 16'b100110?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd10, 5'd6 };
            { 3'd3, 16'b100111?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd10, 5'd6 };
            { 3'd3, 16'b101000?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd11, 5'd6 };
            { 3'd3, 16'b101001?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd11, 5'd6 };
            { 3'd3, 16'b101010?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd11, 5'd6 };
            { 3'd3, 16'b101011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd11, 5'd6 };
            { 3'd3, 16'b101100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd12, 5'd6 };
            { 3'd3, 16'b101101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd12, 5'd6 };
            { 3'd3, 16'b101110?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd12, 5'd6 };
            { 3'd3, 16'b101111?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd12, 5'd6 };
            { 3'd3, 16'b110000?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd13, 5'd6 };
            { 3'd3, 16'b110001?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd13, 5'd6 };
            { 3'd3, 16'b110010?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd13, 5'd6 };
            { 3'd3, 16'b110011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd13, 5'd6 };
            { 3'd3, 16'b110100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd14, 5'd6 };
            { 3'd3, 16'b110101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd14, 5'd6 };
            { 3'd3, 16'b110110?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd14, 5'd6 };
            { 3'd3, 16'b110111?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd14, 5'd6 };
            { 3'd3, 16'b111000?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd15, 5'd6 };
            { 3'd3, 16'b111001?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd15, 5'd6 };
            { 3'd3, 16'b111010?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd15, 5'd6 };
            { 3'd3, 16'b111011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd15, 5'd6 };
            { 3'd3, 16'b111100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd16, 5'd6 };
            { 3'd3, 16'b111101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd16, 5'd6 };
            { 3'd3, 16'b111110?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd16, 5'd6 };
            { 3'd3, 16'b111111?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd16, 5'd6 };
            // idx = 4
            { 3'd4, 16'b01?????????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd0 , 5'd2 };
            { 3'd4, 16'b000111?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd1 , 5'd6 };
            { 3'd4, 16'b1??????????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd1 , 5'd1 };
            { 3'd4, 16'b000100?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd2 , 5'd6 };
            { 3'd4, 16'b000110?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd2 , 5'd6 };
            { 3'd4, 16'b001????????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd2 , 5'd3 };
            { 3'd4, 16'b000011?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd3 , 5'd6 };
            { 3'd4, 16'b0000011????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd3 , 5'd7 };
            { 3'd4, 16'b0000010????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd3 , 5'd7 };
            { 3'd4, 16'b000101?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd3 , 5'd6 };
            { 3'd4, 16'b000010?????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd0, 5'd4 , 5'd6 };
            { 3'd4, 16'b00000011???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd1, 5'd4 , 5'd8 };
            { 3'd4, 16'b00000010???????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd2, 5'd4 , 5'd8 };
            { 3'd4, 16'b0000000????????? } : { trailing_ones[1:0], num_coeff[4:0], coeff_token_len[4:0] } = { 3'd3, 5'd4 , 5'd7 };
        endcase 
    end

    // Update nc context right/below. In simple case these are an external register
    
    always_comb begin : nc_update_vld
        // left -> right
        right_nc_y[0] =  ( !dc_flag && y_flag && !bidx[3] && !bidx[1] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, left_nc_y[0][4:0] };
        right_nc_y[1] =  ( !dc_flag && y_flag && !bidx[3] &&  bidx[1] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, left_nc_y[1][4:0] };
        right_nc_y[2] =  ( !dc_flag && y_flag &&  bidx[3] && !bidx[1] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, left_nc_y[2][4:0] };
        right_nc_y[3] =  ( !dc_flag && y_flag &&  bidx[3] &&  bidx[1] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, left_nc_y[3][4:0] };
        right_nc_cb[0] = ( !dc_flag && cb_flag && !bidx[1] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, left_nc_cb[0][4:0] };
        right_nc_cb[1] = ( !dc_flag && cb_flag &&  bidx[1] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, left_nc_cb[1][4:0] };
        right_nc_cr[0] = ( !dc_flag && cr_flag && !bidx[1] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, left_nc_cr[0][4:0] };                     
        right_nc_cr[1] = ( !dc_flag && cr_flag &&  bidx[1] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, left_nc_cr[1][4:0] }; 
        // above -> below      
        below_nc_y[0] =  ( !dc_flag && y_flag && !bidx[2] && !bidx[0] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, above_nc_y[0][4:0] };
        below_nc_y[1] =  ( !dc_flag && y_flag && !bidx[2] &&  bidx[0] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, above_nc_y[1][4:0] };
        below_nc_y[2] =  ( !dc_flag && y_flag &&  bidx[2] && !bidx[0] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, above_nc_y[2][4:0] };
        below_nc_y[3] =  ( !dc_flag && y_flag &&  bidx[2] &&  bidx[0] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, above_nc_y[3][4:0] };
        below_nc_cb[0] = ( !dc_flag && cb_flag && !bidx[0] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, above_nc_cb[0][4:0] };
        below_nc_cb[1] = ( !dc_flag && cb_flag &&  bidx[0] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, above_nc_cb[1][4:0] };
        below_nc_cr[0] = ( !dc_flag && cr_flag && !bidx[0] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, above_nc_cr[0][4:0] };                     
        below_nc_cr[1] = ( !dc_flag && cr_flag &&  bidx[0] ) ? { 3'b000, num_coeff[4:0] } : { 3'b000, above_nc_cr[1][4:0] };        
    end



    //////////////////////////////
    // level_prefix, level_suffix, trailing_ones
    //////////////////////////////
    
    
    logic [12:0] level[16];
    logic [12:0] level_code[16];
    logic [2:0] suffix_length[17];
    logic [3:0] level_prefix[16];
    logic [5:0] level_suffix_bits[16];
    logic [4:0] max_coeff;
    
    always_comb begin : _level_prefix_suffix_vld
        max_coeff[4:0] = ( ch_flag && dc_flag ) ? 5'd4 : (ac_flag) ? 5'd15 : 5'd16;
        suffix_length[0][2:0] = ( num_coeff > 5'd10 && trailing_ones < 2'd3 ) ? 3'd1 : 3'd0;
        for( int ii = 0; ii < 16; ii++ ) begin
            if( ii < trailing_ones[1:0] ) begin // trailing ones
                suffix_length[ii+1] = suffix_length[ii];
                level_code[ii][12:0]= { 12'h000, coeff_bitword[ii][31] };
                level[ii][12:0] = ( coeff_bitword[ii][31] ) ? 13'h1FFF : 13'h0001;
                coeff_len[ii][8:0]  = 5'd1;
            end else if ( ii >= max_coeff || ii >= num_coeff ) begin // zero fill
                suffix_length[ii+1] = suffix_length[ii];
                level_code[ii][12:0]     = 13'h0000;
                level[ii][12:0] = 13'h0000;
                coeff_len[ii][8:0]  = 5'd0;
           end else begin // normal coeff
                // get level prefix
                level_prefix[ii][3:0] = 0;
                level_suffix_bits[ii][5:0] = 0;
                unique0 casez ( coeff_bitword[ii][31:16] )
                    { 16'b1??????????????? } : begin level_prefix[ii][3:0] = 4'd0 ; level_suffix_bits[ii][5:0] = coeff_bitword[ii][30:25]; end
                    { 16'b01?????????????? } : begin level_prefix[ii][3:0] = 4'd1 ; level_suffix_bits[ii][5:0] = coeff_bitword[ii][29:24]; end
                    { 16'b001????????????? } : begin level_prefix[ii][3:0] = 4'd2 ; level_suffix_bits[ii][5:0] = coeff_bitword[ii][28:23]; end
                    { 16'b0001???????????? } : begin level_prefix[ii][3:0] = 4'd3 ; level_suffix_bits[ii][5:0] = coeff_bitword[ii][27:22]; end
                    { 16'b00001??????????? } : begin level_prefix[ii][3:0] = 4'd4 ; level_suffix_bits[ii][5:0] = coeff_bitword[ii][26:21]; end
                    { 16'b000001?????????? } : begin level_prefix[ii][3:0] = 4'd5 ; level_suffix_bits[ii][5:0] = coeff_bitword[ii][25:20]; end
                    { 16'b0000001????????? } : begin level_prefix[ii][3:0] = 4'd6 ; level_suffix_bits[ii][5:0] = coeff_bitword[ii][24:19]; end
                    { 16'b00000001???????? } : begin level_prefix[ii][3:0] = 4'd7 ; level_suffix_bits[ii][5:0] = coeff_bitword[ii][23:18]; end
                    { 16'b000000001??????? } : begin level_prefix[ii][3:0] = 4'd8 ; level_suffix_bits[ii][5:0] = coeff_bitword[ii][22:17]; end
                    { 16'b0000000001?????? } : begin level_prefix[ii][3:0] = 4'd9 ; level_suffix_bits[ii][5:0] = coeff_bitword[ii][21:16]; end
                    { 16'b00000000001????? } : begin level_prefix[ii][3:0] = 4'd10; level_suffix_bits[ii][5:0] = coeff_bitword[ii][20:15]; end
                    { 16'b000000000001???? } : begin level_prefix[ii][3:0] = 4'd11; level_suffix_bits[ii][5:0] = coeff_bitword[ii][19:14]; end
                    { 16'b0000000000001??? } : begin level_prefix[ii][3:0] = 4'd12; level_suffix_bits[ii][5:0] = coeff_bitword[ii][18:13]; end
                    { 16'b00000000000001?? } : begin level_prefix[ii][3:0] = 4'd13; level_suffix_bits[ii][5:0] = coeff_bitword[ii][17:12]; end
                    { 16'b000000000000001? } : begin level_prefix[ii][3:0] = 4'd14; level_suffix_bits[ii][5:0] = coeff_bitword[ii][16:11]; end
                    { 16'b0000000000000001 } : begin level_prefix[ii][3:0] = 4'd15; level_suffix_bits[ii][5:0] = 6'b000000; end     
                endcase
                // level_code
                if( level_prefix[ii] == 4'd14 && suffix_length[ii][2:0] == 3'd0 ) begin
                    coeff_len[ii][8:0] = 9'd19;
                    level_code[ii][12:0] = coeff_bitword[ii][16:13] + 14;
                end else if ( level_prefix[ii] == 4'd15 ) begin
                    coeff_len[ii][8:0] = 9'd28;                                                                    
                    level_code[ii][12:0] = { 1'b0, coeff_bitword[ii][15:4] } + (( suffix_length[ii] == 0 ) ? 13'd30  :
                                                                                ( suffix_length[ii] == 1 ) ? 13'd30  :
                                                                                ( suffix_length[ii] == 2 ) ? 13'd60  :
                                                                                ( suffix_length[ii] == 3 ) ? 13'd120 :
                                                                                ( suffix_length[ii] == 4 ) ? 13'd240 :
                                                                                ( suffix_length[ii] == 5 ) ? 13'd480 : 13'd960);
                end else begin // Normal coeff case
                    level_code[ii] = 0;
                    coeff_len[ii][8:0] = level_prefix[ii] + suffix_length[ii] + 1;                                                                     
                    unique0 casez( suffix_length[ii] ) 
                        0 : level_code[ii] = { 9'b0, level_prefix[ii][3:0]                             };
                        1 : level_code[ii] = { 8'b0, level_prefix[ii][3:0], level_suffix_bits[ii][5]   };
                        2 : level_code[ii] = { 7'b0, level_prefix[ii][3:0], level_suffix_bits[ii][5:4] };
                        3 : level_code[ii] = { 6'b0, level_prefix[ii][3:0], level_suffix_bits[ii][5:3] };
                        4 : level_code[ii] = { 5'b0, level_prefix[ii][3:0], level_suffix_bits[ii][5:2] };
                        5 : level_code[ii] = { 4'b0, level_prefix[ii][3:0], level_suffix_bits[ii][5:1] };
                        6 : level_code[ii] = { 3'b0, level_prefix[ii][3:0], level_suffix_bits[ii][5:0] };
                    endcase
                end                
                // level
                if( ii == trailing_ones && ii < 3 ) begin // special case, level_code+=2
                    level[ii][12:0] = ( level_code[ii][0] ) ? ( { 1'b1, ~level_code[ii][12:1] } - 1 ) : ( {1'b0, level_code[ii][12:1]} + 2 );
                end else begin // normal level calc
                    level[ii][12:0] = ( level_code[ii][0] ) ?   { 1'b1, ~level_code[ii][12:1] }       : ( {1'b0, level_code[ii][12:1]} + 1 );
                end
                // calc next suffix length
                if( suffix_length[ii][2:0] == 3'd0 ) begin
                    if( ii == trailing_ones && ii < 3 ) begin // special case, level_code+=2
                        suffix_length[ii+1] = ( coeff_bitword[ii][31:28] == 4'b0000  ) ? 3'd2 : 3'd1;
                    end else begin
                        suffix_length[ii+1] = ( coeff_bitword[ii][31:26] == 6'b000000  ) ? 3'd2 : 3'd1;
                    end
                end else if ( suffix_length[ii][2:0] < 3'd6 ) begin
                    suffix_length[ii+1][2:0] = suffix_length[ii][2:0] + (( coeff_bitword[ii][31:29] == 3'b000 ) ? 3'd1 : 3'd0 );
                end else begin
                    suffix_length[ii+1][2:0] = 3'd6;
                end
           end
        end //ii
    end

    //////////////////////////////
    // total_zeros
    //////////////////////////////

    // handle luma/chroma_dc table selection, num_coeff==0 and num_coeff==max_coeff cases
     
    logic [4:0] total_zeros;
    always_comb begin : _total_zeros_vld
        total_zeros[4:0] = 0;
        total_zeros_len[8:0] = 0;   
        unique0 casez( { (ch_flag & dc_flag), num_coeff[4:0], total_zeros_bitword[31:23] } )
            // Luma special cases, num_coeff == 0 and num_coeff == max_coeff
            { 1'b0, 5'd0, 9'b????????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd16, 4'd0 };
            { 1'b0, 5'd16,9'b????????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd0, 4'd0 };
            // Chroma special case
            { 1'b1, 5'd0, 9'b????????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd4, 4'd0 };
            { 1'b1, 5'd4, 9'b????????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd0, 4'd0 };
            // Luma
            { 1'b0, 5'd1, 9'b1???????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd1 };
            { 1'b0, 5'd1, 9'b011?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd3 };
            { 1'b0, 5'd1, 9'b010?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd3 };
            { 1'b0, 5'd1, 9'b0011????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd4 };
            { 1'b0, 5'd1, 9'b0010????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd4 };
            { 1'b0, 5'd1, 9'b00011???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd5, 4'd5 };
            { 1'b0, 5'd1, 9'b00010???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd6, 4'd5 };
            { 1'b0, 5'd1, 9'b000011??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd7, 4'd6 };
            { 1'b0, 5'd1, 9'b000010??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd8, 4'd6 };
            { 1'b0, 5'd1, 9'b0000011?? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd9, 4'd7 };
            { 1'b0, 5'd1, 9'b0000010?? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd10, 4'd7 };
            { 1'b0, 5'd1, 9'b00000011? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd11, 4'd8 };
            { 1'b0, 5'd1, 9'b00000010? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd12, 4'd8 };
            { 1'b0, 5'd1, 9'b000000011 } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd13, 4'd9 };
            { 1'b0, 5'd1, 9'b000000010 } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd14, 4'd9 };
            { 1'b0, 5'd1, 9'b000000001 } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd15, 4'd9 };
            { 1'b0, 5'd2, 9'b111?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd3 };
            { 1'b0, 5'd2, 9'b110?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd3 };
            { 1'b0, 5'd2, 9'b101?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd3 };
            { 1'b0, 5'd2, 9'b100?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd3 };
            { 1'b0, 5'd2, 9'b011?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd3 };
            { 1'b0, 5'd2, 9'b0101????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd5, 4'd4 };
            { 1'b0, 5'd2, 9'b0100????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd6, 4'd4 };
            { 1'b0, 5'd2, 9'b0011????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd7, 4'd4 };
            { 1'b0, 5'd2, 9'b0010????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd8, 4'd4 };
            { 1'b0, 5'd2, 9'b00011???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd9, 4'd5 };
            { 1'b0, 5'd2, 9'b00010???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd10, 4'd5 };
            { 1'b0, 5'd2, 9'b000011??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd11, 4'd6 };
            { 1'b0, 5'd2, 9'b000010??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd12, 4'd6 };
            { 1'b0, 5'd2, 9'b000001??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd13, 4'd6 };
            { 1'b0, 5'd2, 9'b000000??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd14, 4'd6 };
            { 1'b0, 5'd3, 9'b0101????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd4 };
            { 1'b0, 5'd3, 9'b111?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd3 };
            { 1'b0, 5'd3, 9'b110?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd3 };
            { 1'b0, 5'd3, 9'b101?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd3 };
            { 1'b0, 5'd3, 9'b0100????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd4 };
            { 1'b0, 5'd3, 9'b0011????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd5, 4'd4 };
            { 1'b0, 5'd3, 9'b100?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd6, 4'd3 };
            { 1'b0, 5'd3, 9'b011?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd7, 4'd3 };
            { 1'b0, 5'd3, 9'b0010????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd8, 4'd4 };
            { 1'b0, 5'd3, 9'b00011???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd9, 4'd5 };
            { 1'b0, 5'd3, 9'b00010???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd10, 4'd5 };
            { 1'b0, 5'd3, 9'b000001??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd11, 4'd6 };
            { 1'b0, 5'd3, 9'b00001???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd12, 4'd5 };
            { 1'b0, 5'd3, 9'b000000??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd13, 4'd6 };
            { 1'b0, 5'd4, 9'b00011???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd5 };
            { 1'b0, 5'd4, 9'b111?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd3 };
            { 1'b0, 5'd4, 9'b0101????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd4 };
            { 1'b0, 5'd4, 9'b0100????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd4 };
            { 1'b0, 5'd4, 9'b110?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd3 };
            { 1'b0, 5'd4, 9'b101?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd5, 4'd3 };
            { 1'b0, 5'd4, 9'b100?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd6, 4'd3 };
            { 1'b0, 5'd4, 9'b0011????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd7, 4'd4 };
            { 1'b0, 5'd4, 9'b011?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd8, 4'd3 };
            { 1'b0, 5'd4, 9'b0010????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd9, 4'd4 };
            { 1'b0, 5'd4, 9'b00010???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd10, 4'd5 };
            { 1'b0, 5'd4, 9'b00001???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd11, 4'd5 };
            { 1'b0, 5'd4, 9'b00000???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd12, 4'd5 };
            { 1'b0, 5'd5, 9'b0101????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd4 };
            { 1'b0, 5'd5, 9'b0100????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd4 };
            { 1'b0, 5'd5, 9'b0011????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd4 };
            { 1'b0, 5'd5, 9'b111?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd3 };
            { 1'b0, 5'd5, 9'b110?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd3 };
            { 1'b0, 5'd5, 9'b101?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd5, 4'd3 };
            { 1'b0, 5'd5, 9'b100?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd6, 4'd3 };
            { 1'b0, 5'd5, 9'b011?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd7, 4'd3 };
            { 1'b0, 5'd5, 9'b0010????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd8, 4'd4 };
            { 1'b0, 5'd5, 9'b00001???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd9, 4'd5 };
            { 1'b0, 5'd5, 9'b0001????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd10, 4'd4 };
            { 1'b0, 5'd5, 9'b00000???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd11, 4'd5 };
            { 1'b0, 5'd6, 9'b000001??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd6 };
            { 1'b0, 5'd6, 9'b00001???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd5 };
            { 1'b0, 5'd6, 9'b111?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd3 };
            { 1'b0, 5'd6, 9'b110?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd3 };
            { 1'b0, 5'd6, 9'b101?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd3 };
            { 1'b0, 5'd6, 9'b100?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd5, 4'd3 };
            { 1'b0, 5'd6, 9'b011?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd6, 4'd3 };
            { 1'b0, 5'd6, 9'b010?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd7, 4'd3 };
            { 1'b0, 5'd6, 9'b0001????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd8, 4'd4 };
            { 1'b0, 5'd6, 9'b001?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd9, 4'd3 };
            { 1'b0, 5'd6, 9'b000000??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd10, 4'd6 };
            { 1'b0, 5'd7, 9'b000001??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd6 };
            { 1'b0, 5'd7, 9'b00001???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd5 };
            { 1'b0, 5'd7, 9'b101?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd3 };
            { 1'b0, 5'd7, 9'b100?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd3 };
            { 1'b0, 5'd7, 9'b011?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd3 };
            { 1'b0, 5'd7, 9'b11??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd5, 4'd2 };
            { 1'b0, 5'd7, 9'b010?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd6, 4'd3 };
            { 1'b0, 5'd7, 9'b0001????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd7, 4'd4 };
            { 1'b0, 5'd7, 9'b001?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd8, 4'd3 };
            { 1'b0, 5'd7, 9'b000000??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd9, 4'd6 };
            { 1'b0, 5'd8, 9'b000001??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd6 };
            { 1'b0, 5'd8, 9'b0001????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd4 };
            { 1'b0, 5'd8, 9'b00001???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd5 };
            { 1'b0, 5'd8, 9'b011?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd3 };
            { 1'b0, 5'd8, 9'b11??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd2 };
            { 1'b0, 5'd8, 9'b10??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd5, 4'd2 };
            { 1'b0, 5'd8, 9'b010?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd6, 4'd3 };
            { 1'b0, 5'd8, 9'b001?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd7, 4'd3 };
            { 1'b0, 5'd8, 9'b000000??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd8, 4'd6 };
            { 1'b0, 5'd9, 9'b000001??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd6 };
            { 1'b0, 5'd9, 9'b000000??? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd6 };
            { 1'b0, 5'd9, 9'b0001????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd4 };
            { 1'b0, 5'd9, 9'b11??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd2 };
            { 1'b0, 5'd9, 9'b10??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd2 };
            { 1'b0, 5'd9, 9'b001?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd5, 4'd3 };
            { 1'b0, 5'd9, 9'b01??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd6, 4'd2 };
            { 1'b0, 5'd9, 9'b00001???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd7, 4'd5 };
            { 1'b0, 5'd10,9'b00001???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd5 };
            { 1'b0, 5'd10,9'b00000???? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd5 };
            { 1'b0, 5'd10,9'b001?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd3 };
            { 1'b0, 5'd10,9'b11??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd2 };
            { 1'b0, 5'd10,9'b10??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd2 };
            { 1'b0, 5'd10,9'b01??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd5, 4'd2 };
            { 1'b0, 5'd10,9'b0001????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd6, 4'd4 };
            { 1'b0, 5'd11,9'b0000????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd4 };
            { 1'b0, 5'd11,9'b0001????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd4 };
            { 1'b0, 5'd11,9'b001?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd3 };
            { 1'b0, 5'd11,9'b010?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd3 };
            { 1'b0, 5'd11,9'b1???????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd1 };
            { 1'b0, 5'd11,9'b011?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd5, 4'd3 };
            { 1'b0, 5'd12,9'b0000????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd4 };
            { 1'b0, 5'd12,9'b0001????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd4 };
            { 1'b0, 5'd12,9'b01??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd2 };
            { 1'b0, 5'd12,9'b1???????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd1 };
            { 1'b0, 5'd12,9'b001?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd4, 4'd3 };
            { 1'b0, 5'd13,9'b000?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd3 };
            { 1'b0, 5'd13,9'b001?????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd3 };
            { 1'b0, 5'd13,9'b1???????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd1 };
            { 1'b0, 5'd13,9'b01??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd3, 4'd2 };
            { 1'b0, 5'd14,9'b00??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd2 };
            { 1'b0, 5'd14,9'b01??????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd2 };
            { 1'b0, 5'd14,9'b1???????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd2, 4'd1 };
            { 1'b0, 5'd15,9'b0???????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd0, 4'd1 };
            { 1'b0, 5'd15,9'b1???????? } : { total_zeros[4:0], total_zeros_len[3:0] }= { 5'd1, 4'd1 };
            // Chroma
            { 1'b1, 5'd1, 9'b1???????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd0, 4'd1 };
            { 1'b1, 5'd1, 9'b01??????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd1, 4'd2 };
            { 1'b1, 5'd1, 9'b001?????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd2, 4'd3 };
            { 1'b1, 5'd1, 9'b000?????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd3, 4'd3 };
            { 1'b1, 5'd2, 9'b1???????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd0, 4'd1 };
            { 1'b1, 5'd2, 9'b01??????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd1, 4'd2 };
            { 1'b1, 5'd2, 9'b00??????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd2, 4'd2 };
            { 1'b1, 5'd3, 9'b1???????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd0, 4'd1 };
            { 1'b1, 5'd3, 9'b0???????? } : { total_zeros[4:0], total_zeros_len[3:0] } = { 5'd1, 4'd1 };
        endcase  
    end

    //////////////////////////////
    // run_before
    //////////////////////////////
    
    logic [3:0] run_before[15];
    logic [4:0] zeros_left[15]; 
    logic [4:0] num_coeff_minus1;
    always_comb begin : _run_before_vld
        num_coeff_minus1 = num_coeff - 1;
        zeros_left[0] = total_zeros;
        for( int ii = 0; ii < 15; ii++ ) begin
            if( ii > num_coeff_minus1 ) begin // empty
                run_before[ii]     = 0;
                run_before_len[ii] = 0;
                zeros_left[ii+1]   = 0;
            end else if ( zeros_left[ii] && ii == num_coeff_minus1 ) begin // take remaining zeros
                run_before[ii]     = zeros_left[ii];
                run_before_len[ii] = 0;
                zeros_left[ii+1]   = 0;
            end else if ( zeros_left[ii] ) begin // run_before parsing
                run_before_len[ii][8:4]= 0;
                run_before_len [ii][3:0] = 0;
                run_before[ii][3:0] = 0;
                unique0 casez( { (( zeros_left[ii][4:0] > 5'd6 ) ? 3'd7 : zeros_left[ii][2:0] ), run_before_bitword[ii][31:21] } )
                    { 3'd1, 11'b1?????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd0, 4'd1 };
                    { 3'd1, 11'b0?????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd1, 4'd1 };
                    { 3'd2, 11'b1?????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd0, 4'd1 };
                    { 3'd2, 11'b01????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd1, 4'd2 };
                    { 3'd2, 11'b00????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd2, 4'd2 };
                    { 3'd3, 11'b11????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd0, 4'd2 };
                    { 3'd3, 11'b10????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd1, 4'd2 };
                    { 3'd3, 11'b01????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd2, 4'd2 };
                    { 3'd3, 11'b00????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd3, 4'd2 };
                    { 3'd4, 11'b11????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd0, 4'd2 };
                    { 3'd4, 11'b10????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd1, 4'd2 };
                    { 3'd4, 11'b01????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd2, 4'd2 };
                    { 3'd4, 11'b001???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd3, 4'd3 };
                    { 3'd4, 11'b000???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd4, 4'd3 };
                    { 3'd5, 11'b11????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd0, 4'd2 };
                    { 3'd5, 11'b10????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd1, 4'd2 };
                    { 3'd5, 11'b011???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd2, 4'd3 };
                    { 3'd5, 11'b010???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd3, 4'd3 };
                    { 3'd5, 11'b001???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd4, 4'd3 };
                    { 3'd5, 11'b000???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd5, 4'd3 };
                    { 3'd6, 11'b11????????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd0, 4'd2 };
                    { 3'd6, 11'b000???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd1, 4'd3 };
                    { 3'd6, 11'b001???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd2, 4'd3 };
                    { 3'd6, 11'b011???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd3, 4'd3 };
                    { 3'd6, 11'b010???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd4, 4'd3 };
                    { 3'd6, 11'b101???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd5, 4'd3 };
                    { 3'd6, 11'b100???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd6, 4'd3 };
                    { 3'd7, 11'b111???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd0, 4'd3 };
                    { 3'd7, 11'b110???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd1, 4'd3 };
                    { 3'd7, 11'b101???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd2, 4'd3 };
                    { 3'd7, 11'b100???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd3, 4'd3 };
                    { 3'd7, 11'b011???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd4, 4'd3 };
                    { 3'd7, 11'b010???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd5, 4'd3 };
                    { 3'd7, 11'b001???????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd6, 4'd3 };
                    { 3'd7, 11'b0001??????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd7, 4'd4 };
                    { 3'd7, 11'b00001?????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd8, 4'd5 };
                    { 3'd7, 11'b000001????? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd9, 4'd6 };
                    { 3'd7, 11'b0000001???? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd10,4'd7 };
                    { 3'd7, 11'b00000001??? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd11,4'd8 };
                    { 3'd7, 11'b000000001?? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd12,4'd9 };
                    { 3'd7, 11'b0000000001? } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd13,4'd10};
                    { 3'd7, 11'b00000000001 } : { run_before[ii][3:0], run_before_len[ii][3:0] } = { 4'd14,5'd11};
                endcase 
                zeros_left[ii+1][4:0] = zeros_left[ii][4:0] - { 1'b0, run_before[ii][3:0] };               
            end else begin // no zeros left
                run_before[ii]     = 0;
                run_before_len[ii] = 0;
                zeros_left[ii+1]   = 0;
            end
        end //ii
    end
    
    //////////////////////////////
    // inverse zig-zig to get 4x4
    //////////////////////////////
    // expand packed 1D levels[16] into 2D coeff[16] 
    // using num_coeff, total_zeros and run_before[14]
    // and 2D ordering to mux level[16] into coeff[16]

	logic [0:15][4:0] izigzag4x4ac = { 5'd16, 5'd0, 5'd4, 5'd5 , 5'd1 , 5'd3 , 5'd6 , 5'd11, 5'd2, 5'd7 , 5'd10, 5'd12, 5'd8 , 5'd9 , 5'd13, 5'd14 };
	logic [0:15][4:0] izigzag4x4   = { 5'd0, 5'd1 , 5'd5, 5'd6 , 5'd2 , 5'd4 , 5'd7 , 5'd12, 5'd3, 5'd8 , 5'd11, 5'd13, 5'd9 , 5'd10, 5'd14, 5'd15 };
	logic [0:15][4:0] izigzag2x2   = { 5'd0, 5'd16, 5'd1, 5'd16, 5'd16, 5'd16, 5'd16, 5'd16, 5'd2, 5'd16, 5'd3 , 5'd16, 5'd16, 5'd16, 5'd16, 5'd16 };

    logic signed [12:0] coeff[16]; // signed for later iq multiply
    logic [4:0] scan_index[16];
    logic [3:0] cur_zeros[17];
    logic [4:0] cur_run[17];
    logic [3:0] cur_coeff[17];
    logic [4:0] idx1[16];
    logic [4:0] idx2[16];

    always_comb begin : _zigzag_vld
        // create scan index[] from run_before[].
        cur_run[0][4:0]   = num_coeff_minus1;
        cur_zeros[0][3:0] = run_before[cur_run[0][3:0]][3:0];
        cur_coeff[0][3:0] = num_coeff_minus1;        
        for( int ii = 0; ii < 16; ii++ ) begin // create scan_idx
            if( ii >= ( ( ch_flag & dc_flag ) ? 4 : ( ac_flag ) ? 15 : 16 ) ) begin
                scan_index[ii] = 5'h10;
                cur_coeff[ii+1] = cur_coeff[ii];
                cur_run[ii+1]   = cur_run[ii];
                cur_zeros[ii+1] = 4'hf;
            end else if( cur_run[ii][4:0] == num_coeff[4:0] ) begin
                scan_index[ii] = 5'h10;
                cur_coeff[ii+1] = cur_coeff[ii];
                cur_run[ii+1]   = cur_run[ii];
                cur_zeros[ii+1] = 4'hf;
            end else if( cur_zeros[ii] == 0 ) begin
                scan_index[ii][4:0] = { 1'b0, cur_coeff[ii][3:0] };
                cur_coeff[ii+1] = cur_coeff[ii] - 1;
                cur_run[ii+1]   = cur_run[ii] - 1;
                cur_zeros[ii+1] = run_before[ cur_run[ii+1] ];
            end else begin
                scan_index[ii]  = 5'h10;
                cur_zeros[ii+1] = cur_zeros[ii] - 1;
                cur_run[ii+1]   = cur_run[ii];
                cur_coeff[ii+1] = cur_coeff[ii];
            end 
        end //ii

        // load coeff from level with scan_index[zigzag[]]       
        for( int ii = 0 ; ii < 16; ii++ ) begin  
            idx1[ii][4:0]   = ( ch_flag & dc_flag ) ? izigzag2x2[ii][4:0] : ( ac_flag ) ? izigzag4x4ac[ii][4:0] : izigzag4x4[ii][4:0];
            idx2[ii][4:0]   = ( idx1[ii][4] ) ? 5'h10 : scan_index[idx1[ii][3:0]];
            coeff[ii][12:0] = ( idx2[ii][4] ) ? 13'd0 : level[idx2[ii][3:0]];
        end //ii 
    end // always_comb
 	//////////////////////////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////////////////////////
	//                         >>>>>>>>> coeff[16] <<<<<<<<<<<<<<
	//           Now we have coefficients to: 1) entropy encode 2) reconstruct
	//////////////////////////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////////////////////////

	// // Select qpy or derive qpc, and create mod6, div6 
    // const int qpc_table[52] = { 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,
    // 							29, 30, 31, 32, 32, 33, 34, 34,35,35,36,36,37,37,37,38,38,38,39,39,39,39 };
	// qp = (ch_flag) ? qpc_table[qpy] : qpy;
    
    logic [0:103][12:0] qptab;
    assign qptab = 
                  { { 6'd00, 3'd0, 4'd0 } , { 6'd00, 3'd0, 4'd0 } , { 6'd01, 3'd1, 4'd0 } , { 6'd01, 3'd1, 4'd0 } , { 6'd02, 3'd2, 4'd0 } , { 6'd02, 3'd2, 4'd0 } , 
                    { 6'd03, 3'd3, 4'd0 } , { 6'd03, 3'd3, 4'd0 } , { 6'd04, 3'd4, 4'd0 } , { 6'd04, 3'd4, 4'd0 } , { 6'd05, 3'd5, 4'd0 } , { 6'd05, 3'd5, 4'd0 } , 
                    { 6'd06, 3'd0, 4'd1 } , { 6'd06, 3'd0, 4'd1 } , { 6'd07, 3'd1, 4'd1 } , { 6'd07, 3'd1, 4'd1 } , { 6'd08, 3'd2, 4'd1 } , { 6'd08, 3'd2, 4'd1 } , 
                    { 6'd09, 3'd3, 4'd1 } , { 6'd09, 3'd3, 4'd1 } , { 6'd10, 3'd4, 4'd1 } , { 6'd10, 3'd4, 4'd1 } , { 6'd11, 3'd5, 4'd1 } , { 6'd11, 3'd5, 4'd1 } , 
                    { 6'd12, 3'd0, 4'd2 } , { 6'd12, 3'd0, 4'd2 } , { 6'd13, 3'd1, 4'd2 } , { 6'd13, 3'd1, 4'd2 } , { 6'd14, 3'd2, 4'd2 } , { 6'd14, 3'd2, 4'd2 } , 
                    { 6'd15, 3'd3, 4'd2 } , { 6'd15, 3'd3, 4'd2 } , { 6'd16, 3'd4, 4'd2 } , { 6'd16, 3'd4, 4'd2 } , { 6'd17, 3'd5, 4'd2 } , { 6'd17, 3'd5, 4'd2 } , 
                    { 6'd18, 3'd0, 4'd3 } , { 6'd18, 3'd0, 4'd3 } , { 6'd19, 3'd1, 4'd3 } , { 6'd19, 3'd1, 4'd3 } , { 6'd20, 3'd2, 4'd3 } , { 6'd20, 3'd2, 4'd3 } , 
                    { 6'd21, 3'd3, 4'd3 } , { 6'd21, 3'd3, 4'd3 } , { 6'd22, 3'd4, 4'd3 } , { 6'd22, 3'd4, 4'd3 } , { 6'd23, 3'd5, 4'd3 } , { 6'd23, 3'd5, 4'd3 } , 
                    { 6'd24, 3'd0, 4'd4 } , { 6'd24, 3'd0, 4'd4 } , { 6'd25, 3'd1, 4'd4 } , { 6'd25, 3'd1, 4'd4 } , { 6'd26, 3'd2, 4'd4 } , { 6'd26, 3'd2, 4'd4 } , 
                    { 6'd27, 3'd3, 4'd4 } , { 6'd27, 3'd3, 4'd4 } , { 6'd28, 3'd4, 4'd4 } , { 6'd28, 3'd4, 4'd4 } , { 6'd29, 3'd5, 4'd4 } , { 6'd29, 3'd5, 4'd4 } , 
                    { 6'd30, 3'd0, 4'd5 } , { 6'd29, 3'd5, 4'd4 } , { 6'd31, 3'd1, 4'd5 } , { 6'd30, 3'd0, 4'd5 } , { 6'd32, 3'd2, 4'd5 } , { 6'd31, 3'd1, 4'd5 } , 
                    { 6'd33, 3'd3, 4'd5 } , { 6'd32, 3'd2, 4'd5 } , { 6'd34, 3'd4, 4'd5 } , { 6'd32, 3'd2, 4'd5 } , { 6'd35, 3'd5, 4'd5 } , { 6'd33, 3'd3, 4'd5 } , 
                    { 6'd36, 3'd0, 4'd6 } , { 6'd34, 3'd4, 4'd5 } , { 6'd37, 3'd1, 4'd6 } , { 6'd34, 3'd4, 4'd5 } , { 6'd38, 3'd2, 4'd6 } , { 6'd35, 3'd5, 4'd5 } , 
                    { 6'd39, 3'd3, 4'd6 } , { 6'd35, 3'd5, 4'd5 } , { 6'd40, 3'd4, 4'd6 } , { 6'd36, 3'd0, 4'd6 } , { 6'd41, 3'd5, 4'd6 } , { 6'd36, 3'd0, 4'd6 } , 
                    { 6'd42, 3'd0, 4'd7 } , { 6'd37, 3'd1, 4'd6 } , { 6'd43, 3'd1, 4'd7 } , { 6'd37, 3'd1, 4'd6 } , { 6'd44, 3'd2, 4'd7 } , { 6'd37, 3'd1, 4'd6 } , 
                    { 6'd45, 3'd3, 4'd7 } , { 6'd38, 3'd2, 4'd6 } , { 6'd46, 3'd4, 4'd7 } , { 6'd38, 3'd2, 4'd6 } , { 6'd47, 3'd5, 4'd7 } , { 6'd38, 3'd2, 4'd6 } , 
                    { 6'd48, 3'd0, 4'd8 } , { 6'd39, 3'd3, 4'd6 } , { 6'd49, 3'd1, 4'd8 } , { 6'd39, 3'd3, 4'd6 } , { 6'd50, 3'd2, 4'd8 } , { 6'd39, 3'd3, 4'd6 } , 
                    { 6'd51, 3'd3, 4'd8 } , { 6'd39, 3'd3, 4'd6 } };
    
    logic [5:0] qp;
    logic [3:0] qpdiv6;
    logic [2:0] qpmod6;
    
    always_comb begin
        {qp[5:0], qpmod6[2:0], qpdiv6[3:0]} = qptab[{qpy[5:0], ch_flag}][12:0]; // rom lookup
    end

	/////////////////////////////////////////
	// Inverse Quant (coeff->f)
	/////////////////////////////////////////

    logic [0:5][4:0] dvmat0, dvmat1, dvmat2;
    logic [4:0] dvm0, dvm1, dvm2;
    logic [0:15][4:0] dquant;
    assign dvmat0 = { 5'd10, 5'd11, 5'd13, 5'd14, 5'd16, 5'd18 };
    assign dvmat1 = { 5'd16, 5'd18, 5'd20, 5'd23, 5'd25, 5'd29 };
    assign dvmat2 = { 5'd13, 5'd14, 5'd16, 5'd18, 5'd20, 5'd23 };
    assign dvm0 = dvmat0[ qpmod6 ];
    assign dvm1 = dvmat1[ qpmod6 ];
    assign dvm2 = dvmat2[ qpmod6 ];
    assign dquant = {  dvm0, dvm2, dvm0, dvm2, 
                       dvm2, dvm1, dvm2, dvm1, 
                       dvm0, dvm2, dvm0, dvm2, 
                       dvm2, dvm1, dvm2, dvm1 };
    logic [28:0] f[16];
    logic signed [24:0] dprod[16]; // 13 bit signed coeff * 5+4 bit quant
    logic signed [9:0] dmul[16];
    logic signed [24:0] dpofs[16]; // with rounding offset
    logic signed [15:0] dcoeff[16];

    always_comb begin
        for( int ii = 0; ii < 16; ii++ ) begin
            dcoeff[ii][15:0] = ( ii == 0 && ac_flag && cb_flag ) ? dc_hold[{ 1'b0, bidx[1], 1'b0,  bidx[0] }][15:0] : // sample 0,1,4,5
                               ( ii == 0 && ac_flag && cr_flag ) ? dc_hold[{ 1'b0, bidx[1], 1'b1, ~bidx[0] }][15:0] : // sample 3,2,7,6
                               ( ii == 0 && ac_flag &&  y_flag ) ? dc_hold[bidx[3:0]][15:0] : // luma dc coeff
                                                                   { {3{coeff[ii][12]}}, coeff[ii][12:0] }; // regular coeff
            dmul[ii][9:0] = { 1'b0, dquant[ii][4:0], 4'b0000 };
            dprod[ii] = dcoeff[ii] * dmul[ii]; // Signed Multiply!
            dpofs[ii][24:0] = dprod[ii][24:0] + 
                             (( ii == 0 && ac_flag && qpdiv6 == 0 ) ? 25'h20:
                              ( ii == 0 && ac_flag && qpdiv6 == 1 ) ? 25'h10:
                              ( ii == 0 && ac_flag && qpdiv6 == 2 ) ? 25'h8:
                              ( ii == 0 && ac_flag && qpdiv6 == 3 ) ? 25'h4:
                              ( ii == 0 && ac_flag && qpdiv6 == 4 ) ? 25'h2:
                              ( ii == 0 && ac_flag && qpdiv6 == 5 ) ? 25'h1:
                              (                       qpdiv6 == 0 ) ? 25'h8:
                              (                       qpdiv6 == 1 ) ? 25'h4:
                              (                       qpdiv6 == 2 ) ? 25'h2:
                            /*(                       qpdiv6 == 3 )*/ 25'h1 );         
        end
        if( dc_flag ) begin // if DC coeff, defer quant until AC, just copy
            if( ch_flag ) begin // relocate chroma DC and zero remainder
                for( int ii = 0; ii < 16; ii++ ) begin
                    f[ii] = 29'd0;
                end
                f[ 0][28:0] = { {16{coeff[ 0][12]}}, coeff[0][12:0] };
                f[ 2][28:0] = { {16{coeff[ 2][12]}}, coeff[2][12:0] };
                f[ 8][28:0] = { {16{coeff[ 8][12]}}, coeff[8][12:0] };
                f[10][28:0] = { {16{coeff[10][12]}}, coeff[10][12:0] };
            end else begin // just copy thru luma DC
                for( int ii = 0; ii < 16; ii++ ) begin
                    f[ii][28:0] = { {16{coeff[ii][12]}}, coeff[ii][12:0] };
                end
            end 
        end else begin // Inverse quant the ac coeffs, bring in the inverse DC
            for( int ii = 0; ii < 16; ii++ ) begin
                if( ii == 0 && ac_flag && ch_flag ) begin // get chroma DC from dc hold and iquant 
                    f[0] =  ( qpdiv6 == 0 ) ? { {9{dprod[0][24]}}, dprod[0][24:5]       }:
                            ( qpdiv6 == 1 ) ? { {8{dprod[0][24]}}, dprod[0][24:4]       }:
                            ( qpdiv6 == 2 ) ? { {7{dprod[0][24]}}, dprod[0][24:3]       }:
                            ( qpdiv6 == 3 ) ? { {4{dprod[0][24]}}, dprod[0][24:2]       }:
                            ( qpdiv6 == 4 ) ? { {5{dprod[0][24]}}, dprod[0][24:1]       }:
                            ( qpdiv6 == 5 ) ? { {4{dprod[0][24]}}, dprod[0][24:0]       }:
                            ( qpdiv6 == 6 ) ? { {3{dprod[0][24]}}, dprod[0][24:0], 1'b0 }:
                            ( qpdiv6 == 7 ) ? { {2{dprod[0][24]}}, dprod[0][24:0], 2'b0 }:
                          /*( qpdiv6 == 8 )*/ { {1{dprod[0][24]}}, dprod[0][24:0], 3'b0 };                            
                end else if ( ii == 0 && ac_flag ) begin // get luma dc from dc hold and iquant
                    f[0] =  ( qpdiv6 == 0 ) ? {{10{dpofs[0][24]}}, dpofs[0][24:6]       }:
                            ( qpdiv6 == 1 ) ? { {9{dpofs[0][24]}}, dpofs[0][24:5]       }:
                            ( qpdiv6 == 2 ) ? { {8{dpofs[0][24]}}, dpofs[0][24:4]       }:
                            ( qpdiv6 == 3 ) ? { {7{dpofs[0][24]}}, dpofs[0][24:3]       }:
                            ( qpdiv6 == 4 ) ? { {6{dpofs[0][24]}}, dpofs[0][24:2]       }:
                            ( qpdiv6 == 5 ) ? { {5{dpofs[0][24]}}, dpofs[0][24:1]       }:
                            ( qpdiv6 == 6 ) ? { {4{dprod[0][24]}}, dprod[0][24:0]       }:
                            ( qpdiv6 == 7 ) ? { {3{dprod[0][24]}}, dprod[0][24:0], 1'b0 }:
                          /*( qpdiv6 == 8 )*/ { {2{dprod[0][24]}}, dprod[0][24:0], 2'b0 };                            
                end else begin // normal 4x4 quant
                    f[ii] = ( qpdiv6 == 0 ) ? { {8{dpofs[ii][24]}}, dpofs[ii][24:4]       }:
                            ( qpdiv6 == 1 ) ? { {7{dpofs[ii][24]}}, dpofs[ii][24:3]       }:
                            ( qpdiv6 == 2 ) ? { {6{dpofs[ii][24]}}, dpofs[ii][24:2]       }:
                            ( qpdiv6 == 3 ) ? { {5{dpofs[ii][24]}}, dpofs[ii][24:1]       }:
                            ( qpdiv6 == 4 ) ? { {4{dprod[ii][24]}}, dprod[ii][24:0]       }:
                            ( qpdiv6 == 5 ) ? { {3{dprod[ii][24]}}, dprod[ii][24:0], 1'b0 }:
                            ( qpdiv6 == 6 ) ? { {2{dprod[ii][24]}}, dprod[ii][24:0], 2'b0 }:
                            ( qpdiv6 == 7 ) ? { {1{dprod[ii][24]}}, dprod[ii][24:0], 3'b0 }:
                          /*( qpdiv6 == 8 )*/ {                     dprod[ii][24:0], 4'b0 };                            
            end
            end
        end
    end
	

	/////////////////////////////////////////
	// Inverse Transform (f->res)
	/////////////////////////////////////////

    logic [16:0] g[16];
    logic [16:0] h[16];
    logic [16:0] k[16];
    logic [16:0] m[16];
    
    always_comb begin
        for (int row = 0; row < 4; row++) begin // row 1d transforms
            g[row * 4 + 0][16:0] = {    f[row * 4 + 0][15]  , f[row * 4 + 0][15:0] } +               {    f[row * 4 + 2][15]  ,  f[row * 4 + 2][15:0] } ;
            g[row * 4 + 1][16:0] = {    f[row * 4 + 0][15]  , f[row * 4 + 0][15:0] } -               {    f[row * 4 + 2][15]  ,  f[row * 4 + 2][15:0] } ;
            g[row * 4 + 2][16:0] = ( ( dc_flag ) ? 
                                   {    f[row * 4 + 1][15]  , f[row * 4 + 1][15:0] } :
                                   { {2{f[row * 4 + 1][15]}}, f[row * 4 + 1][15:1] })-               {    f[row * 4 + 3][15]  ,  f[row * 4 + 3][15:0] } ;
            g[row * 4 + 3][16:0] = {    f[row * 4 + 1][15]  , f[row * 4 + 1][15:0] } +(( dc_flag ) ? {    f[row * 4 + 3][15]  ,  f[row * 4 + 3][15:0] } :
                                                                                                     { {2{f[row * 4 + 3][15]}},  f[row * 4 + 3][15:1] });
            h[row * 4 + 0][16:0] = {    g[row * 4 + 0][15]  , g[row * 4 + 0][15:0] } +               {    g[row * 4 + 3][15]  ,  g[row * 4 + 3][15:0] } ;
            h[row * 4 + 1][16:0] = {    g[row * 4 + 1][15]  , g[row * 4 + 1][15:0] } +               {    g[row * 4 + 2][15]  ,  g[row * 4 + 2][15:0] } ;
            h[row * 4 + 2][16:0] = {    g[row * 4 + 1][15]  , g[row * 4 + 1][15:0] } -               {    g[row * 4 + 2][15]  ,  g[row * 4 + 2][15:0] } ;
            h[row * 4 + 3][16:0] = {    g[row * 4 + 0][15]  , g[row * 4 + 0][15:0] } -               {    g[row * 4 + 3][15]  ,  g[row * 4 + 3][15:0] } ;
        end
        for (int col = 0; col < 4; col++) begin // col 1d transforms
            k[col + 4 * 0][16:0] = {    h[col + 4 * 0][15]  , h[col + 4 * 0][15:0] } +               {    h[col + 4 * 2][15]  ,  h[col + 4 * 2][15:0] } ;
            k[col + 4 * 1][16:0] = {    h[col + 4 * 0][15]  , h[col + 4 * 0][15:0] } -               {    h[col + 4 * 2][15]  ,  h[col + 4 * 2][15:0] } ;
            k[col + 4 * 2][16:0] = ( ( dc_flag ) ?  
                                   {    h[col + 4 * 1][15]  , h[col + 4 * 1][15:0] } :
                                   { {2{h[col + 4 * 1][15]}}, h[col + 4 * 1][15:1] })-               {    h[col + 4 * 3][15]  ,  h[col + 4 * 3][15:0] } ;
            k[col + 4 * 3][16:0] = {    h[col + 4 * 1][15]  , h[col + 4 * 1][15:0] } +(( dc_flag ) ? {    h[col + 4 * 3][15]  ,  h[col + 4 * 3][15:0] } :
                                                                                                     { {2{h[col + 4 * 3][15]}},  h[col + 4 * 3][15:1] });
            m[col + 4 * 0][16:0] = {    k[col + 4 * 0][15]  , k[col + 4 * 0][15:0] } +               {    k[col + 4 * 3][15]  ,  k[col + 4 * 3][15:0] } ;
            m[col + 4 * 1][16:0] = {    k[col + 4 * 1][15]  , k[col + 4 * 1][15:0] } +               {    k[col + 4 * 2][15]  ,  k[col + 4 * 2][15:0] } ;
            m[col + 4 * 2][16:0] = {    k[col + 4 * 1][15]  , k[col + 4 * 1][15:0] } -               {    k[col + 4 * 2][15]  ,  k[col + 4 * 2][15:0] } ;
            m[col + 4 * 3][16:0] = {    k[col + 4 * 0][15]  , k[col + 4 * 0][15:0] } -               {    k[col + 4 * 3][15]  ,  k[col + 4 * 3][15:0] } ;
        end    
    end


    // check for normative overflows.

    always_comb begin
        overflow[5:1] = 0;
        for ( int ii = 0; ii < 16; ii++ ) begin
            overflow[1] |= ~( (~(|f[ii][28:15])) | (&f[ii][28:15]) );
            overflow[2] |=  (     g[ii][16] ^ g[ii][15] );
            overflow[3] |=  (     h[ii][16] ^ h[ii][15] );
            overflow[4] |=  (     k[ii][16] ^ k[ii][15] );
            overflow[5] |=  (     m[ii][16] ^ m[ii][15] );
        end
    end

	// Save transformed DC values for later combination and quantization

    always_comb begin
        for( int ii = 0; ii < 16; ii++ ) begin
             dc_hold_dout[ii][15:0] = ( dc_flag &&  y_flag              || 
                                        dc_flag && cb_flag && (ii&2)==0 ||
                                        dc_flag && cr_flag && (ii&2)==2 ) ? m[ii][15:0] : dc_hold[ii][15:0];
        end
    end
    
	// construct residual samples

    logic [16:0] pre_sh_res[16];
    logic [10:0] res[16];

    always_comb begin
        for( int ii = 0; ii < 16; ii++ ) begin
            pre_sh_res[ii][16:0]= { m[ii][15], m[ii][15:0] } + 17'd32;
            res[ii][10:0] = pre_sh_res[ii][16:6];
        end
    end
    

	/////////////////////////////////////////
	// Recon and Distortion
	////////////////////////////////////////

    logic [12:0] recon_pre_clip[16];

    always_comb begin
        // Reconstruct
        for( int ii = 0; ii < 16; ii++ ) begin
            recon_pre_clip[ii][12:0] = { {2{res[ii][10]}}, res[ii][10:0] } + { 1'b0, pred[ii][11:0] };
            recon[ii][7:0] = ( recon_pre_clip[ii][12] ) ? 8'h00 : ( |recon_pre_clip[ii][11:8] ) ? 8'hFF : recon_pre_clip[ii][7:0];
        end
    end
    
endmodule
	

// vld word barrel shifter
// get current bits from anywhere in the input bitstream
module vld_shift_512 #(
    OWIDTH    = 28,
        MIN_SHIFT = 0,
        MAX_SHIFT = 512,
        WIDTH     = 512
        )
        ( 
    output logic [31:0] out,
    input  logic [511:0] in,
    input  logic [8:0] sel
        );
    logic [8:0] shift;
    logic [511:0] barrel[10]; 
    
    always_comb begin
        shift[8:0] = sel[8:0];
        for( int ii = 0; ii < 512; ii++ ) begin
            barrel[0][ii] = ( ii < MIN_SHIFT ) ? 1'b0 : ( ii > MAX_SHIFT + OWIDTH ) ? 1'b0 : in[ii]; // Zero unused inputs
            barrel[1][ii] = ( shift[8] ) ? (( ii >= 256 ) ? barrel[0][ii-256] : 1'b0 ) : barrel[0][ii];     
            barrel[2][ii] = ( shift[7] ) ? (( ii >= 128 ) ? barrel[1][ii-128] : 1'b0 ) : barrel[1][ii];
            barrel[3][ii] = ( shift[6] ) ? (( ii >=  64 ) ? barrel[2][ii- 64] : 1'b0 ) : barrel[2][ii];
            barrel[4][ii] = ( shift[5] ) ? (( ii >=  32 ) ? barrel[3][ii- 32] : 1'b0 ) : barrel[3][ii];
            barrel[5][ii] = ( shift[4] ) ? (( ii >=  16 ) ? barrel[4][ii- 16] : 1'b0 ) : barrel[4][ii];
            barrel[6][ii] = ( shift[3] ) ? (( ii >=   8 ) ? barrel[5][ii-  8] : 1'b0 ) : barrel[5][ii];
            barrel[7][ii] = ( shift[2] ) ? (( ii >=   4 ) ? barrel[6][ii-  4] : 1'b0 ) : barrel[6][ii];
            barrel[8][ii] = ( shift[1] ) ? (( ii >=   2 ) ? barrel[7][ii-  2] : 1'b0 ) : barrel[7][ii];
            barrel[9][ii] = ( shift[0] ) ? (( ii >=   1 ) ? barrel[8][ii-  1] : 1'b0 ) : barrel[8][ii];
        end
        out[31:32-OWIDTH] = barrel[9][511:512-OWIDTH]; // only select used output, synth remove the unused muxes
        out[31-OWIDTH:0] = 0;
    end    
endmodule
 