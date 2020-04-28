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

// Process a transform block
// Input: block predictor, original video, qpy, offset, deadzone and block index
// Output: recon, bitstream, sad, ssd, bitcount
module gg_process
   #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
    )
    (
    input wire clk,
    input wire [11:0]     orig[16],
    input wire [11:0]     pred[16],
    output logic [7:0]   recon[16],
    input wire [7:0] offset, // [0.8] with max of 128 to give 0.5 rounding
    input wire [15:0] deadzone, // [8.8], with effective min of 255
    input wire [5:0] qpy,
    input wire [2:0] cidx, // cidx={0-luma, 1-acluma, 2-cb, 3-cr, 4-dccb, 5-dccr, 6-dcy}
    input wire [3:0] bidx, // block IDX in h264 order
    output logic [11:0] sad, // 4x4 sum absolute difference
    output logic [19:0] ssd, // 4x4 sum of squared difference
    output logic [8:0] bitcount, // bitcount to code block
    output logic [511:0] bits, // output bits (max 501
    output logic [511:0] mask, // mask of valid output bits
    output logic [4:0] num_coeff, // Count of non-zero block coeffs
    input wire abv_out_of_pic,
    input wire left_out_of_pic,
    input wire [3:0][7:0] abv_nc,
    output logic [3:0][7:0] below_nc,
    output logic [6:0] overflow
    );
 
 

    // Flags
	wire dc_flag = ( cidx[2:0] == 4 || cidx[2:0] == 5 || cidx[2:0] == 6) ? 1'b1 : 1'b0;
	wire ac_flag = ( cidx[2:0] == 1 || cidx[2:0] == 2 || cidx[2:0] == 3) ? 1'b1 : 1'b0;
	wire ch_flag = ( cidx[2:0] == 2 || cidx[2:0] == 3 || cidx[2:0] == 4 || cidx[2:0] == 5) ? 1'b1 :1'b 0;    
	wire cb_flag = ( cidx[2:0] == 2 || cidx[2:0] == 4 ) ? 1'b1 : 1'b0;
	wire cr_flag = ( cidx[2:0] == 3 || cidx[2:0] == 5 ) ? 1'b1 : 1'b0;
	wire y_flag  = ( cidx[2:0] == 0 || cidx[2:0] == 1 || cidx[2:0] == 6 ) ? 1'b1 : 1'b0;
	
	/////////////////////////////////////////
	// Subtract Prediction
	/////////////////////////////////////////

    logic [12:0] a[16];
    always_comb begin
        for (int ii = 0; ii < 16; ii=ii+1) begin
            a[ii] = { 1'b0, orig[ii][11:0] } - { 1'b0, pred[ii][11:0] };
        end
    end
	
	/////////////////////////////////////////
	// Forward Transform (a->e)
	/////////////////////////////////////////

    logic [13:0] b[16];
    logic [15:0] c[16];
    logic [16:0] d[16];
    logic [18:0] e[16];
   
    always_comb begin
        for (int row = 0; row < 4; row++) begin // row 1d transforms
            b[row * 4 + 0][13:0] = {    a[row * 4 + 0][12]  , a[row * 4 + 0][12:0] } +               {    a[row * 4 + 3][12]  ,  a[row * 4 + 3][12:0]       } ;
            b[row * 4 + 1][13:0] = {    a[row * 4 + 1][12]  , a[row * 4 + 1][12:0] } +               {    a[row * 4 + 2][12]  ,  a[row * 4 + 2][12:0]       } ;
            b[row * 4 + 2][13:0] = {    a[row * 4 + 1][12]  , a[row * 4 + 1][12:0] } -               {    a[row * 4 + 2][12]  ,  a[row * 4 + 2][12:0]       } ;
            b[row * 4 + 3][13:0] = {    a[row * 4 + 0][12]  , a[row * 4 + 0][12:0] } -               {    a[row * 4 + 3][12]  ,  a[row * 4 + 3][12:0]       } ;
            c[row * 4 + 0][15:0] = { {2{b[row * 4 + 0][13]}}, b[row * 4 + 0][13:0] } +               { {2{b[row * 4 + 1][13]}},  b[row * 4 + 1][13:0]       } ;
            c[row * 4 + 1][15:0] = { {2{b[row * 4 + 2][13]}}, b[row * 4 + 2][13:0] } + ( dc_flag ) ? { {2{b[row * 4 + 3][13]}},  b[row * 4 + 3][13:0]       } : 
                                                                                                     {    b[row * 4 + 3][13]  ,  b[row * 4 + 3][13:0], 1'b0 } ;
            c[row * 4 + 2][15:0] = { {2{b[row * 4 + 0][13]}}, b[row * 4 + 0][13:0] } -               { {2{b[row * 4 + 1][13]}},  b[row * 4 + 1][13:0]       } ;
            c[row * 4 + 3][15:0] = { {2{b[row * 4 + 3][13]}}, b[row * 4 + 3][13:0] } - ( dc_flag ) ? { {2{b[row * 4 + 2][13]}},  b[row * 4 + 2][13:0]       } : 
                                                                                                     {    b[row * 4 + 2][13]  ,  b[row * 4 + 2][13:0], 1'b0 } ;
        end
        for (int col = 0; col < 4; col++) begin // col 1d transforms
            d[col + 4 * 0][16:0] = {    c[col + 4 * 0][15]  , c[col + 4 * 0][15:0] } +               {    c[col + 4 * 3][15]  ,  c[col + 4 * 3][15:0]       } ;
            d[col + 4 * 1][16:0] = {    c[col + 4 * 1][15]  , c[col + 4 * 1][15:0] } +               {    c[col + 4 * 2][15]  ,  c[col + 4 * 2][15:0]       } ;
            d[col + 4 * 2][16:0] = {    c[col + 4 * 1][15]  , c[col + 4 * 1][15:0] } -               {    c[col + 4 * 2][15]  ,  c[col + 4 * 2][15:0]       } ;
            d[col + 4 * 3][16:0] = {    c[col + 4 * 0][15]  , c[col + 4 * 0][15:0] } -               {    c[col + 4 * 3][15]  ,  c[col + 4 * 3][15:0]       } ;
            e[col + 4 * 0][18:0] = { {2{d[col + 4 * 0][16]}}, d[col + 4 * 0][16:0] } +               { {2{d[col + 4 * 1][16]}},  d[col + 4 * 1][16:0]       } ;
            e[col + 4 * 1][18:0] = { {2{d[col + 4 * 2][16]}}, d[col + 4 * 2][16:0] } + ( dc_flag ) ? { {2{d[col + 4 * 3][16]}},  d[col + 4 * 3][16:0]       } : 
                                                                                                     {    d[col + 4 * 3][16]  ,  d[col + 4 * 3][16:0], 1'b0 } ;
            e[col + 4 * 2][18:0] = { {2{d[col + 4 * 0][16]}}, d[col + 4 * 0][16:0] } -               { {2{d[col + 4 * 1][16]}},  d[col + 4 * 1][16:0]       } ;
            e[col + 4 * 3][18:0] = { {2{d[col + 4 * 3][16]}}, d[col + 4 * 3][16:0] } - ( dc_flag ) ? { {2{d[col + 4 * 2][16]}},  d[col + 4 * 2][16:0], 1'b0 } : 
                                                                                                     {    d[col + 4 * 2][16]  ,  d[col + 4 * 2][16:0], 1'b0 } ;
        end    
    end

	////////////////////////////////////////////////////
	// Foward Quantize (e->coeff), offset, deadzone
	////////////////////////////////////////////////////

    // const int qpc_table[52] = { 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,
    // 							29, 30, 31, 32, 32, 33, 34, 34,35,35,36,36,37,37,37,38,38,38,39,39,39,39 };
	// // Select qpy or derive qpc, and create mod6, div6 
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
  
    // Create forward quant matrix
    
    logic [0:5][13:0] fvmat0, fvmat1, fvmat2;
    logic [13:0] fvm0, fvm1, fvm2;
    logic [0:15][13:0] quant;
    assign fvmat0 = { 14'd13107, 14'd11916, 14'd10082, 14'd9362,14'd8192,14'd7282 };
    assign fvmat1 = { 14'd5243 , 14'd4660 , 14'd4194 , 14'd3647,14'd3355,14'd2893 };
    assign fvmat2 = { 14'd8066 , 14'd7490 , 14'd6554 , 14'd5825,14'd5243,14'd4559 };
    assign fvm0 = fvmat0[ qpmod6 ];
    assign fvm1 = fvmat1[ qpmod6 ];
    assign fvm2 = fvmat2[ qpmod6 ];
    assign quant = { { fvm0, fvm2, fvm0, fvm2 }, 
                     { fvm2, fvm1, fvm2, fvm1 }, 
                     { fvm0, fvm2, fvm0, fvm2 }, 
                     { fvm2, fvm1, fvm2, fvm1 } };
                                                                                                                         
	logic [18:0] abscoeff[16];
	logic [15:0] negcoeff;
	logic [32:0] quant_prod[16];
	logic [25:0] quant_shift1[16];
	logic [25:0] quant_shift2[16];
	logic [26:0] quant_ofs[16];
	logic [18:0] quant_dz[16];
	logic [11:0] quant_clip[16];
	logic signed [19:0] coeff[16];

 	// Forward quant 16 coeffs
	
    always_comb begin
        for( int ii = 0; ii < 16; ii++ ) begin
            negcoeff[ii]       =   e[18];
            abscoeff[ii][18:0] = ( e[18] ) ? ( ~e[ii][18:0] + 19'd1 ) : e[ii][18:0];
            quant_prod[ii][32:0]   = abscoeff[ii][18:0] * quant[ii][13:0];
            quant_shift1[ii][25:0] = ( !ch_flag && dc_flag ) ? { 2'b0, quant_prod[ii][32:9] } : 
                                     (  ch_flag && dc_flag ) ? { 1'b0, quant_prod[ii][32:8] } :
                                                               {       quant_prod[ii][32:7] } ;
            quant_shift2[ii][25:0] = ( qpdiv6[3:0] == 4'd0 ) ? {       quant_shift1[ii][25:0] } :
                                     ( qpdiv6[3:0] == 4'd1 ) ? { 1'b0, quant_shift1[ii][25:1] } : 
                                     ( qpdiv6[3:0] == 4'd2 ) ? { 2'b0, quant_shift1[ii][25:2] } : 
                                     ( qpdiv6[3:0] == 4'd3 ) ? { 3'b0, quant_shift1[ii][25:3] } : 
                                     ( qpdiv6[3:0] == 4'd4 ) ? { 4'b0, quant_shift1[ii][25:4] } : 
                                     ( qpdiv6[3:0] == 4'd5 ) ? { 5'b0, quant_shift1[ii][25:5] } : 
                                     ( qpdiv6[3:0] == 4'd6 ) ? { 6'b0, quant_shift1[ii][25:6] } : 
                                     ( qpdiv6[3:0] == 4'd7 ) ? { 7'b0, quant_shift1[ii][25:7] } : 
                                   /*( qpdiv6[3:0] == 4'd8 )*/ { 8'b0, quant_shift1[ii][25:8] } ;
            quant_ofs[ii][26:0] = { 1'b0, quant_shift2[ii][25:0] } + { 19'd0, offset[7:0] };
            quant_dz[ii][18:0]  = ( quant_ofs[ii][26:0] > { 11'd0, deadzone[15:0] } ) ? quant_ofs[ii][26:8] : 0;
            // Note: max encodable coeff, in general is -2063 to 2063 (suffix len = 0 or 1), but up to +/-2528 with suffix lenth 6
            // Do a quick clip here to fit the coeff and let coeff coding take care of exact flagging.
            // Upon error should bypass as PCM, and/or requant the block as coeffs are too large, or just accept clipping.
            quant_clip[ii][11:0] = ( quant_dz[ii][18:0] > 19'hFFF ) ? 12'hFFF : quant_dz[ii][11:0]; 
            coeff[ii][12:0]     = ( negcoeff[ii] ) ? { 1'b1, ~quant_clip[ii][11:0] + 1 } : { 1'b0, quant_clip[ii][11:0] };
        end
    end
   
    // Flag coeff overflow, coeff to large for prefix 15. 
    always_comb begin
        overflow[0] = 0;
        for( int ii = 0; ii < 16; ii++ ) begin
            overflow[0] |= |quant_dz[ii][18:12];
        end
    end

	//////////////////////////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////////////////////////
	//                         >>>>>>>>> coeff[16] <<<<<<<<<<<<<<
	//           Now we have coefficients to: 1) entropy encode 2) reconstruct
	//////////////////////////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////////////////////////


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
    assign dquant = { { dvm0, dvm2, dvm0, dvm2 }, 
                      { dvm2, dvm1, dvm2, dvm1 }, 
                      { dvm0, dvm2, dvm0, dvm2 }, 
                      { dvm2, dvm1, dvm2, dvm1 } };



    reg [15:0] dc_hold [2][16];

    logic [28:0] f[16];
    logic signed [24:0] dprod[16]; // 13 bit signed coeff * 5+4 bit quant
    logic signed [24:0] dpofs[16]; // with rounding offset
    logic signed [15:0] dcoeff[16];

    always_comb begin
        if( dc_flag ) begin // if DC coeff, defer quant until AC, just copy
            if( ch_flag ) begin // relocate chroma DC and zero remainder
                for( int ii = 0; ii < 16; ii++ ) begin
                    f[ii] = 29'd0;
                end
                f[ 0][28:0] = { 16'b0, coeff[0][12:0] };
                f[ 2][28:0] = { 16'b0, coeff[1][12:0] };
                f[ 8][28:0] = { 16'b0, coeff[4][12:0] };
                f[10][28:0] = { 16'b0, coeff[5][12:0] };
            end else begin // just copy thru luma DC
                for( int ii = 0; ii < 16; ii++ ) begin
                    f[ii][28:0] = { 16'b0, coeff[ii][12:0] };
                end
            end 
        end else begin // Inverse quant the ac coeffs, bring in the inverse DC
            for( int ii = 0; ii < 16; ii++ ) begin
                dcoeff[ii][15:0] = ( ii == 0 && ac_flag && cr_flag ) ? dc_hold[2][{ 1'b0, bidx[1], 1'b0, bidx[0] }][15:0] : // sample 0,1,4,5
                                   ( ii == 0 && ac_flag && cb_flag ) ? dc_hold[1][{ 1'b0, bidx[1], 1'b0, bidx[0] }][15:0] : // sample 0,1,4,5
                                   ( ii == 0 && ac_flag &&  y_flag ) ? dc_hold[0][bidx[3:0]][15:0] : // luma dc coeff
                                                                       { {3{coeff[ii][12]}}, coeff[ii][12:0] }; // regular coeff
                dprod[ii][24:0] = dcoeff[ii][15:0] * { dquant[ii][4:0], 4'b0000 };
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
                          /*( qpdiv6 == 8 )*/ {                    dprod[ii][24:0], 4'b0 };                            
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
            g[row * 4 + 3][16:0] = {    f[row * 4 + 1][15]  , f[row * 4 + 1][15:0] } - ( dc_flag ) ? {    f[row * 4 + 3][15]  ,  f[row * 4 + 3][15:0] } :
                                                                                                     { {2{f[row * 4 + 3][15]}},  f[row * 4 + 3][15:1] } ;
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
            k[col + 4 * 3][16:0] = {    h[col + 4 * 1][15]  , h[col + 4 * 1][15:0] } - ( dc_flag ) ? {    h[col + 4 * 3][15]  ,  h[col + 4 * 3][15:0] } :
                                                                                                     { {2{h[col + 4 * 3][15]}},  h[col + 4 * 3][15:1] } ;
            m[col + 4 * 0][16:0] = {    k[col + 4 * 0][15]  , k[col + 4 * 0][15:0] } +               {    k[col + 4 * 3][15]  ,  k[col + 4 * 3][15:0] } ;
            m[col + 4 * 1][16:0] = {    k[col + 4 * 1][15]  , k[col + 4 * 1][15:0] } +               {    k[col + 4 * 2][15]  ,  k[col + 4 * 2][15:0] } ;
            m[col + 4 * 2][16:0] = {    k[col + 4 * 1][15]  , k[col + 4 * 1][15:0] } -               {    k[col + 4 * 2][15]  ,  k[col + 4 * 2][15:0] } ;
            m[col + 4 * 3][16:0] = {    k[col + 4 * 0][15]  , k[col + 4 * 0][15:0] } -               {    k[col + 4 * 3][15]  ,  k[col + 4 * 3][15:0] } ;
        end    
    end


    // check for normative overflows.

    logic [4:0] f_overflow;

    always_comb begin
        f_overflow[5:1] = 0;
        for ( int ii = 0; ii < 16; ii++ ) begin
            f_overflow[1] = f_overflow[1] | ~( (~(|f[ii][28:15])) | (&f[ii][28:15]) );
            f_overflow[2] = f_overflow[2] |  (     g[ii][16] ^ g[ii][15] );
            f_overflow[3] = f_overflow[3] |  (     h[ii][16] ^ h[ii][15] );
            f_overflow[4] = f_overflow[4] |  (     k[ii][16] ^ k[ii][15] );
            f_overflow[5] = f_overflow[5] |  (     m[ii][16] ^ m[ii][15] );
        end
    end

	// Save transformed DC values for later combination and quantization

    always_ff @(posedge clk) begin
        if( dc_flag ) begin
            for( int ii = 0; ii < 16; ii++ ) begin
                if( y_flag ) begin
                    dc_hold[0][ii][15:0] <= m[ii][15:0];
                end
                if( cb_flag ) begin
                    dc_hold[1][ii][15:0] <= m[ii][15:0];
                end
                if( cr_flag ) begin
                    dc_hold[2][ii][15:0] <= m[ii][15:0];
                end
            end
        end
    end
    
	// construct residual samples

    logic [16:0] pre_sh_res[16];
    logic [10:0] res[16];

    always_comb begin
        for( int ii = 0; ii < 16; ii++ ) begin
            pre_sh_res[ii][16:0]= { 1'b0, m[ii][15:0] } + 17'd32;
            res[ii][10:0] = pre_sh_res[ii][16:6];
        end
    end
    

	/////////////////////////////////////////
	// Recon and Distortion
	////////////////////////////////////////


    logic [12:0] recon_pre_clip[16];
    logic [8:0] rdiff[16];
    logic [7:0] rabs[16];
    logic [19:0] rsqr[16];

    always_comb begin
        // Reconstruct
        for( int ii = 0; ii < 16; ii++ ) begin
            recon_pre_clip[ii][12:0] = { {2{res[ii][10]}}, res[ii][10:0] } + { 1'b0, pred[ii][11:0] };
            recon[ii][7:0] = ( recon_pre_clip[ii][12] ) ? 8'h00 : ( |recon_pre_clip[ii][11:8] ) ? 8'hFF : recon_pre_clip[ii][7:0];
        end
        // Measure Reconstruction Distortion
        for( int ii = 0; ii < 16; ii++ ) begin
            rdiff[ii] = { 1'b0, recon[ii] } - { 1'b0, orig[ii] };
            rabs[ii] = ( rdiff[ii][8] ) ? (~rdiff[ii][7:0] + 1) : rdiff[ii][7:0];
            rsqr[ii][19:0] = { 4'b0000, rabs[ii][7:0] * rabs[ii][7:0] };
        end
        // Sum Distortions
        ssd[19:0] =(( rsqr[ 0] + rsqr[ 1] ) + ( rsqr[ 2] + rsqr[ 3] ) +
                    ( rsqr[ 4] + rsqr[ 5] ) + ( rsqr[ 4] + rsqr[ 5] )) +
                   (( rsqr[ 8] + rsqr[ 9] ) + ( rsqr[10] + rsqr[11] ) +
                    ( rsqr[12] + rsqr[13] ) + ( rsqr[14] + rsqr[15] ));
        sad[11:0] =(( { 4'b0, rabs[ 0] } + { 4'b0, rabs[ 1] } ) + ( { 4'b0, rabs[ 2] } + { 4'b0, rabs[ 3] } ) +
                    ( { 4'b0, rabs[ 4] } + { 4'b0, rabs[ 5] } ) + ( { 4'b0, rabs[ 4] } + { 4'b0, rabs[ 5] } )) +
                   (( { 4'b0, rabs[ 8] } + { 4'b0, rabs[ 9] } ) + ( { 4'b0, rabs[10] } + { 4'b0, rabs[11] } ) +
                    ( { 4'b0, rabs[12] } + { 4'b0, rabs[13] } ) + ( { 4'b0, rabs[14] } + { 4'b0, rabs[15] } ));
    end

	//////////////////////////////////////////
	//////////////////////////////////////////
	//         VLC CaVLC Encoding
	//////////////////////////////////////////
	//////////////////////////////////////////

	//////////////////////////////////////////
	// Zigzag scan convert block coeffs
	//////////////////////////////////////////

    logic [15:0][12:0] scan;
    logic [4:0] max_coeff;
    logic [15:0] sig_coeff_flag;
    logic [4:0] last_coeff;
    logic [4:0] total_zeros;
    
	// int scan[16]; // dc->hf ordered coefficient list
	// int zigzag4x4[16] = { 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
	// int zigzag2x2[4] = { 0, 1, 4, 5 };
	
    assign max_coeff[4:0] = ( ch_flag && dc_flag ) ? 5'd4 : ( ac_flag ) ? 5'd15 : 5'd16; 
    
    assign scan = ( ch_flag && dc_flag ) ? { {12{13'd0}}, coeff[5], coeff[4], coeff[1], coeff[0] } :
                  ( ac_flag ) ? { 13'd0    ,coeff[15],coeff[14],coeff[11],coeff[ 7],coeff[10],coeff[13],coeff[12],
                                  coeff[ 9],coeff[ 6],coeff[ 3],coeff[ 2],coeff[ 5],coeff[ 8],coeff[ 4],coeff[ 1] } :
                                { coeff[15],coeff[14],coeff[11],coeff[ 7],coeff[10],coeff[13],coeff[12],coeff[ 9],
                                  coeff[ 6],coeff[ 3],coeff[ 2],coeff[ 5],coeff[ 8],coeff[ 4],coeff[ 1],coeff[ 0] } ;
    
    always_comb begin
        for( int ii = 0; ii < 16; ii++ ) begin
            sig_coeff_flag[ii] = |scan[ii];
        end
        num_coeff = ( ( ( { 4'd0, sig_coeff_flag[ 0] } + { 4'd0, sig_coeff_flag[ 1] } ) + ( { 4'd0, sig_coeff_flag[ 2] } + { 4'd0, sig_coeff_flag[ 3] } ) )   +
                      ( ( { 4'd0, sig_coeff_flag[ 4] } + { 4'd0, sig_coeff_flag[ 5] } ) + ( { 4'd0, sig_coeff_flag[ 6] } + { 4'd0, sig_coeff_flag[ 7] } ) ) ) +
                    ( ( ( { 4'd0, sig_coeff_flag[ 8] } + { 4'd0, sig_coeff_flag[ 9] } ) + ( { 4'd0, sig_coeff_flag[10] } + { 4'd0, sig_coeff_flag[11] } ) )   +
                      ( ( { 4'd0, sig_coeff_flag[12] } + { 4'd0, sig_coeff_flag[13] } ) + ( { 4'd0, sig_coeff_flag[14] } + { 4'd0, sig_coeff_flag[15] } ) ) ) ;

        last_coeff = 0;
        for( int ii = 16; ii > 0; ii-- ) 
            if( last_coeff == 0 && sig_coeff_flag[ii-1] )
                last_coeff = ii;
         total_zeros = last_coeff - num_coeff;
    end

	//////////////////////////////////////////
	// Syntax Element: Trailing_ones_sign_flag
	//////////////////////////////////////////


    logic [15:0] one_flag;
    logic [15:0] gt1_flag;
    logic [16:0][1:0] t1_count;
    logic [1:0] trailing_ones;
    logic [15:0][2:0] sign_flag;
    logic [71:0] vlc32_trailing_ones;
    always_comb begin
        for( int ii = 0; ii < 16; ii++ ) begin
            one_flag[ii] = ( scan[ii] == 13'h1 || scan[ii] == 13'h1FFF ) ? 1'b1 : 1'b0; // abs(scan[ii])==1
        end
        for( int ii = 15; ii >= 0; ii-- ) begin // flag from 1st sig coeff >= 2 
            gt1_flag[ii] = ( ii == 15 && !one_flag[15] && scan[15] != 0 ) ? 1'b1 : 
                           ( gt1_flag[ii+1] || ( !one_flag[ii] && scan[ii] != 0 ) ) ? 1'b1 : 1'b0;
        end
        t1_count[16] = 2'd0;
        for( int ii = 15; ii >= 0; ii-- ) begin // need to stop at first scan coeff > 1
            t1_count[ii] = ( ii = 15 )             ? { 1'b0, one_flag[15] } :
                           ( t1_count[ii+1] == 3 ) ?   2'd3 : 
                           ( !gt1_flag[ii] )       ? ( t1_count[ii+1] + { 1'b0, one_flag[ii] } ) : 
                                                       t1_count[ii+1];
        end
        trailing_ones = t1_count[0];
        for( int ii = 15; ii >= 0; ii-- ) begin
            sign_flag[ii][0] = ( ii == 15 ) ? ( one_flag[15] & scan[15][12] ) : 
                               ( t1_count[ii] == 2'd1 && t1_count[ii+1] == 2'd0 ) ? scan[ii][12] : sign_flag[ii+1][0];
            sign_flag[ii][1] = ( ii == 15 ) ? 1'b0 : 
                               ( t1_count[ii] == 2'd2 && t1_count[ii+1] == 2'd1 ) ? scan[ii][12] : sign_flag[ii+1][1];
            sign_flag[ii][2] = ( ii == 15 || ii == 14 ) ? 1'b0 : 
                               ( t1_count[ii] == 2'd3 && t1_count[ii+1] == 2'd2 ) ? scan[ii][12] : sign_flag[ii+1][2];
        end
        vlc32_trailing_ones = ( trailing_ones == 2'd0 ) ? { 32'b0, 32'b0, 8'd0 } :
                              ( trailing_ones == 2'd1 ) ? { 31'b0, sign_flag[0][0], 32'b1, 8'd1 } :
                              ( trailing_ones == 2'd2 ) ? { 30'b0, sign_flag[0][1:0], 32'b11, 8'd2 } :
                            /*( trailing_ones == 2'd3 )*/ { 29'b0, sign_flag[0][2:0], 32'b111, 8'd3 }; 
    end

	//////////////////////////////////////////
	// Syntax Element: Coeff_token
	//////////////////////////////////////////

    // TODO: need to handle abv/left interfacing
    // TO SOLVE: pcm over-ride changes na to 16, RACE
    
    logic [71:0] vlc32_coeff_token;
    logic [2:0] coeff_idx;
    logic [4:0] na, nb, nc;
    logic [5:0] nab;
    
    reg [4:0] left_y_nc_reg[4], abv_y_nc_reg[4];
    reg [4:0] left_cb_nc_reg[2], abv_cb_nc_reg[2];
    reg [4:0] left_cr_nc_reg[2], abv_cr_nc_reg[2];
    
    assign na = ( cb_flag && dc_flag ) ? left_cb_nc_reg[0] :
                ( cr_flag && dc_flag ) ? left_cr_nc_reg[0] :
                (  y_flag && dc_flag ) ? left_y_nc_reg[0] :
                ( cb_flag            ) ? left_cb_nc_reg[ bidx[1] ] :
                ( cr_flag            ) ? left_cr_nc_reg[ bidx[1] ] :
                                         left_y_nc_reg[ { bidx[3], bidx[1] } ];
                              
    assign nb = ( cb_flag && dc_flag ) ? abv_cb_nc_reg[0] :
                ( cr_flag && dc_flag ) ? abv_cr_nc_reg[0] :
                (  y_flag && dc_flag ) ? abv_y_nc_reg[0] :
                ( cb_flag            ) ? abv_cb_nc_reg[ bidx[0] ] :
                ( cr_flag            ) ? abv_cr_nc_reg[ bidx[0] ] :
                                         abv_y_nc_reg[ { bidx[2], bidx[0] } ];

    assign nab[5:0] = { 1'b0, na[4:0] } + { 1'b0, nb[4:0] } + 6'd1;
    
    assign nc = ( left_out_of_pic && abv_out_of_pic && bidx == 0 ) ? 5'd0 :
                ( left_out_of_pic && ( bidx == 0 || bidx == 2 || bidx == 8 || bidx == 10 ) ) ? nb[4:0] :
                ( abv_out_of_pic  && ( bidx == 0 || bidx == 1 || bidx == 4 || bidx == 5  ) ) ? na[4:0] : nab[5:1];
    
    assign coeff_idx = ( ch_flag && dc_flag ) ? 3'd4 :
                       ( |nc[4:3]           ) ? 3'd3 : // nc >= 8
                       ( nc[2]              ) ? 3'd2 : // 4 <= nc < 8
                       ( nc[1]              ) ? 3'd1 : // 2 <= nc < 4
                                                3'd0 ; // 0 <= nc < 2 

    table_9_5_coeff_token coeff_token_table_
    (
        .num_coeff      ( num_coeff[4:0]     ),
        .trailing_ones  ( trailing_ones[1:0] ),
        .table_idx      ( coeff_idx[2:0]     ),
        .vlc32          ( vlc32_coeff_token )
    );  

    // Update nc context
    
    always_ff @(posedge clk) begin
        if( !dc_flag ) begin
            if( y_flag ) begin
                left_y_nc_reg[ { bidx[3], bidx[1] } ] = num_coeff[4:0];
                abv_y_nc_reg[  { bidx[2], bidx[1] } ] = num_coeff[4:0];
            end else if ( cb_flag ) begin
                left_cb_nc_reg[ bidx[0] ] = num_coeff[4:0];
                abv_cb_nc_reg[  bidx[1] ] = num_coeff[4:0];
            end else begin // cr flag
                left_cr_nc_reg[ bidx[0] ] = num_coeff[4:0];
                abv_cr_nc_reg[  bidx[1] ] = num_coeff[4:0];
            end
        end
    end


	//////////////////////////////////////////
	// Syntax Element: Total zeros
	//////////////////////////////////////////

    logic [71:0] vlc32_total_zeros_2x2;
    logic [71:0] vlc32_total_zeros_4x4;
    logic [71:0] vlc32_total_zeros;
    
    table_9_9_total_zeros_2x2 total_zeros_2x2_
    (
        .num_coeff( num_coeff[1:0] ),
        .total_zeros( total_zeros[1:0] ),
        .vlc32( vlc32_total_zeros )
    );

    table_9_8_total_zeros_4x4 total_zeros_4x4_
    (
        .num_coeff( num_coeff[3:0] ),
        .total_zeros( total_zeros[3:0] ),
        .vlc32( vlc32_total_zeros )
    );

    assign vlc32_total_zeros = ( num_coeff == max_coeff || num_coeff == 0 ) ? 72'b0 :
                               ( dc_flag && ch_flag ) ? vlc32_total_zeros_2x2 : 
                                                        vlc32_total_zeros_4x4 ;
                                                        
	//////////////////////////////////////////
	// Syntax Element: Run_before[]
	//////////////////////////////////////////

    logic [71:0] vlc32_run_before[14];
    logic [3:0] run_before[16];
    logic [3:0] zeros_left[16];
    logic [15:0] first_sig_coeff;
    logic [15:0] valid_run;

    always_comb begin
        for( int ii = 15; ii >= 0; ii-- ) begin
            first_sig_coeff[ii] = ( ii == 15             ) ? 1'b1 : 
                                  ( sig_coeff_flag[ii+1] ) ? 1'b0 : 
                                                             first_sig_coeff[ii+1];
            run_before[ii] = ( ii == 15                  ) ? 4'd0 : 
                             ( first_sig_coeff[ii]       ) ? 4'd0 :
                             ( sig_coeff_flag[ii]        ) ? 4'd0 : 
                                                             (run_before[ii] + 4'd1);
            zeros_left[ii] = ( ii == 15                  ) ? total_zeros :
                             ( sig_coeff_flag[ii] && zeros_left[ii+1] == 4'd0 ) ? 4'd0 :
                             ( sig_coeff_flag[ii] ) ? zeros_left[ii+1] - run_before[ii] : 
                                                             run_before[ii];
        end
    end                               
                               
    // Run before lookup table
    table_9_10_run_before run_before_table_0  ( .run_before( run_before[ 0][3:0]), .zeros_left( zeros_left[ 0][3:0]), .vlc32( vlc32_run_before[ 0][71:0]) );
    table_9_10_run_before run_before_table_1  ( .run_before( run_before[ 1][3:0]), .zeros_left( zeros_left[ 1][3:0]), .vlc32( vlc32_run_before[ 1][71:0]) );
    table_9_10_run_before run_before_table_2  ( .run_before( run_before[ 2][3:0]), .zeros_left( zeros_left[ 2][3:0]), .vlc32( vlc32_run_before[ 2][71:0]) );
    table_9_10_run_before run_before_table_3  ( .run_before( run_before[ 3][3:0]), .zeros_left( zeros_left[ 3][3:0]), .vlc32( vlc32_run_before[ 3][71:0]) );
    table_9_10_run_before run_before_table_4  ( .run_before( run_before[ 4][3:0]), .zeros_left( zeros_left[ 4][3:0]), .vlc32( vlc32_run_before[ 4][71:0]) );
    table_9_10_run_before run_before_table_5  ( .run_before( run_before[ 5][3:0]), .zeros_left( zeros_left[ 5][3:0]), .vlc32( vlc32_run_before[ 5][71:0]) );
    table_9_10_run_before run_before_table_6  ( .run_before( run_before[ 6][3:0]), .zeros_left( zeros_left[ 6][3:0]), .vlc32( vlc32_run_before[ 6][71:0]) );
    table_9_10_run_before run_before_table_7  ( .run_before( run_before[ 7][3:0]), .zeros_left( zeros_left[ 7][3:0]), .vlc32( vlc32_run_before[ 7][71:0]) );
    table_9_10_run_before run_before_table_8  ( .run_before( run_before[ 8][3:0]), .zeros_left( zeros_left[ 8][3:0]), .vlc32( vlc32_run_before[ 8][71:0]) );
    table_9_10_run_before run_before_table_9  ( .run_before( run_before[ 9][3:0]), .zeros_left( zeros_left[ 9][3:0]), .vlc32( vlc32_run_before[ 9][71:0]) );
    table_9_10_run_before run_before_table_10 ( .run_before( run_before[10][3:0]), .zeros_left( zeros_left[10][3:0]), .vlc32( vlc32_run_before[10][71:0]) );
    table_9_10_run_before run_before_table_11 ( .run_before( run_before[11][3:0]), .zeros_left( zeros_left[11][3:0]), .vlc32( vlc32_run_before[11][71:0]) );
    table_9_10_run_before run_before_table_12 ( .run_before( run_before[12][3:0]), .zeros_left( zeros_left[12][3:0]), .vlc32( vlc32_run_before[12][71:0]) );
    table_9_10_run_before run_before_table_13 ( .run_before( run_before[13][3:0]), .zeros_left( zeros_left[13][3:0]), .vlc32( vlc32_run_before[13][71:0]) );

	///////////////////////////////////////////////
	// Syntax Element: level_prefix, level_suffix
	///////////////////////////////////////////////
	
	
    logic [2:0] suffix_length[17];
    logic [11:0] abs_coeff[16];
    logic [15:0] enc_coeff; // flag to suffix/prefix code a scan coeff

    always_comb begin
        suffix_length[16][2:0] = ( num_coeff[4:0] > 5'd10 && trailing_ones[1:0] < 2'd3 ) ? 3'd1 : 3'd0;
        for( int ii = 15; ii >= 0; ii-- ) begin
            abs_coeff[ii] = ( scan[ii][12] ) ? ( ~scan[ii][11:0] + 12'd1 ) : scan[ii][11:0];
            enc_coeff[ii] = ( sig_coeff_flag[ii] && t1_count[ii+1][1:0] == trailing_ones[1:0] ) ? 1'b1 : 1'b0;
            suffix_length[ii] = ( !enc_coeff[ii] ) ? suffix_length[ii+1] :
                                ( suffix_length[ii+1] == 0 && abs_coeff[ii+1][11:0] > 12'd3  ) ? 3'd2 :
                                ( suffix_length[ii+1] == 0                                   ) ? 3'd1 :
                                ( suffix_length[ii+1] == 1 && abs_coeff[ii+1][11:0] > 12'd3  ) ? 3'd2 :
                                ( suffix_length[ii+1] == 2 && abs_coeff[ii+1][11:0] > 12'd6  ) ? 3'd3 :
                                ( suffix_length[ii+1] == 3 && abs_coeff[ii+1][11:0] > 12'd12 ) ? 3'd4 :
                                ( suffix_length[ii+1] == 4 && abs_coeff[ii+1][11:0] > 12'd24 ) ? 3'd5 :
                                ( suffix_length[ii+1] == 5 && abs_coeff[ii+1][11:0] > 12'd48 ) ? 3'd2 :  3'd6 ;
        end
    end                               

    // Calculate level code
    logic [12:0] level_code[16];
    logic special_coeff[16];
    logic [4:0] sig_count[17];
    always_comb begin
        sig_count[16] = 5'd0;
        for( int ii = 15; ii >= 0; ii++ ) begin
            sig_count[ii][4:0] = sig_count[ii+1][4:0] + { 4'b0000, sig_coeff_flag[ii] }; 
            special_coeff[ii] = ( sig_count[ii+1] == { 3'b000, trailing_ones[ii+1][1:0] } ) ? 1'b1 : 1'b0;
        end
        for( int ii = 0; ii < 16; ii++ ) begin
            if( !enc_coeff[ii] ) begin
                level_code[ii][12:0] = 13'd0;
            end else begin
                level_code[ii][12:0] =  ( ( scan[ii][12] ) ? { (scan[ii][12:0] - 13'd1), 1'b0 } : { ~scan[ii][12:0], 1'b1 } ) - ( ( special_coeff[ii] ) ? 13'd2 : 13'd0 );      
            end
        end
    end                               

    // prefix+suffix vlc code coefficients
    logic [71:0] vlc32_prefix_suffix_coeff[16];
    logic [6:0][12:0] p15_thresh = { 13'd960, 13'd480, 13'd240, 13'd120, 13'd 60, 13'd30, 13'd30 }; 
    logic [15:0] p15_suffix_diff[16];
    logic [14:0][15:0] mask_tbl = { 16'h7FFF, 16'h3FFF, 16'h1FFF, 16'hFFF, 16'h7FF, 16'h3FF, 16'h1FF, 16'hFF, 16'h7F, 16'h3F, 16'h1F, 16'hF, 16'h7, 16'h3, 16'h1 };
    always_comb begin
        overflow[6] = 0;
        for( int ii = 0; ii < 16; ii++ ) begin
            if( !enc_coeff[ii] ) begin
                vlc32_prefix_suffix_coeff[ii] = { 32'h0, 32'h0, 8'd0 };
            end else if ( level_code[ii][12:0] >= ( p15_thresh[suffix_length[ii+1]][12:0] + 13'd4096 ) ) begin
                overflow[6] |= 1'b1; // Mark this as an overflow error
                vlc32_prefix_suffix_coeff[ii][ 7: 0] = 8'd28; // Length = 28 = 15 + 1 + 12
                vlc32_prefix_suffix_coeff[ii][39: 8] = 32'hFFF_FFFF; // mask
                vlc32_prefix_suffix_coeff[ii][51:40] = { 12'hFFE, level_code[ii][0] }; // clip with correct odd/even sign 
                vlc32_prefix_suffix_coeff[ii][71:52] = 20'b1; // end of prefix bits
            end else if ( level_code[ii] >= p15_thresh[suffix_length[ii+1]] ) begin // prefix = 15 coding
                overflow[6] |= ( level_code[ii][12:0] - p15_thresh[suffix_length[ii+1]][12:0] >= 13'hFFF ) ? 1'b1 : 1'b0;
                vlc32_prefix_suffix_coeff[ii][ 7: 0] = 8'd28; // Length = 28 = 15 + 1 + 12
                vlc32_prefix_suffix_coeff[ii][39: 8] = 32'hFFF_FFFF; // mask
                vlc32_prefix_suffix_coeff[ii][51:40] = 13'hFFF & (level_code[ii][12:0] - p15_thresh[suffix_length[ii+1]][12:0]); 
                vlc32_prefix_suffix_coeff[ii][71:52] = 20'b1; // end of prefix bits
            end else if ( suffix_length[ii+1] == 3'd0 && level_code[ii][12:0] >= 13'd14 ) begin // prefix , 4 bit special case
                vlc32_prefix_suffix_coeff[ii][ 7: 0] = 8'd19; // Length = 14 + 1 + 4 = 19
                vlc32_prefix_suffix_coeff[ii][39: 8] = 32'h7_FFFF; // mask
                vlc32_prefix_suffix_coeff[ii][43:40] = 13'hF & ( level_code[ii][12:0] - 13'd14 ); 
                vlc32_prefix_suffix_coeff[ii][71:44] = 28'b1; // end of prefix bits
            end else if( suffix_length[ii+1] == 3'd6 ) begin // prefix 0 to 13 unary with suffix len = 6
                vlc32_prefix_suffix_coeff[ii][ 7: 0] = { 4'b0, level_code[ii][9:6] } + 8'd7; // length 
                vlc32_prefix_suffix_coeff[ii][39: 8] = { 10'b0, ( mask_tbl[level_code[ii][9:6]][15:0] ), 6'b111111 }; // mask
                vlc32_prefix_suffix_coeff[ii][45:40] = level_code[ii][5:0]; // end of prefix bits
                vlc32_prefix_suffix_coeff[ii][71:46] = 26'b1; // end of prefix bits
            end else if( suffix_length[ii+1] == 3'd5 ) begin // prefix 0 to 13 unary with suffix len = 5
                vlc32_prefix_suffix_coeff[ii][ 7: 0] = { 4'b0, level_code[ii][8:5] } + 8'd6; // length 
                vlc32_prefix_suffix_coeff[ii][39: 8] = { 11'b0, ( mask_tbl[level_code[ii][8:5]][15:0] ), 5'b11111 }; // mask
                vlc32_prefix_suffix_coeff[ii][44:40] = level_code[ii][4:0]; // end of prefix bits
                vlc32_prefix_suffix_coeff[ii][71:45] = 27'b1; // end of prefix bits
            end else if( suffix_length[ii+1] == 3'd4 ) begin // prefix 0 to 13 unary with suffix len = 4
                vlc32_prefix_suffix_coeff[ii][ 7: 0] = { 4'b0, level_code[ii][7:4] } + 8'd5; // length
                vlc32_prefix_suffix_coeff[ii][39: 8] = { 12'b0, ( mask_tbl[level_code[ii][7:4]][15:0] ), 4'b1111 }; // mask
                vlc32_prefix_suffix_coeff[ii][43:40] = level_code[ii][3:0]; // end of prefix bits
                vlc32_prefix_suffix_coeff[ii][71:44] = 28'b1; // end of prefix bits
            end else if( suffix_length[ii+1] == 3'd3 ) begin // prefix 0 to 13 unary with suffix len = 3
                vlc32_prefix_suffix_coeff[ii][ 7: 0] = { 4'b0, level_code[ii][6:3] } + 8'd4; // length
                vlc32_prefix_suffix_coeff[ii][39: 8] = { 13'b0, ( mask_tbl[level_code[ii][6:3]][15:0] ), 3'b111 }; // mask
                vlc32_prefix_suffix_coeff[ii][42:40] = level_code[ii][2:0]; // end of prefix bits
                vlc32_prefix_suffix_coeff[ii][71:43] = 29'b1; // end of prefix bits
            end else if( suffix_length[ii+1] == 3'd2 ) begin // prefix 0 to 13 unary with suffix len = 2
                vlc32_prefix_suffix_coeff[ii][ 7: 0] = { 4'b0, level_code[ii][5:2] } + 8'd3; // length
                vlc32_prefix_suffix_coeff[ii][39: 8] = { 14'b0, ( mask_tbl[level_code[ii][5:2]][15:0] ), 2'b11 }; // mask
                vlc32_prefix_suffix_coeff[ii][41:40] = level_code[ii][1:0]; // end of prefix bits
                vlc32_prefix_suffix_coeff[ii][71:42] = 30'b1; // end of prefix bits
            end else if( suffix_length[ii+1] == 3'd1 ) begin // prefix 0 to 13 unary with suffix len = 1
                vlc32_prefix_suffix_coeff[ii][ 7: 0] = { 4'b0, level_code[ii][4:1] } + 8'd2; // length
                vlc32_prefix_suffix_coeff[ii][39: 8] = { 15'b0, ( mask_tbl[level_code[ii][4:1]][15:0] ), 1'b1 }; // mask
                vlc32_prefix_suffix_coeff[ii][   40] = level_code[0]; // end of prefix bits
                vlc32_prefix_suffix_coeff[ii][71:41] = 31'b1; // end of prefix bits
            end else begin // prefix 0 to 13 unary with suffix len = 0
                vlc32_prefix_suffix_coeff[ii][ 7: 0] = { 4'b0, level_code[ii][3:0] } + 8'd1; // length
                vlc32_prefix_suffix_coeff[ii][39: 8] = { 16'b0, ( mask_tbl[level_code[ii][3:0]][15:0] ) }; // mask
                vlc32_prefix_suffix_coeff[ii][71:40] = 32'b1; // end of prefix bits
            end
        end
    end                               

    // Bit Funnel Tree, VLC Concatenation
    
    logic [71:0] vlc32_cat[15];
    logic [135:0] vlc64_cat[9];
    logic [263:0] vlc128_cat[5];
    logic [519:0] vlc256_cat[4];
    logic [1039:0] vlc512_cat;
    
    vlc_cat #( 13, 11, 10, 32, 8, 32, 8 ) cat_00_ ( .abcat(  vlc32_cat[ 0] ), .a(  vlc32_run_before[ 0]          ), .b( vlc32_run_before[ 1]          ) );
    vlc_cat #( 11,  9,  8, 32, 8, 32, 8 ) cat_01_ ( .abcat(  vlc32_cat[ 1] ), .a(  vlc32_run_before[ 2]          ), .b( vlc32_run_before[ 3]          ) );
    vlc_cat #(  9,  7,  6, 32, 8, 32, 8 ) cat_02_ ( .abcat(  vlc32_cat[ 2] ), .a(  vlc32_run_before[ 4]          ), .b( vlc32_run_before[ 5]          ) );
    vlc_cat #(  7,  5,  4, 32, 8, 32, 8 ) cat_03_ ( .abcat(  vlc32_cat[ 3] ), .a(  vlc32_run_before[ 6]          ), .b( vlc32_run_before[ 7]          ) );
    vlc_cat #(  5,  3,  3, 32, 8, 32, 8 ) cat_04_ ( .abcat(  vlc32_cat[ 4] ), .a(  vlc32_run_before[ 8]          ), .b( vlc32_run_before[ 9]          ) );
    vlc_cat #(  4,  3,  2, 32, 8, 32, 8 ) cat_05_ ( .abcat(  vlc32_cat[ 5] ), .a(  vlc32_run_before[10]          ), .b( vlc32_run_before[11]          ) );
    vlc_cat #(  2,  2,  1, 32, 8, 32, 8 ) cat_06_ ( .abcat(  vlc32_cat[ 6] ), .a(  vlc32_run_before[12]          ), .b( vlc32_run_before[13]          ) );
    vlc_cat #( 19,  9, 13, 32, 8, 32, 8 ) cat_07_ ( .abcat(  vlc32_cat[ 7] ), .a(  vlc32_total_zeros             ), .b( vlc32_cat[ 0]                 ) );
    vlc_cat #( 15, 11,  9, 32, 8, 32, 8 ) cat_08_ ( .abcat(  vlc32_cat[ 8] ), .a(  vlc32_cat[ 1]                 ), .b( vlc32_cat[ 2]                 ) ); 
    vlc_cat #(  9,  7,  5, 32, 8, 32, 8 ) cat_09_ ( .abcat(  vlc32_cat[ 9] ), .a(  vlc32_cat[ 3]                 ), .b( vlc32_cat[ 4]                 ) ); 
    vlc_cat #(  4,  4,  2, 32, 8, 32, 8 ) cat_10_ ( .abcat(  vlc32_cat[10] ), .a(  vlc32_cat[ 5]                 ), .b( vlc32_cat[ 6]                 ) );
    vlc_cat #( 27, 19, 15, 32, 8, 32, 8 ) cat_11_ ( .abcat(  vlc32_cat[11] ), .a(  vlc32_cat[ 7]                 ), .b( vlc32_cat[ 8]                 ) );
    vlc_cat #( 12,  9, 10, 32, 8, 32, 8 ) cat_12_ ( .abcat(  vlc32_cat[12] ), .a(  vlc32_cat[ 9]                 ), .b( vlc32_cat[10]                 ) );
    vlc_cat #( 30, 27, 12, 32, 8, 32, 8 ) cat_13_ ( .abcat(  vlc32_cat[13] ), .a(  vlc32_cat[11]                 ), .b( vlc32_cat[12]                 ) );
    vlc_cat #( 19, 16,  3, 32, 8, 32, 8 ) cat_14_ ( .abcat(  vlc32_cat[14] ), .a(  vlc32_coeff_token             ), .b( vlc32_trailing_ones           ) );
    vlc_cat #( 47, 19, 28, 32, 8, 64, 8 ) cat_15_ ( .abcat(  vlc64_cat[ 0] ), .a(  vlc32_cat[14]                 ), .b( vlc32_prefix_suffix_coeff[15] ) );
    vlc_cat #( 56, 28, 28, 32, 8, 64, 8 ) cat_16_ ( .abcat(  vlc64_cat[ 1] ), .a(  vlc32_prefix_suffix_coeff[14] ), .b( vlc32_prefix_suffix_coeff[13] ) );
    vlc_cat #( 56, 28, 28, 32, 8, 64, 8 ) cat_17_ ( .abcat(  vlc64_cat[ 2] ), .a(  vlc32_prefix_suffix_coeff[12] ), .b( vlc32_prefix_suffix_coeff[13] ) );
    vlc_cat #( 56, 28, 28, 32, 8, 64, 8 ) cat_18_ ( .abcat(  vlc64_cat[ 3] ), .a(  vlc32_prefix_suffix_coeff[10] ), .b( vlc32_prefix_suffix_coeff[13] ) );
    vlc_cat #( 56, 28, 28, 32, 8, 64, 8 ) cat_19_ ( .abcat(  vlc64_cat[ 4] ), .a(  vlc32_prefix_suffix_coeff[ 8] ), .b( vlc32_prefix_suffix_coeff[13] ) );
    vlc_cat #( 56, 28, 28, 32, 8, 64, 8 ) cat_20_ ( .abcat(  vlc64_cat[ 5] ), .a(  vlc32_prefix_suffix_coeff[ 6] ), .b( vlc32_prefix_suffix_coeff[13] ) );
    vlc_cat #( 56, 28, 28, 32, 8, 64, 8 ) cat_21_ ( .abcat(  vlc64_cat[ 6] ), .a(  vlc32_prefix_suffix_coeff[ 4] ), .b( vlc32_prefix_suffix_coeff[13] ) );
    vlc_cat #( 56, 28, 28, 32, 8, 64, 8 ) cat_22_ ( .abcat(  vlc64_cat[ 7] ), .a(  vlc32_prefix_suffix_coeff[ 2] ), .b( vlc32_prefix_suffix_coeff[13] ) );
    vlc_cat #( 58, 28, 30, 32, 8, 64, 8 ) cat_23_ ( .abcat(  vlc64_cat[ 8] ), .a(  vlc32_prefix_suffix_coeff[ 0] ), .b( vlc32_cat[13]                 ) );
    vlc_cat #(103, 47, 56, 64, 8,128, 8 ) cat_24_ ( .abcat( vlc128_cat[ 0] ), .a(  vlc64_cat[ 0]                 ), .b( vlc64_cat[ 1]                 ) );
    vlc_cat #(112, 56, 56, 64, 8,128, 8 ) cat_25_ ( .abcat( vlc128_cat[ 1] ), .a(  vlc64_cat[ 2]                 ), .b( vlc64_cat[ 3]                 ) );
    vlc_cat #(112, 56, 56, 64, 8,128, 8 ) cat_26_ ( .abcat( vlc128_cat[ 2] ), .a(  vlc64_cat[ 4]                 ), .b( vlc64_cat[ 5]                 ) );
    vlc_cat #(112, 56, 56, 64, 8,128, 8 ) cat_27_ ( .abcat( vlc128_cat[ 3] ), .a(  vlc64_cat[ 6]                 ), .b( vlc64_cat[ 7]                 ) );
    vlc_cat #( 58, 58,  0, 64, 8,128, 8 ) cat_28_ ( .abcat( vlc128_cat[ 4] ), .a(  vlc64_cat[ 8]                 ), .b(        136'b0                 ) );
    vlc_cat #(215,103,112,128, 8,256, 8 ) cat_29_ ( .abcat( vlc256_cat[ 0] ), .a( vlc128_cat[ 0]                 ), .b( vlc128_cat[ 1]                ) );
    vlc_cat #(224,112,112,128, 8,256, 8 ) cat_30_ ( .abcat( vlc256_cat[ 1] ), .a( vlc128_cat[ 2]                 ), .b( vlc128_cat[ 3]                ) );
    vlc_cat #( 58, 58,  0,128, 8,256, 8 ) cat_31_ ( .abcat( vlc256_cat[ 2] ), .a( vlc128_cat[ 4]                 ), .b(         264'b0                ) );
    vlc_cat #(282,224, 58,256, 8,256, 8 ) cat_32_ ( .abcat( vlc256_cat[ 3] ), .a( vlc256_cat[ 1]                 ), .b( vlc256_cat[ 2]                ) );
    vlc_cat #(497,215,282,256, 8,512,16 ) cat_33_ ( .abcat( vlc512_cat     ), .a( vlc256_cat[ 0]                 ), .b( vlc256_cat[ 3]                ) );
   
    // Assign rate outputs
    
    assign bitcount[9:0] = vlc512_cat[9:0]; 
    assign bits[511:0]   = vlc512_cat[527:16];
    assign mask[510:0]   = vlc512_cat[1039:528];
    
    //////////
    // DONE
    //////////
endmodule

// Concatenate 2 VLC's
// A 512 bit concatenate is reasonable assuming logic reduciton by synth tool (validate!)
module vlc_cat
#(
    // Required
    QMAX = 30,
    AMAX  = 27,
    BMAX  = 12,
    // Default 
    ABITS = 32,
    ACNT = 8,
    QBITS = 32,
    QCNT = 8, 
    // Calculated
    BBITS = ABITS,
    BCNT = ACNT,
    APORT = ABITS*2+ACNT,
    BPORT = BBITS*2+BCNT,
    QPORT = QBITS*2+QCNT
)
(
    output logic [QPORT-1:0] abcat,
    input  logic [APORT-1:0] a,
    input  logic [BPORT-1:0] b
);
    localparam int SH_ADDR_WIDTH = $clog2( BMAX );
    
    logic [511:0] dout, mout, ad, am;
    logic [8:0] shift;
    
    // Only drive the shift, data, mask bits required, otherwise 0 for synth const propagation and removal
    always_comb begin
        shift[8:0] = 9'b0;
        ad[511:0] = 512'd0; 
        am[511:0] = 512'd0;
        shift[SH_ADDR_WIDTH-1:0] = b[SH_ADDR_WIDTH-1:0];
        am[AMAX-1:0] = a[AMAX+ACNT-1:ACNT];
        ad[AMAX-1:0] = a[AMAX+ACNT+ABITS-1:ACNT+ABITS];
    end
    
    logic [511:0] barrel[10];
    
    always_comb begin
        for( int ii = 0; ii < 512; ii++ ) begin
            barrel[0][ii*2 +: 2]  = { ad[ii], am[ii] };
            barrel[1][ii*2 +: 2]  = ( shift[8] ) ? (( ii >= 256 ) ? barrel[0][(ii-256)*2 +: 2] : 2'b00 ) : barrel[0][ii*2 +: 2];
            barrel[2][ii*2 +: 2]  = ( shift[7] ) ? (( ii >= 128 ) ? barrel[1][(ii-128)*2 +: 2] : 2'b00 ) : barrel[1][ii*2 +: 2];
            barrel[3][ii*2 +: 2]  = ( shift[6] ) ? (( ii >=  64 ) ? barrel[2][(ii- 64)*2 +: 2] : 2'b00 ) : barrel[2][ii*2 +: 2];
            barrel[4][ii*2 +: 2]  = ( shift[5] ) ? (( ii >=  32 ) ? barrel[3][(ii- 32)*2 +: 2] : 2'b00 ) : barrel[3][ii*2 +: 2];
            barrel[5][ii*2 +: 2]  = ( shift[4] ) ? (( ii >=  16 ) ? barrel[4][(ii- 16)*2 +: 2] : 2'b00 ) : barrel[4][ii*2 +: 2];
            barrel[6][ii*2 +: 2]  = ( shift[3] ) ? (( ii >=   8 ) ? barrel[5][(ii-  8)*2 +: 2] : 2'b00 ) : barrel[5][ii*2 +: 2];
            barrel[7][ii*2 +: 2]  = ( shift[2] ) ? (( ii >=   4 ) ? barrel[6][(ii-  4)*2 +: 2] : 2'b00 ) : barrel[6][ii*2 +: 2];
            barrel[8][ii*2 +: 2]  = ( shift[1] ) ? (( ii >=   2 ) ? barrel[7][(ii-  2)*2 +: 2] : 2'b00 ) : barrel[7][ii*2 +: 2];
            barrel[9][ii*2 +: 2]  = ( shift[0] ) ? (( ii >=   1 ) ? barrel[8][(ii-  1)*2 +: 2] : 2'b00 ) : barrel[8][ii*2 +: 2];
            { dout[ii], mout[ii] } = barrel[9][ii*2 +: 2];
        end
    end    
    
    always_comb begin
        abcat[QCNT-1:0] = {{(QCNT-ACNT){1'b0}}, ACNT[ACNT-1:0] } + {{(QCNT-BCNT){1'b0}}, BCNT[ACNT-1:0]};
        for( int ii = 0; ii < QBITS; ii++ ) begin
            if( ii >= QMAX ) begin
                abcat[ii+QCNT] = 1'b0; // mask
                abcat[ii+QCNT+QBITS] = 1'b0; // data
            end else if ( ii >= AMAX ) begin // no A data 
                abcat[ii+QCNT] = mout[ii];
                abcat[ii+QCNT+QBITS] = dout[ii];
            end else begin // A data direct, or muxed B data.
                abcat[ii+QCNT]       = ( b[ii+QCNT] ) ? b[ii+QCNT]       : mout[ii]; // mask
                abcat[ii+QCNT+QBITS] = ( b[ii+QCNT] ) ? b[ii+QCNT+QBITS] : dout[ii]; // data
            end
        end 
    end
    
endmodule



module table_9_10_run_before
(
    input logic [3:0] run_before,
    input logic [3:0] zeros_left,
    output logic [71:0] vlc32
);   
    always_comb begin
        unique case( { zeros_left[2:0], run_before[3:0] } ) // synopsys parallel_case  
            { 3'd0, 4'b???? } : vlc32 = { 32'h0, 32'h0, 8'd0 }; /*str=<empty>*/
            { 3'd1, 4'd0 } : vlc32 = { 32'h1, 32'h1, 8'd1 }; /*str=1*/
            { 3'd1, 4'd1 } : vlc32 = { 32'h0, 32'h1, 8'd1 }; /*str=0*/
            { 3'd2, 4'd0 } : vlc32 = { 32'h1, 32'h1, 8'd1 }; /*str=1*/
            { 3'd2, 4'd1 } : vlc32 = { 32'h1, 32'h3, 8'd2 }; /*str=01*/
            { 3'd2, 4'd2 } : vlc32 = { 32'h0, 32'h3, 8'd2 }; /*str=00*/
            { 3'd3, 4'd0 } : vlc32 = { 32'h3, 32'h3, 8'd2 }; /*str=11*/
            { 3'd3, 4'd1 } : vlc32 = { 32'h2, 32'h3, 8'd2 }; /*str=10*/
            { 3'd3, 4'd2 } : vlc32 = { 32'h1, 32'h3, 8'd2 }; /*str=01*/
            { 3'd3, 4'd3 } : vlc32 = { 32'h0, 32'h3, 8'd2 }; /*str=00*/
            { 3'd4, 4'd0 } : vlc32 = { 32'h3, 32'h3, 8'd2 }; /*str=11*/
            { 3'd4, 4'd1 } : vlc32 = { 32'h2, 32'h3, 8'd2 }; /*str=10*/
            { 3'd4, 4'd2 } : vlc32 = { 32'h1, 32'h3, 8'd2 }; /*str=01*/
            { 3'd4, 4'd3 } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 3'd4, 4'd4 } : vlc32 = { 32'h0, 32'h7, 8'd3 }; /*str=000*/
            { 3'd5, 4'd0 } : vlc32 = { 32'h3, 32'h3, 8'd2 }; /*str=11*/
            { 3'd5, 4'd1 } : vlc32 = { 32'h2, 32'h3, 8'd2 }; /*str=10*/
            { 3'd5, 4'd2 } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 3'd5, 4'd3 } : vlc32 = { 32'h2, 32'h7, 8'd3 }; /*str=010*/
            { 3'd5, 4'd4 } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 3'd5, 4'd5 } : vlc32 = { 32'h0, 32'h7, 8'd3 }; /*str=000*/
            { 3'd6, 4'd0 } : vlc32 = { 32'h3, 32'h3, 8'd2 }; /*str=11*/
            { 3'd6, 4'd1 } : vlc32 = { 32'h0, 32'h7, 8'd3 }; /*str=000*/
            { 3'd6, 4'd2 } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 3'd6, 4'd3 } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 3'd6, 4'd4 } : vlc32 = { 32'h2, 32'h7, 8'd3 }; /*str=010*/
            { 3'd6, 4'd5 } : vlc32 = { 32'h5, 32'h7, 8'd3 }; /*str=101*/
            { 3'd6, 4'd6 } : vlc32 = { 32'h4, 32'h7, 8'd3 }; /*str=100*/
            { 3'd7, 4'd0 } : vlc32 = { 32'h7, 32'h7, 8'd3 }; /*str=111*/
            { 3'd7, 4'd1 } : vlc32 = { 32'h6, 32'h7, 8'd3 }; /*str=110*/
            { 3'd7, 4'd2 } : vlc32 = { 32'h5, 32'h7, 8'd3 }; /*str=101*/
            { 3'd7, 4'd3 } : vlc32 = { 32'h4, 32'h7, 8'd3 }; /*str=100*/
            { 3'd7, 4'd4 } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 3'd7, 4'd5 } : vlc32 = { 32'h2, 32'h7, 8'd3 }; /*str=010*/
            { 3'd7, 4'd6 } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 3'd7, 4'd7 } : vlc32 = { 32'h1, 32'hF, 8'd4 }; /*str=0001*/
            { 3'd7, 4'd8 } : vlc32 = { 32'h1, 32'h1F, 8'd5 }; /*str=00001*/
            { 3'd7, 4'd9 } : vlc32 = { 32'h1, 32'h3F, 8'd6 }; /*str=000001*/
            { 3'd7, 4'd10 } : vlc32 = { 32'h1, 32'h7F, 8'd7 }; /*str=0000001*/
            { 3'd7, 4'd11 } : vlc32 = { 32'h1, 32'hFF, 8'd8 }; /*str=00000001*/
            { 3'd7, 4'd12 } : vlc32 = { 32'h1, 32'h1FF, 8'd9 }; /*str=000000001*/
            { 3'd7, 4'd13 } : vlc32 = { 32'h1, 32'h3FF, 8'd10 }; /*str=0000000001*/
            { 3'd7, 4'd14 } : vlc32 = { 32'h1, 32'h7FF, 8'd11 }; /*str=00000000001*/
            default        : vlc32 = {72{1'bx}}; // don't care
        endcase
    end 
endmodule

module table_9_9_total_zeros_2x2
(
    input logic [1:0] num_coeff,
    input logic [1:0] total_zeros,
    output logic [71:0] vlc32
);   
    always_comb begin
        unique case( { num_coeff[1:0], total_zeros[1:0] } ) // synopsys parallel_case  
            { 2'd1, 2'd0 } : vlc32 = { 32'h1, 32'd1, 8'd1 }; /* str=1 */
            { 2'd1, 2'd1 } : vlc32 = { 32'h1, 32'd3, 8'd2 }; /* str=01 */
            { 2'd1, 2'd2 } : vlc32 = { 32'h1, 32'd7, 8'd3 }; /* str=001 */
            { 2'd1, 2'd3 } : vlc32 = { 32'h0, 32'd7, 8'd3 }; /* str=000 */
            { 2'd2, 2'd0 } : vlc32 = { 32'h1, 32'd1, 8'd1 }; /* str=1 */
            { 2'd2, 2'd0 } : vlc32 = { 32'h1, 32'd3, 8'd2 }; /* str=01 */
            { 2'd2, 2'd0 } : vlc32 = { 32'h0, 32'd3, 8'd2 }; /* str=00 */
            { 2'd3, 2'd0 } : vlc32 = { 32'h1, 32'd1, 8'd1 }; /* str=1 */
            { 2'd3, 2'd0 } : vlc32 = { 32'h0, 32'd1, 8'd1 }; /* str=0 */
            default        : vlc32 = {72{1'bx}}; // don't care
        endcase
    end 
endmodule


module table_9_8_total_zeros_4x4
(
    input logic [3:0] num_coeff,
    input logic [3:0] total_zeros,
    output logic [71:0] vlc32
);   
    always_comb begin        
        unique case( { num_coeff[3:0], total_zeros[3:0] } ) // synopsys parallel_case
            { 4'd1 , 4'd0  } : vlc32 = { 32'h1, 32'h1, 8'd1 }; /*str=1*/
            { 4'd1 , 4'd1  } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 4'd1 , 4'd2  } : vlc32 = { 32'h2, 32'h7, 8'd3 }; /*str=010*/
            { 4'd1 , 4'd3  } : vlc32 = { 32'h3, 32'hF, 8'd4 }; /*str=0011*/
            { 4'd1 , 4'd4  } : vlc32 = { 32'h2, 32'hF, 8'd4 }; /*str=0010*/
            { 4'd1 , 4'd5  } : vlc32 = { 32'h3, 32'h1F, 8'd5 }; /*str=00011*/
            { 4'd1 , 4'd6  } : vlc32 = { 32'h2, 32'h1F, 8'd5 }; /*str=00010*/
            { 4'd1 , 4'd7  } : vlc32 = { 32'h3, 32'h3F, 8'd6 }; /*str=000011*/
            { 4'd1 , 4'd8  } : vlc32 = { 32'h2, 32'h3F, 8'd6 }; /*str=000010*/
            { 4'd1 , 4'd9  } : vlc32 = { 32'h3, 32'h7F, 8'd7 }; /*str=0000011*/
            { 4'd1 , 4'd10 } : vlc32 = { 32'h2, 32'h7F, 8'd7 }; /*str=0000010*/
            { 4'd1 , 4'd11 } : vlc32 = { 32'h3, 32'hFF, 8'd8 }; /*str=00000011*/
            { 4'd1 , 4'd12 } : vlc32 = { 32'h2, 32'hFF, 8'd8 }; /*str=00000010*/
            { 4'd1 , 4'd13 } : vlc32 = { 32'h3, 32'h1FF, 8'd9 }; /*str=000000011*/
            { 4'd1 , 4'd14 } : vlc32 = { 32'h2, 32'h1FF, 8'd9 }; /*str=000000010*/
            { 4'd1 , 4'd15 } : vlc32 = { 32'h1, 32'h1FF, 8'd9 }; /*str=000000001*/
            { 4'd2 , 4'd0  } : vlc32 = { 32'h7, 32'h7, 8'd3 }; /*str=111*/
            { 4'd2 , 4'd1  } : vlc32 = { 32'h6, 32'h7, 8'd3 }; /*str=110*/
            { 4'd2 , 4'd2  } : vlc32 = { 32'h5, 32'h7, 8'd3 }; /*str=101*/
            { 4'd2 , 4'd3  } : vlc32 = { 32'h4, 32'h7, 8'd3 }; /*str=100*/
            { 4'd2 , 4'd4  } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 4'd2 , 4'd5  } : vlc32 = { 32'h5, 32'hF, 8'd4 }; /*str=0101*/
            { 4'd2 , 4'd6  } : vlc32 = { 32'h4, 32'hF, 8'd4 }; /*str=0100*/
            { 4'd2 , 4'd7  } : vlc32 = { 32'h3, 32'hF, 8'd4 }; /*str=0011*/
            { 4'd2 , 4'd8  } : vlc32 = { 32'h2, 32'hF, 8'd4 }; /*str=0010*/
            { 4'd2 , 4'd9  } : vlc32 = { 32'h3, 32'h1F, 8'd5 }; /*str=00011*/
            { 4'd2 , 4'd10 } : vlc32 = { 32'h2, 32'h1F, 8'd5 }; /*str=00010*/
            { 4'd2 , 4'd11 } : vlc32 = { 32'h3, 32'h3F, 8'd6 }; /*str=000011*/
            { 4'd2 , 4'd12 } : vlc32 = { 32'h2, 32'h3F, 8'd6 }; /*str=000010*/
            { 4'd2 , 4'd13 } : vlc32 = { 32'h1, 32'h3F, 8'd6 }; /*str=000001*/
            { 4'd2 , 4'd14 } : vlc32 = { 32'h0, 32'h3F, 8'd6 }; /*str=000000*/
            { 4'd3 , 4'd0  } : vlc32 = { 32'h5, 32'hF, 8'd4 }; /*str=0101*/
            { 4'd3 , 4'd1  } : vlc32 = { 32'h7, 32'h7, 8'd3 }; /*str=111*/
            { 4'd3 , 4'd2  } : vlc32 = { 32'h6, 32'h7, 8'd3 }; /*str=110*/
            { 4'd3 , 4'd3  } : vlc32 = { 32'h5, 32'h7, 8'd3 }; /*str=101*/
            { 4'd3 , 4'd4  } : vlc32 = { 32'h4, 32'hF, 8'd4 }; /*str=0100*/
            { 4'd3 , 4'd5  } : vlc32 = { 32'h3, 32'hF, 8'd4 }; /*str=0011*/
            { 4'd3 , 4'd6  } : vlc32 = { 32'h4, 32'h7, 8'd3 }; /*str=100*/
            { 4'd3 , 4'd7  } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 4'd3 , 4'd8  } : vlc32 = { 32'h2, 32'hF, 8'd4 }; /*str=0010*/
            { 4'd3 , 4'd9  } : vlc32 = { 32'h3, 32'h1F, 8'd5 }; /*str=00011*/
            { 4'd3 , 4'd10 } : vlc32 = { 32'h2, 32'h1F, 8'd5 }; /*str=00010*/
            { 4'd3 , 4'd11 } : vlc32 = { 32'h1, 32'h3F, 8'd6 }; /*str=000001*/
            { 4'd3 , 4'd12 } : vlc32 = { 32'h1, 32'h1F, 8'd5 }; /*str=00001*/
            { 4'd3 , 4'd13 } : vlc32 = { 32'h0, 32'h3F, 8'd6 }; /*str=000000*/
            { 4'd4 , 4'd0  } : vlc32 = { 32'h3, 32'h1F, 8'd5 }; /*str=00011*/
            { 4'd4 , 4'd1  } : vlc32 = { 32'h7, 32'h7, 8'd3 }; /*str=111*/
            { 4'd4 , 4'd2  } : vlc32 = { 32'h5, 32'hF, 8'd4 }; /*str=0101*/
            { 4'd4 , 4'd3  } : vlc32 = { 32'h4, 32'hF, 8'd4 }; /*str=0100*/
            { 4'd4 , 4'd4  } : vlc32 = { 32'h6, 32'h7, 8'd3 }; /*str=110*/
            { 4'd4 , 4'd5  } : vlc32 = { 32'h5, 32'h7, 8'd3 }; /*str=101*/
            { 4'd4 , 4'd6  } : vlc32 = { 32'h4, 32'h7, 8'd3 }; /*str=100*/
            { 4'd4 , 4'd7  } : vlc32 = { 32'h3, 32'hF, 8'd4 }; /*str=0011*/
            { 4'd4 , 4'd8  } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 4'd4 , 4'd9  } : vlc32 = { 32'h2, 32'hF, 8'd4 }; /*str=0010*/
            { 4'd4 , 4'd10 } : vlc32 = { 32'h2, 32'h1F, 8'd5 }; /*str=00010*/
            { 4'd4 , 4'd11 } : vlc32 = { 32'h1, 32'h1F, 8'd5 }; /*str=00001*/
            { 4'd4 , 4'd12 } : vlc32 = { 32'h0, 32'h1F, 8'd5 }; /*str=00000*/
            { 4'd5 , 4'd0  } : vlc32 = { 32'h5, 32'hF, 8'd4 }; /*str=0101*/
            { 4'd5 , 4'd1  } : vlc32 = { 32'h4, 32'hF, 8'd4 }; /*str=0100*/
            { 4'd5 , 4'd2  } : vlc32 = { 32'h3, 32'hF, 8'd4 }; /*str=0011*/
            { 4'd5 , 4'd3  } : vlc32 = { 32'h7, 32'h7, 8'd3 }; /*str=111*/
            { 4'd5 , 4'd4  } : vlc32 = { 32'h6, 32'h7, 8'd3 }; /*str=110*/
            { 4'd5 , 4'd5  } : vlc32 = { 32'h5, 32'h7, 8'd3 }; /*str=101*/
            { 4'd5 , 4'd6  } : vlc32 = { 32'h4, 32'h7, 8'd3 }; /*str=100*/
            { 4'd5 , 4'd7  } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 4'd5 , 4'd8  } : vlc32 = { 32'h2, 32'hF, 8'd4 }; /*str=0010*/
            { 4'd5 , 4'd9  } : vlc32 = { 32'h1, 32'h1F, 8'd5 }; /*str=00001*/
            { 4'd5 , 4'd10 } : vlc32 = { 32'h1, 32'hF, 8'd4 }; /*str=0001*/
            { 4'd5 , 4'd11 } : vlc32 = { 32'h0, 32'h1F, 8'd5 }; /*str=00000*/
            { 4'd6 , 4'd0  } : vlc32 = { 32'h1, 32'h3F, 8'd6 }; /*str=000001*/
            { 4'd6 , 4'd1  } : vlc32 = { 32'h1, 32'h1F, 8'd5 }; /*str=00001*/
            { 4'd6 , 4'd2  } : vlc32 = { 32'h7, 32'h7, 8'd3 }; /*str=111*/
            { 4'd6 , 4'd3  } : vlc32 = { 32'h6, 32'h7, 8'd3 }; /*str=110*/
            { 4'd6 , 4'd4  } : vlc32 = { 32'h5, 32'h7, 8'd3 }; /*str=101*/
            { 4'd6 , 4'd5  } : vlc32 = { 32'h4, 32'h7, 8'd3 }; /*str=100*/
            { 4'd6 , 4'd6  } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 4'd6 , 4'd7  } : vlc32 = { 32'h2, 32'h7, 8'd3 }; /*str=010*/
            { 4'd6 , 4'd8  } : vlc32 = { 32'h1, 32'hF, 8'd4 }; /*str=0001*/
            { 4'd6 , 4'd9  } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 4'd6 , 4'd10 } : vlc32 = { 32'h0, 32'h3F, 8'd6 }; /*str=000000*/
            { 4'd7 , 4'd0  } : vlc32 = { 32'h1, 32'h3F, 8'd6 }; /*str=000001*/
            { 4'd7 , 4'd1  } : vlc32 = { 32'h1, 32'h1F, 8'd5 }; /*str=00001*/
            { 4'd7 , 4'd2  } : vlc32 = { 32'h5, 32'h7, 8'd3 }; /*str=101*/
            { 4'd7 , 4'd3  } : vlc32 = { 32'h4, 32'h7, 8'd3 }; /*str=100*/
            { 4'd7 , 4'd4  } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 4'd7 , 4'd5  } : vlc32 = { 32'h3, 32'h3, 8'd2 }; /*str=11*/
            { 4'd7 , 4'd6  } : vlc32 = { 32'h2, 32'h7, 8'd3 }; /*str=010*/
            { 4'd7 , 4'd7  } : vlc32 = { 32'h1, 32'hF, 8'd4 }; /*str=0001*/
            { 4'd7 , 4'd8  } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 4'd7 , 4'd9  } : vlc32 = { 32'h0, 32'h3F, 8'd6 }; /*str=000000*/
            { 4'd8 , 4'd0  } : vlc32 = { 32'h1, 32'h3F, 8'd6 }; /*str=000001*/
            { 4'd8 , 4'd1  } : vlc32 = { 32'h1, 32'hF, 8'd4 }; /*str=0001*/
            { 4'd8 , 4'd2  } : vlc32 = { 32'h1, 32'h1F, 8'd5 }; /*str=00001*/
            { 4'd8 , 4'd3  } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 4'd8 , 4'd4  } : vlc32 = { 32'h3, 32'h3, 8'd2 }; /*str=11*/
            { 4'd8 , 4'd5  } : vlc32 = { 32'h2, 32'h3, 8'd2 }; /*str=10*/
            { 4'd8 , 4'd6  } : vlc32 = { 32'h2, 32'h7, 8'd3 }; /*str=010*/
            { 4'd8 , 4'd7  } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 4'd8 , 4'd8  } : vlc32 = { 32'h0, 32'h3F, 8'd6 }; /*str=000000*/
            { 4'd9 , 4'd0  } : vlc32 = { 32'h1, 32'h3F, 8'd6 }; /*str=000001*/
            { 4'd9 , 4'd1  } : vlc32 = { 32'h0, 32'h3F, 8'd6 }; /*str=000000*/
            { 4'd9 , 4'd2  } : vlc32 = { 32'h1, 32'hF, 8'd4 }; /*str=0001*/
            { 4'd9 , 4'd3  } : vlc32 = { 32'h3, 32'h3, 8'd2 }; /*str=11*/
            { 4'd9 , 4'd4  } : vlc32 = { 32'h2, 32'h3, 8'd2 }; /*str=10*/
            { 4'd9 , 4'd5  } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 4'd9 , 4'd6  } : vlc32 = { 32'h1, 32'h3, 8'd2 }; /*str=01*/
            { 4'd9 , 4'd7  } : vlc32 = { 32'h1, 32'h1F, 8'd5 }; /*str=00001*/
            { 4'd10, 4'd0  } : vlc32 = { 32'h1, 32'h1F, 8'd5 }; /*str=00001*/
            { 4'd10, 4'd1  } : vlc32 = { 32'h0, 32'h1F, 8'd5 }; /*str=00000*/
            { 4'd10, 4'd2  } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 4'd10, 4'd3  } : vlc32 = { 32'h3, 32'h3, 8'd2 }; /*str=11*/
            { 4'd10, 4'd4  } : vlc32 = { 32'h2, 32'h3, 8'd2 }; /*str=10*/
            { 4'd10, 4'd5  } : vlc32 = { 32'h1, 32'h3, 8'd2 }; /*str=01*/
            { 4'd10, 4'd6  } : vlc32 = { 32'h1, 32'hF, 8'd4 }; /*str=0001*/
            { 4'd11, 4'd0  } : vlc32 = { 32'h0, 32'hF, 8'd4 }; /*str=0000*/
            { 4'd11, 4'd1  } : vlc32 = { 32'h1, 32'hF, 8'd4 }; /*str=0001*/
            { 4'd11, 4'd2  } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 4'd11, 4'd3  } : vlc32 = { 32'h2, 32'h7, 8'd3 }; /*str=010*/
            { 4'd11, 4'd4  } : vlc32 = { 32'h1, 32'h1, 8'd1 }; /*str=1*/
            { 4'd11, 4'd5  } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 4'd12, 4'd0  } : vlc32 = { 32'h0, 32'hF, 8'd4 }; /*str=0000*/
            { 4'd12, 4'd1  } : vlc32 = { 32'h1, 32'hF, 8'd4 }; /*str=0001*/
            { 4'd12, 4'd2  } : vlc32 = { 32'h1, 32'h3, 8'd2 }; /*str=01*/
            { 4'd12, 4'd3  } : vlc32 = { 32'h1, 32'h1, 8'd1 }; /*str=1*/
            { 4'd12, 4'd4  } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 4'd13, 4'd0  } : vlc32 = { 32'h0, 32'h7, 8'd3 }; /*str=000*/
            { 4'd13, 4'd1  } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 4'd13, 4'd2  } : vlc32 = { 32'h1, 32'h1, 8'd1 }; /*str=1*/
            { 4'd13, 4'd3  } : vlc32 = { 32'h1, 32'h3, 8'd2 }; /*str=01*/
            { 4'd14, 4'd0  } : vlc32 = { 32'h0, 32'h3, 8'd2 }; /*str=00*/
            { 4'd14, 4'd1  } : vlc32 = { 32'h1, 32'h3, 8'd2 }; /*str=01*/
            { 4'd14, 4'd2  } : vlc32 = { 32'h1, 32'h1, 8'd1 }; /*str=1*/
            { 4'd15, 4'd0  } : vlc32 = { 32'h0, 32'h1, 8'd1 }; /*str=0*/
            { 4'd15, 4'd1  } : vlc32 = { 32'h1, 32'h1, 8'd1 }; /*str=1*/
            default          : vlc32 = {72{1'bx}}; // don't care
        endcase
    end
endmodule

module table_9_5_coeff_token
(
    input logic [5:0] num_coeff,
    input logic [1:0] trailing_ones,
    input logic [2:0] table_idx,
    output logic [71:0] vlc32 // 0:nC<2, 1:nC<4, 2:nC<8, 3:nC>=8, 4:chdc
);   
    always_comb begin
        unique case( { trailing_ones[1:0], num_coeff[4:0], table_idx[2:0] } )  // synopsys parallel_case
            { 2'd0, 5'd0 , 3'd0 } : vlc32 = { 32'h1, 32'h1, 8'd1 }; /*str=1*/
            { 2'd0, 5'd0 , 3'd1 } : vlc32 = { 32'h3, 32'h3, 8'd2 }; /*str=11*/
            { 2'd0, 5'd0 , 3'd2 } : vlc32 = { 32'hF, 32'hF, 8'd4 }; /*str=1111*/
            { 2'd0, 5'd0 , 3'd3 } : vlc32 = { 32'h3, 32'h3F, 8'd6 }; /*str=000011*/
            { 2'd0, 5'd0 , 3'd4 } : vlc32 = { 32'h1, 32'h3, 8'd2 }; /*str=01*/
            { 2'd0, 5'd0 , 3'd5 } : vlc32 = { 32'h1, 32'h1, 8'd1 }; /*str=1*/
            { 2'd0, 5'd1 , 3'd0 } : vlc32 = { 32'h5, 32'h3F, 8'd6 }; /*str=000101*/
            { 2'd1, 5'd1 , 3'd0 } : vlc32 = { 32'h1, 32'h3, 8'd2 }; /*str=01*/
            { 2'd0, 5'd2 , 3'd0 } : vlc32 = { 32'h7, 32'hFF, 8'd8 }; /*str=00000111*/
            { 2'd1, 5'd2 , 3'd0 } : vlc32 = { 32'h4, 32'h3F, 8'd6 }; /*str=000100*/
            { 2'd2, 5'd2 , 3'd0 } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 2'd0, 5'd3 , 3'd0 } : vlc32 = { 32'h7, 32'h1FF, 8'd9 }; /*str=000000111*/
            { 2'd1, 5'd3 , 3'd0 } : vlc32 = { 32'h6, 32'hFF, 8'd8 }; /*str=00000110*/
            { 2'd2, 5'd3 , 3'd0 } : vlc32 = { 32'h5, 32'h7F, 8'd7 }; /*str=0000101*/
            { 2'd3, 5'd3 , 3'd0 } : vlc32 = { 32'h3, 32'h1F, 8'd5 }; /*str=00011*/
            { 2'd0, 5'd4 , 3'd0 } : vlc32 = { 32'h7, 32'h3FF, 8'd10 }; /*str=0000000111*/
            { 2'd1, 5'd4 , 3'd0 } : vlc32 = { 32'h6, 32'h1FF, 8'd9 }; /*str=000000110*/
            { 2'd2, 5'd4 , 3'd0 } : vlc32 = { 32'h5, 32'hFF, 8'd8 }; /*str=00000101*/
            { 2'd3, 5'd4 , 3'd0 } : vlc32 = { 32'h3, 32'h3F, 8'd6 }; /*str=000011*/
            { 2'd0, 5'd5 , 3'd0 } : vlc32 = { 32'h7, 32'h7FF, 8'd11 }; /*str=00000000111*/
            { 2'd1, 5'd5 , 3'd0 } : vlc32 = { 32'h6, 32'h3FF, 8'd10 }; /*str=0000000110*/
            { 2'd2, 5'd5 , 3'd0 } : vlc32 = { 32'h5, 32'h1FF, 8'd9 }; /*str=000000101*/
            { 2'd3, 5'd5 , 3'd0 } : vlc32 = { 32'h4, 32'h7F, 8'd7 }; /*str=0000100*/
            { 2'd0, 5'd6 , 3'd0 } : vlc32 = { 32'hF, 32'h1FFF, 8'd13 }; /*str=0000000001111*/
            { 2'd1, 5'd6 , 3'd0 } : vlc32 = { 32'h6, 32'h7FF, 8'd11 }; /*str=00000000110*/
            { 2'd2, 5'd6 , 3'd0 } : vlc32 = { 32'h5, 32'h3FF, 8'd10 }; /*str=0000000101*/
            { 2'd3, 5'd6 , 3'd0 } : vlc32 = { 32'h4, 32'hFF, 8'd8 }; /*str=00000100*/
            { 2'd0, 5'd7 , 3'd0 } : vlc32 = { 32'hB, 32'h1FFF, 8'd13 }; /*str=0000000001011*/
            { 2'd1, 5'd7 , 3'd0 } : vlc32 = { 32'hE, 32'h1FFF, 8'd13 }; /*str=0000000001110*/
            { 2'd2, 5'd7 , 3'd0 } : vlc32 = { 32'h5, 32'h7FF, 8'd11 }; /*str=00000000101*/
            { 2'd3, 5'd7 , 3'd0 } : vlc32 = { 32'h4, 32'h1FF, 8'd9 }; /*str=000000100*/
            { 2'd0, 5'd8 , 3'd0 } : vlc32 = { 32'h8, 32'h1FFF, 8'd13 }; /*str=0000000001000*/
            { 2'd1, 5'd8 , 3'd0 } : vlc32 = { 32'hA, 32'h1FFF, 8'd13 }; /*str=0000000001010*/
            { 2'd2, 5'd8 , 3'd0 } : vlc32 = { 32'hD, 32'h1FFF, 8'd13 }; /*str=0000000001101*/
            { 2'd3, 5'd8 , 3'd0 } : vlc32 = { 32'h4, 32'h3FF, 8'd10 }; /*str=0000000100*/
            { 2'd0, 5'd9 , 3'd0 } : vlc32 = { 32'hF, 32'h3FFF, 8'd14 }; /*str=00000000001111*/
            { 2'd1, 5'd9 , 3'd0 } : vlc32 = { 32'hE, 32'h3FFF, 8'd14 }; /*str=00000000001110*/
            { 2'd2, 5'd9 , 3'd0 } : vlc32 = { 32'h9, 32'h1FFF, 8'd13 }; /*str=0000000001001*/
            { 2'd3, 5'd9 , 3'd0 } : vlc32 = { 32'h4, 32'h7FF, 8'd11 }; /*str=00000000100*/
            { 2'd0, 5'd10, 3'd0 } : vlc32 = { 32'hB, 32'h3FFF, 8'd14 }; /*str=00000000001011*/
            { 2'd1, 5'd10, 3'd0 } : vlc32 = { 32'hA, 32'h3FFF, 8'd14 }; /*str=00000000001010*/
            { 2'd2, 5'd10, 3'd0 } : vlc32 = { 32'hD, 32'h3FFF, 8'd14 }; /*str=00000000001101*/
            { 2'd3, 5'd10, 3'd0 } : vlc32 = { 32'hC, 32'h1FFF, 8'd13 }; /*str=0000000001100*/
            { 2'd0, 5'd14, 3'd0 } : vlc32 = { 32'hF, 32'h7FFF, 8'd15 }; /*str=000000000001111*/
            { 2'd1, 5'd14, 3'd0 } : vlc32 = { 32'hE, 32'h7FFF, 8'd15 }; /*str=000000000001110*/
            { 2'd2, 5'd14, 3'd0 } : vlc32 = { 32'h9, 32'h3FFF, 8'd14 }; /*str=00000000001001*/
            { 2'd3, 5'd14, 3'd0 } : vlc32 = { 32'hC, 32'h3FFF, 8'd14 }; /*str=00000000001100*/
            { 2'd0, 5'd12, 3'd0 } : vlc32 = { 32'hB, 32'h7FFF, 8'd15 }; /*str=000000000001011*/
            { 2'd1, 5'd12, 3'd0 } : vlc32 = { 32'hA, 32'h7FFF, 8'd15 }; /*str=000000000001010*/
            { 2'd2, 5'd12, 3'd0 } : vlc32 = { 32'hD, 32'h7FFF, 8'd15 }; /*str=000000000001101*/
            { 2'd3, 5'd12, 3'd0 } : vlc32 = { 32'h8, 32'h3FFF, 8'd14 }; /*str=00000000001000*/
            { 2'd0, 5'd13, 3'd0 } : vlc32 = { 32'hF, 32'hFFFF, 8'd16 }; /*str=0000000000001111*/
            { 2'd1, 5'd13, 3'd0 } : vlc32 = { 32'h1, 32'h7FFF, 8'd15 }; /*str=000000000000001*/
            { 2'd2, 5'd13, 3'd0 } : vlc32 = { 32'h9, 32'h7FFF, 8'd15 }; /*str=000000000001001*/
            { 2'd3, 5'd13, 3'd0 } : vlc32 = { 32'hC, 32'h7FFF, 8'd15 }; /*str=000000000001100*/
            { 2'd0, 5'd14, 3'd0 } : vlc32 = { 32'hB, 32'hFFFF, 8'd16 }; /*str=0000000000001011*/
            { 2'd1, 5'd14, 3'd0 } : vlc32 = { 32'hE, 32'hFFFF, 8'd16 }; /*str=0000000000001110*/
            { 2'd2, 5'd14, 3'd0 } : vlc32 = { 32'hD, 32'hFFFF, 8'd16 }; /*str=0000000000001101*/
            { 2'd3, 5'd14, 3'd0 } : vlc32 = { 32'h8, 32'h7FFF, 8'd15 }; /*str=000000000001000*/
            { 2'd0, 5'd15, 3'd0 } : vlc32 = { 32'h7, 32'hFFFF, 8'd16 }; /*str=0000000000000111*/
            { 2'd1, 5'd15, 3'd0 } : vlc32 = { 32'hA, 32'hFFFF, 8'd16 }; /*str=0000000000001010*/
            { 2'd2, 5'd15, 3'd0 } : vlc32 = { 32'h9, 32'hFFFF, 8'd16 }; /*str=0000000000001001*/
            { 2'd3, 5'd15, 3'd0 } : vlc32 = { 32'hC, 32'hFFFF, 8'd16 }; /*str=0000000000001100*/
            { 2'd0, 5'd16, 3'd0 } : vlc32 = { 32'h4, 32'hFFFF, 8'd16 }; /*str=0000000000000100*/
            { 2'd1, 5'd16, 3'd0 } : vlc32 = { 32'h6, 32'hFFFF, 8'd16 }; /*str=0000000000000110*/
            { 2'd2, 5'd16, 3'd0 } : vlc32 = { 32'h5, 32'hFFFF, 8'd16 }; /*str=0000000000000101*/
            { 2'd3, 5'd16, 3'd0 } : vlc32 = { 32'h8, 32'hFFFF, 8'd16 }; /*str=0000000000001000*/
            { 2'd0, 5'd1 , 3'd1 } : vlc32 = { 32'hB, 32'h3F, 8'd6 }; /*str=001011*/
            { 2'd1, 5'd1 , 3'd1 } : vlc32 = { 32'h2, 32'h3, 8'd2 }; /*str=10*/
            { 2'd0, 5'd2 , 3'd1 } : vlc32 = { 32'h7, 32'h3F, 8'd6 }; /*str=000111*/
            { 2'd1, 5'd2 , 3'd1 } : vlc32 = { 32'h7, 32'h1F, 8'd5 }; /*str=00111*/
            { 2'd2, 5'd2 , 3'd1 } : vlc32 = { 32'h3, 32'h7, 8'd3 }; /*str=011*/
            { 2'd0, 5'd3 , 3'd1 } : vlc32 = { 32'h7, 32'h7F, 8'd7 }; /*str=0000111*/
            { 2'd1, 5'd3 , 3'd1 } : vlc32 = { 32'hA, 32'h3F, 8'd6 }; /*str=001010*/
            { 2'd2, 5'd3 , 3'd1 } : vlc32 = { 32'h9, 32'h3F, 8'd6 }; /*str=001001*/
            { 2'd3, 5'd3 , 3'd1 } : vlc32 = { 32'h5, 32'hF, 8'd4 }; /*str=0101*/
            { 2'd0, 5'd4 , 3'd1 } : vlc32 = { 32'h7, 32'hFF, 8'd8 }; /*str=00000111*/
            { 2'd1, 5'd4 , 3'd1 } : vlc32 = { 32'h6, 32'h3F, 8'd6 }; /*str=000110*/
            { 2'd2, 5'd4 , 3'd1 } : vlc32 = { 32'h5, 32'h3F, 8'd6 }; /*str=000101*/
            { 2'd3, 5'd4 , 3'd1 } : vlc32 = { 32'h4, 32'hF, 8'd4 }; /*str=0100*/
            { 2'd0, 5'd5 , 3'd1 } : vlc32 = { 32'h4, 32'hFF, 8'd8 }; /*str=00000100*/
            { 2'd1, 5'd5 , 3'd1 } : vlc32 = { 32'h6, 32'h7F, 8'd7 }; /*str=0000110*/
            { 2'd2, 5'd5 , 3'd1 } : vlc32 = { 32'h5, 32'h7F, 8'd7 }; /*str=0000101*/
            { 2'd3, 5'd5 , 3'd1 } : vlc32 = { 32'h6, 32'h1F, 8'd5 }; /*str=00110*/
            { 2'd0, 5'd6 , 3'd1 } : vlc32 = { 32'h7, 32'h1FF, 8'd9 }; /*str=000000111*/
            { 2'd1, 5'd6 , 3'd1 } : vlc32 = { 32'h6, 32'hFF, 8'd8 }; /*str=00000110*/
            { 2'd2, 5'd6 , 3'd1 } : vlc32 = { 32'h5, 32'hFF, 8'd8 }; /*str=00000101*/
            { 2'd3, 5'd6 , 3'd1 } : vlc32 = { 32'h8, 32'h3F, 8'd6 }; /*str=001000*/
            { 2'd0, 5'd7 , 3'd1 } : vlc32 = { 32'hF, 32'h7FF, 8'd11 }; /*str=00000001111*/
            { 2'd1, 5'd7 , 3'd1 } : vlc32 = { 32'h6, 32'h1FF, 8'd9 }; /*str=000000110*/
            { 2'd2, 5'd7 , 3'd1 } : vlc32 = { 32'h5, 32'h1FF, 8'd9 }; /*str=000000101*/
            { 2'd3, 5'd7 , 3'd1 } : vlc32 = { 32'h4, 32'h3F, 8'd6 }; /*str=000100*/
            { 2'd0, 5'd8 , 3'd1 } : vlc32 = { 32'hB, 32'h7FF, 8'd11 }; /*str=00000001011*/
            { 2'd1, 5'd8 , 3'd1 } : vlc32 = { 32'hE, 32'h7FF, 8'd11 }; /*str=00000001110*/
            { 2'd2, 5'd8 , 3'd1 } : vlc32 = { 32'hD, 32'h7FF, 8'd11 }; /*str=00000001101*/
            { 2'd3, 5'd8 , 3'd1 } : vlc32 = { 32'h4, 32'h7F, 8'd7 }; /*str=0000100*/
            { 2'd0, 5'd9 , 3'd1 } : vlc32 = { 32'hF, 32'hFFF, 8'd12 }; /*str=000000001111*/
            { 2'd1, 5'd9 , 3'd1 } : vlc32 = { 32'hA, 32'h7FF, 8'd11 }; /*str=00000001010*/
            { 2'd2, 5'd9 , 3'd1 } : vlc32 = { 32'h9, 32'h7FF, 8'd11 }; /*str=00000001001*/
            { 2'd3, 5'd9 , 3'd1 } : vlc32 = { 32'h4, 32'h1FF, 8'd9 }; /*str=000000100*/
            { 2'd0, 5'd10, 3'd1 } : vlc32 = { 32'hB, 32'hFFF, 8'd12 }; /*str=000000001011*/
            { 2'd1, 5'd10, 3'd1 } : vlc32 = { 32'hE, 32'hFFF, 8'd12 }; /*str=000000001110*/
            { 2'd2, 5'd10, 3'd1 } : vlc32 = { 32'hD, 32'hFFF, 8'd12 }; /*str=000000001101*/
            { 2'd3, 5'd10, 3'd1 } : vlc32 = { 32'hC, 32'h7FF, 8'd11 }; /*str=00000001100*/
            { 2'd0, 5'd11, 3'd1 } : vlc32 = { 32'h8, 32'hFFF, 8'd12 }; /*str=000000001000*/
            { 2'd1, 5'd11, 3'd1 } : vlc32 = { 32'hA, 32'hFFF, 8'd12 }; /*str=000000001010*/
            { 2'd2, 5'd11, 3'd1 } : vlc32 = { 32'h9, 32'hFFF, 8'd12 }; /*str=000000001001*/
            { 2'd3, 5'd11, 3'd1 } : vlc32 = { 32'h8, 32'h7FF, 8'd11 }; /*str=00000001000*/
            { 2'd0, 5'd12, 3'd1 } : vlc32 = { 32'hF, 32'h1FFF, 8'd13 }; /*str=0000000001111*/
            { 2'd1, 5'd12, 3'd1 } : vlc32 = { 32'hE, 32'h1FFF, 8'd13 }; /*str=0000000001110*/
            { 2'd2, 5'd12, 3'd1 } : vlc32 = { 32'hD, 32'h1FFF, 8'd13 }; /*str=0000000001101*/
            { 2'd3, 5'd12, 3'd1 } : vlc32 = { 32'hC, 32'hFFF, 8'd12 }; /*str=000000001100*/
            { 2'd0, 5'd13, 3'd1 } : vlc32 = { 32'hB, 32'h1FFF, 8'd13 }; /*str=0000000001011*/
            { 2'd1, 5'd13, 3'd1 } : vlc32 = { 32'hA, 32'h1FFF, 8'd13 }; /*str=0000000001010*/
            { 2'd2, 5'd13, 3'd1 } : vlc32 = { 32'h9, 32'h1FFF, 8'd13 }; /*str=0000000001001*/
            { 2'd3, 5'd13, 3'd1 } : vlc32 = { 32'hC, 32'h1FFF, 8'd13 }; /*str=0000000001100*/
            { 2'd0, 5'd14, 3'd1 } : vlc32 = { 32'h7, 32'h1FFF, 8'd13 }; /*str=0000000000111*/
            { 2'd1, 5'd14, 3'd1 } : vlc32 = { 32'hB, 32'h3FFF, 8'd14 }; /*str=00000000001011*/
            { 2'd2, 5'd14, 3'd1 } : vlc32 = { 32'h6, 32'h1FFF, 8'd13 }; /*str=0000000000110*/
            { 2'd3, 5'd14, 3'd1 } : vlc32 = { 32'h8, 32'h1FFF, 8'd13 }; /*str=0000000001000*/
            { 2'd0, 5'd15, 3'd1 } : vlc32 = { 32'h9, 32'h3FFF, 8'd14 }; /*str=00000000001001*/
            { 2'd1, 5'd15, 3'd1 } : vlc32 = { 32'h8, 32'h3FFF, 8'd14 }; /*str=00000000001000*/
            { 2'd2, 5'd15, 3'd1 } : vlc32 = { 32'hA, 32'h3FFF, 8'd14 }; /*str=00000000001010*/
            { 2'd3, 5'd15, 3'd1 } : vlc32 = { 32'h1, 32'h1FFF, 8'd13 }; /*str=0000000000001*/
            { 2'd0, 5'd16, 3'd1 } : vlc32 = { 32'h7, 32'h3FFF, 8'd14 }; /*str=00000000000111*/
            { 2'd1, 5'd16, 3'd1 } : vlc32 = { 32'h6, 32'h3FFF, 8'd14 }; /*str=00000000000110*/
            { 2'd2, 5'd16, 3'd1 } : vlc32 = { 32'h5, 32'h3FFF, 8'd14 }; /*str=00000000000101*/
            { 2'd3, 5'd16, 3'd1 } : vlc32 = { 32'h4, 32'h3FFF, 8'd14 }; /*str=00000000000100*/
            { 2'd0, 5'd1 , 3'd2 } : vlc32 = { 32'hF, 32'h3F, 8'd6 }; /*str=001111*/
            { 2'd1, 5'd1 , 3'd2 } : vlc32 = { 32'hE, 32'hF, 8'd4 }; /*str=1110*/
            { 2'd0, 5'd2 , 3'd2 } : vlc32 = { 32'hB, 32'h3F, 8'd6 }; /*str=001011*/
            { 2'd1, 5'd2 , 3'd2 } : vlc32 = { 32'hF, 32'h1F, 8'd5 }; /*str=01111*/
            { 2'd2, 5'd2 , 3'd2 } : vlc32 = { 32'hD, 32'hF, 8'd4 }; /*str=1101*/
            { 2'd0, 5'd3 , 3'd2 } : vlc32 = { 32'h8, 32'h3F, 8'd6 }; /*str=001000*/
            { 2'd1, 5'd3 , 3'd2 } : vlc32 = { 32'hC, 32'h1F, 8'd5 }; /*str=01100*/
            { 2'd2, 5'd3 , 3'd2 } : vlc32 = { 32'hE, 32'h1F, 8'd5 }; /*str=01110*/
            { 2'd3, 5'd3 , 3'd2 } : vlc32 = { 32'hC, 32'hF, 8'd4 }; /*str=1100*/
            { 2'd0, 5'd4 , 3'd2 } : vlc32 = { 32'hF, 32'h7F, 8'd7 }; /*str=0001111*/
            { 2'd1, 5'd4 , 3'd2 } : vlc32 = { 32'hA, 32'h1F, 8'd5 }; /*str=01010*/
            { 2'd2, 5'd4 , 3'd2 } : vlc32 = { 32'hB, 32'h1F, 8'd5 }; /*str=01011*/
            { 2'd3, 5'd4 , 3'd2 } : vlc32 = { 32'hB, 32'hF, 8'd4 }; /*str=1011*/
            { 2'd0, 5'd5 , 3'd2 } : vlc32 = { 32'hB, 32'h7F, 8'd7 }; /*str=0001011*/
            { 2'd1, 5'd5 , 3'd2 } : vlc32 = { 32'h8, 32'h1F, 8'd5 }; /*str=01000*/
            { 2'd2, 5'd5 , 3'd2 } : vlc32 = { 32'h9, 32'h1F, 8'd5 }; /*str=01001*/
            { 2'd3, 5'd5 , 3'd2 } : vlc32 = { 32'hA, 32'hF, 8'd4 }; /*str=1010*/
            { 2'd0, 5'd6 , 3'd2 } : vlc32 = { 32'h9, 32'h7F, 8'd7 }; /*str=0001001*/
            { 2'd1, 5'd6 , 3'd2 } : vlc32 = { 32'hE, 32'h3F, 8'd6 }; /*str=001110*/
            { 2'd2, 5'd6 , 3'd2 } : vlc32 = { 32'hD, 32'h3F, 8'd6 }; /*str=001101*/
            { 2'd3, 5'd6 , 3'd2 } : vlc32 = { 32'h9, 32'hF, 8'd4 }; /*str=1001*/
            { 2'd0, 5'd7 , 3'd2 } : vlc32 = { 32'h8, 32'h7F, 8'd7 }; /*str=0001000*/
            { 2'd1, 5'd7 , 3'd2 } : vlc32 = { 32'hA, 32'h3F, 8'd6 }; /*str=001010*/
            { 2'd2, 5'd7 , 3'd2 } : vlc32 = { 32'h9, 32'h3F, 8'd6 }; /*str=001001*/
            { 2'd3, 5'd7 , 3'd2 } : vlc32 = { 32'h8, 32'hF, 8'd4 }; /*str=1000*/
            { 2'd0, 5'd8 , 3'd2 } : vlc32 = { 32'hF, 32'hFF, 8'd8 }; /*str=00001111*/
            { 2'd1, 5'd8 , 3'd2 } : vlc32 = { 32'hE, 32'h7F, 8'd7 }; /*str=0001110*/
            { 2'd2, 5'd8 , 3'd2 } : vlc32 = { 32'hD, 32'h7F, 8'd7 }; /*str=0001101*/
            { 2'd3, 5'd8 , 3'd2 } : vlc32 = { 32'hD, 32'h1F, 8'd5 }; /*str=01101*/
            { 2'd0, 5'd9 , 3'd2 } : vlc32 = { 32'hB, 32'hFF, 8'd8 }; /*str=00001011*/
            { 2'd1, 5'd9 , 3'd2 } : vlc32 = { 32'hE, 32'hFF, 8'd8 }; /*str=00001110*/
            { 2'd2, 5'd9 , 3'd2 } : vlc32 = { 32'hA, 32'h7F, 8'd7 }; /*str=0001010*/
            { 2'd3, 5'd9 , 3'd2 } : vlc32 = { 32'hC, 32'h3F, 8'd6 }; /*str=001100*/
            { 2'd0, 5'd10, 3'd2 } : vlc32 = { 32'hF, 32'h1FF, 8'd9 }; /*str=000001111*/
            { 2'd1, 5'd10, 3'd2 } : vlc32 = { 32'hA, 32'hFF, 8'd8 }; /*str=00001010*/
            { 2'd2, 5'd10, 3'd2 } : vlc32 = { 32'hD, 32'hFF, 8'd8 }; /*str=00001101*/
            { 2'd3, 5'd10, 3'd2 } : vlc32 = { 32'hC, 32'h7F, 8'd7 }; /*str=0001100*/
            { 2'd0, 5'd11, 3'd2 } : vlc32 = { 32'hB, 32'h1FF, 8'd9 }; /*str=000001011*/
            { 2'd1, 5'd11, 3'd2 } : vlc32 = { 32'hE, 32'h1FF, 8'd9 }; /*str=000001110*/
            { 2'd2, 5'd11, 3'd2 } : vlc32 = { 32'h9, 32'hFF, 8'd8 }; /*str=00001001*/
            { 2'd3, 5'd11, 3'd2 } : vlc32 = { 32'hC, 32'hFF, 8'd8 }; /*str=00001100*/
            { 2'd0, 5'd12, 3'd2 } : vlc32 = { 32'h8, 32'h1FF, 8'd9 }; /*str=000001000*/
            { 2'd1, 5'd12, 3'd2 } : vlc32 = { 32'hA, 32'h1FF, 8'd9 }; /*str=000001010*/
            { 2'd2, 5'd12, 3'd2 } : vlc32 = { 32'hD, 32'h1FF, 8'd9 }; /*str=000001101*/
            { 2'd3, 5'd12, 3'd2 } : vlc32 = { 32'h8, 32'hFF, 8'd8 }; /*str=00001000*/
            { 2'd0, 5'd13, 3'd2 } : vlc32 = { 32'hD, 32'h3FF, 8'd10 }; /*str=0000001101*/
            { 2'd1, 5'd13, 3'd2 } : vlc32 = { 32'h7, 32'h1FF, 8'd9 }; /*str=000000111*/
            { 2'd2, 5'd13, 3'd2 } : vlc32 = { 32'h9, 32'h1FF, 8'd9 }; /*str=000001001*/
            { 2'd3, 5'd13, 3'd2 } : vlc32 = { 32'hC, 32'h1FF, 8'd9 }; /*str=000001100*/
            { 2'd0, 5'd14, 3'd2 } : vlc32 = { 32'h9, 32'h3FF, 8'd10 }; /*str=0000001001*/
            { 2'd1, 5'd14, 3'd2 } : vlc32 = { 32'hC, 32'h3FF, 8'd10 }; /*str=0000001100*/
            { 2'd2, 5'd14, 3'd2 } : vlc32 = { 32'hB, 32'h3FF, 8'd10 }; /*str=0000001011*/
            { 2'd3, 5'd14, 3'd2 } : vlc32 = { 32'hA, 32'h3FF, 8'd10 }; /*str=0000001010*/
            { 2'd0, 5'd15, 3'd2 } : vlc32 = { 32'h5, 32'h3FF, 8'd10 }; /*str=0000000101*/
            { 2'd1, 5'd15, 3'd2 } : vlc32 = { 32'h8, 32'h3FF, 8'd10 }; /*str=0000001000*/
            { 2'd2, 5'd15, 3'd2 } : vlc32 = { 32'h7, 32'h3FF, 8'd10 }; /*str=0000000111*/
            { 2'd3, 5'd15, 3'd2 } : vlc32 = { 32'h6, 32'h3FF, 8'd10 }; /*str=0000000110*/
            { 2'd0, 5'd16, 3'd2 } : vlc32 = { 32'h1, 32'h3FF, 8'd10 }; /*str=0000000001*/
            { 2'd1, 5'd16, 3'd2 } : vlc32 = { 32'h4, 32'h3FF, 8'd10 }; /*str=0000000100*/
            { 2'd2, 5'd16, 3'd2 } : vlc32 = { 32'h3, 32'h3FF, 8'd10 }; /*str=0000000011*/
            { 2'd3, 5'd16, 3'd2 } : vlc32 = { 32'h2, 32'h3FF, 8'd10 }; /*str=0000000010*/
            { 2'd0, 5'd1 , 3'd3 } : vlc32 = { 32'h0, 32'h3F, 8'd6 }; /*str=000000*/
            { 2'd1, 5'd1 , 3'd3 } : vlc32 = { 32'h1, 32'h3F, 8'd6 }; /*str=000001*/
            { 2'd0, 5'd2 , 3'd3 } : vlc32 = { 32'h4, 32'h3F, 8'd6 }; /*str=000100*/
            { 2'd1, 5'd2 , 3'd3 } : vlc32 = { 32'h5, 32'h3F, 8'd6 }; /*str=000101*/
            { 2'd2, 5'd2 , 3'd3 } : vlc32 = { 32'h6, 32'h3F, 8'd6 }; /*str=000110*/
            { 2'd0, 5'd3 , 3'd3 } : vlc32 = { 32'h8, 32'h3F, 8'd6 }; /*str=001000*/
            { 2'd1, 5'd3 , 3'd3 } : vlc32 = { 32'h9, 32'h3F, 8'd6 }; /*str=001001*/
            { 2'd2, 5'd3 , 3'd3 } : vlc32 = { 32'hA, 32'h3F, 8'd6 }; /*str=001010*/
            { 2'd3, 5'd3 , 3'd3 } : vlc32 = { 32'hB, 32'h3F, 8'd6 }; /*str=001011*/
            { 2'd0, 5'd4 , 3'd3 } : vlc32 = { 32'hC, 32'h3F, 8'd6 }; /*str=001100*/
            { 2'd1, 5'd4 , 3'd3 } : vlc32 = { 32'hD, 32'h3F, 8'd6 }; /*str=001101*/
            { 2'd2, 5'd4 , 3'd3 } : vlc32 = { 32'hE, 32'h3F, 8'd6 }; /*str=001110*/
            { 2'd3, 5'd4 , 3'd3 } : vlc32 = { 32'hF, 32'h3F, 8'd6 }; /*str=001111*/
            { 2'd0, 5'd5 , 3'd3 } : vlc32 = { 32'h10, 32'h3F, 8'd6 }; /*str=010000*/
            { 2'd1, 5'd5 , 3'd3 } : vlc32 = { 32'h11, 32'h3F, 8'd6 }; /*str=010001*/
            { 2'd2, 5'd5 , 3'd3 } : vlc32 = { 32'h12, 32'h3F, 8'd6 }; /*str=010010*/
            { 2'd3, 5'd5 , 3'd3 } : vlc32 = { 32'h13, 32'h3F, 8'd6 }; /*str=010011*/
            { 2'd0, 5'd6 , 3'd3 } : vlc32 = { 32'h14, 32'h3F, 8'd6 }; /*str=010100*/
            { 2'd1, 5'd6 , 3'd3 } : vlc32 = { 32'h15, 32'h3F, 8'd6 }; /*str=010101*/
            { 2'd2, 5'd6 , 3'd3 } : vlc32 = { 32'h16, 32'h3F, 8'd6 }; /*str=010110*/
            { 2'd3, 5'd6 , 3'd3 } : vlc32 = { 32'h17, 32'h3F, 8'd6 }; /*str=010111*/
            { 2'd0, 5'd7 , 3'd3 } : vlc32 = { 32'h18, 32'h3F, 8'd6 }; /*str=011000*/
            { 2'd1, 5'd7 , 3'd3 } : vlc32 = { 32'h19, 32'h3F, 8'd6 }; /*str=011001*/
            { 2'd2, 5'd7 , 3'd3 } : vlc32 = { 32'h1A, 32'h3F, 8'd6 }; /*str=011010*/
            { 2'd3, 5'd7 , 3'd3 } : vlc32 = { 32'h1B, 32'h3F, 8'd6 }; /*str=011011*/
            { 2'd0, 5'd8 , 3'd3 } : vlc32 = { 32'h1C, 32'h3F, 8'd6 }; /*str=011100*/
            { 2'd1, 5'd8 , 3'd3 } : vlc32 = { 32'h1D, 32'h3F, 8'd6 }; /*str=011101*/
            { 2'd2, 5'd8 , 3'd3 } : vlc32 = { 32'h1E, 32'h3F, 8'd6 }; /*str=011110*/
            { 2'd3, 5'd8 , 3'd3 } : vlc32 = { 32'h1F, 32'h3F, 8'd6 }; /*str=011111*/
            { 2'd0, 5'd9 , 3'd3 } : vlc32 = { 32'h20, 32'h3F, 8'd6 }; /*str=100000*/
            { 2'd1, 5'd9 , 3'd3 } : vlc32 = { 32'h21, 32'h3F, 8'd6 }; /*str=100001*/
            { 2'd2, 5'd9 , 3'd3 } : vlc32 = { 32'h22, 32'h3F, 8'd6 }; /*str=100010*/
            { 2'd3, 5'd9 , 3'd3 } : vlc32 = { 32'h23, 32'h3F, 8'd6 }; /*str=100011*/
            { 2'd0, 5'd10, 3'd3 } : vlc32 = { 32'h24, 32'h3F, 8'd6 }; /*str=100100*/
            { 2'd1, 5'd10, 3'd3 } : vlc32 = { 32'h25, 32'h3F, 8'd6 }; /*str=100101*/
            { 2'd2, 5'd10, 3'd3 } : vlc32 = { 32'h26, 32'h3F, 8'd6 }; /*str=100110*/
            { 2'd3, 5'd10, 3'd3 } : vlc32 = { 32'h27, 32'h3F, 8'd6 }; /*str=100111*/
            { 2'd0, 5'd11, 3'd3 } : vlc32 = { 32'h28, 32'h3F, 8'd6 }; /*str=101000*/
            { 2'd1, 5'd11, 3'd3 } : vlc32 = { 32'h29, 32'h3F, 8'd6 }; /*str=101001*/
            { 2'd2, 5'd11, 3'd3 } : vlc32 = { 32'h2A, 32'h3F, 8'd6 }; /*str=101010*/
            { 2'd3, 5'd11, 3'd3 } : vlc32 = { 32'h2B, 32'h3F, 8'd6 }; /*str=101011*/
            { 2'd0, 5'd12, 3'd3 } : vlc32 = { 32'h2C, 32'h3F, 8'd6 }; /*str=101100*/
            { 2'd1, 5'd12, 3'd3 } : vlc32 = { 32'h2D, 32'h3F, 8'd6 }; /*str=101101*/
            { 2'd2, 5'd12, 3'd3 } : vlc32 = { 32'h2E, 32'h3F, 8'd6 }; /*str=101110*/
            { 2'd3, 5'd12, 3'd3 } : vlc32 = { 32'h2F, 32'h3F, 8'd6 }; /*str=101111*/
            { 2'd0, 5'd13, 3'd3 } : vlc32 = { 32'h30, 32'h3F, 8'd6 }; /*str=110000*/
            { 2'd1, 5'd13, 3'd3 } : vlc32 = { 32'h31, 32'h3F, 8'd6 }; /*str=110001*/
            { 2'd2, 5'd13, 3'd3 } : vlc32 = { 32'h32, 32'h3F, 8'd6 }; /*str=110010*/
            { 2'd3, 5'd13, 3'd3 } : vlc32 = { 32'h33, 32'h3F, 8'd6 }; /*str=110011*/
            { 2'd0, 5'd14, 3'd3 } : vlc32 = { 32'h34, 32'h3F, 8'd6 }; /*str=110100*/
            { 2'd1, 5'd14, 3'd3 } : vlc32 = { 32'h35, 32'h3F, 8'd6 }; /*str=110101*/
            { 2'd2, 5'd14, 3'd3 } : vlc32 = { 32'h36, 32'h3F, 8'd6 }; /*str=110110*/
            { 2'd3, 5'd14, 3'd3 } : vlc32 = { 32'h37, 32'h3F, 8'd6 }; /*str=110111*/
            { 2'd0, 5'd15, 3'd3 } : vlc32 = { 32'h38, 32'h3F, 8'd6 }; /*str=111000*/
            { 2'd1, 5'd15, 3'd3 } : vlc32 = { 32'h39, 32'h3F, 8'd6 }; /*str=111001*/
            { 2'd2, 5'd15, 3'd3 } : vlc32 = { 32'h3A, 32'h3F, 8'd6 }; /*str=111010*/
            { 2'd3, 5'd15, 3'd3 } : vlc32 = { 32'h3B, 32'h3F, 8'd6 }; /*str=111011*/
            { 2'd0, 5'd16, 3'd3 } : vlc32 = { 32'h3C, 32'h3F, 8'd6 }; /*str=111100*/
            { 2'd1, 5'd16, 3'd3 } : vlc32 = { 32'h3D, 32'h3F, 8'd6 }; /*str=111101*/
            { 2'd2, 5'd16, 3'd3 } : vlc32 = { 32'h3E, 32'h3F, 8'd6 }; /*str=111110*/
            { 2'd3, 5'd16, 3'd3 } : vlc32 = { 32'h3F, 32'h3F, 8'd6 }; /*str=111111*/
            { 2'd0, 5'd1 , 3'd4 } : vlc32 = { 32'h7, 32'h3F, 8'd6 }; /*str=000111*/
            { 2'd1, 5'd1 , 3'd4 } : vlc32 = { 32'h1, 32'h1, 8'd1 }; /*str=1*/
            { 2'd0, 5'd2 , 3'd4 } : vlc32 = { 32'h4, 32'h3F, 8'd6 }; /*str=000100*/
            { 2'd1, 5'd2 , 3'd4 } : vlc32 = { 32'h6, 32'h3F, 8'd6 }; /*str=000110*/
            { 2'd2, 5'd2 , 3'd4 } : vlc32 = { 32'h1, 32'h7, 8'd3 }; /*str=001*/
            { 2'd0, 5'd3 , 3'd4 } : vlc32 = { 32'h3, 32'h3F, 8'd6 }; /*str=000011*/
            { 2'd1, 5'd3 , 3'd4 } : vlc32 = { 32'h3, 32'h7F, 8'd7 }; /*str=0000011*/
            { 2'd2, 5'd3 , 3'd4 } : vlc32 = { 32'h2, 32'h7F, 8'd7 }; /*str=0000010*/
            { 2'd3, 5'd3 , 3'd4 } : vlc32 = { 32'h5, 32'h3F, 8'd6 }; /*str=000101*/
            { 2'd0, 5'd4 , 3'd4 } : vlc32 = { 32'h2, 32'h3F, 8'd6 }; /*str=000010*/
            { 2'd1, 5'd4 , 3'd4 } : vlc32 = { 32'h3, 32'hFF, 8'd8 }; /*str=00000011*/
            { 2'd2, 5'd4 , 3'd4 } : vlc32 = { 32'h2, 32'hFF, 8'd8 }; /*str=00000010*/
            { 2'd3, 5'd4 , 3'd4 } : vlc32 = { 32'h0, 32'h7F, 8'd7 }; /*str=0000000*/
            default        : vlc32 = {72{1'bx}}; // don't care
        endcase
    end 
endmodule