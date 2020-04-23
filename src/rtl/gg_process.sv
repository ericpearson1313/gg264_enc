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
    output logic [4:0] num_coeff, // Count of non-zero block coeffs
    input wire abv_out_of_pic,
    input wire left_out_of_pic,
    input wire [7:0] abv_nc[4],
    output logic [7:0] below_nc[4]
    );
    
    // Flags
	wire dc_flag = ( cidx[2:0] == 4 || cidx[2:0] == 5 || cidx[2:0] == 6) ? 1'b1 : 1'b0;
	wire ac_flag = ( cidx[2:0] == 1 || cidx[2:0] == 2 || cidx[2:0] == 3) ? 1'b1 : 1'b0;
	wire ch_flag = ( cidx[2:0] == 2 || cidx[2:0] == 3 || cidx[2:0] == 4 || cidx[2:0] == 5) ? 1'b1 :1'b 0;    
	
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
	logic [19:0] coeff[16];

 	// // Forward quant 16 coeffs
	// for (int ii = 0; ii < 16; ii++) {
	// 	abscoeff = (e[ii] < 0) ? -e[ii] : e[ii]; // remove the sign, so we round down towards zero using >>
	// 	negcoeff = (e[ii] < 0) ? 1 : 0; // we will restore the sign after quantization
	// 	quant = (dc_flag) ? Qmat[qp % 6][0][0] : Qmat[qp % 6][ii >> 2][ii & 3];
	// 	qshift = (qp / 6) + ((dc_flag & !ch_flag) ? 9 : (dc_flag && ch_flag) ? 8 : 7);
	// 	qc = ((abscoeff * quant) >> qshift ) + offset; // 8 fractional bits still remain, larger dc shift
	// 	qcdz = (qc < deadzone) ? 0 : (qc >> 8);
	// 	coeff[ii] = (negcoeff) ? -qcdz : qcdz;
	// }	
	
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
            // Note: max encodable coeff, in general is -2063 to 2063 (suffix len = 0 or 1), 
            // larger ranges for suffix lenths 2,3,4,5,6 , up to +/-480
            // should bypass as PCM, and/or clip the values if too large. Flag this for sure.
            quant_clip[ii][11:0] = ( quant_dz[ii][18:0] > 19'd2063 ) ? 12'd2063 : quant_dz[ii][11:0]; 
            coeff[ii][12:0]     = ( negcoeff[ii] ) ? ~quant_clip[ii][11:0] + 1 : quant_clip[ii][11:0];
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

	//int dequant;
	//int coeff_dc;
	//if (dc_flag) { // Just copy DC coeff, will be quanted later along with AC
	//	if (ch_flag) { // sub-sample coeffs for ch dc
	//		for (int ii = 0; ii < 16; f[ii++] = 0);
	//		f[0] = coeff[0];
	//		f[2] = coeff[1];
	//		f[8] = coeff[4];
	//		f[10] = coeff[5];
	//	}
	//	else { // copy all coeff unquantized
	//		for (int ii = 0; ii < 16; ii++) {
	//			f[ii] = coeff[ii];
	//		}
	//	}
	//}
	//else { // Inverse quant 4x4, with special scaling for DC coeff when appropriate
	//	for (int ii = 0; ii < 16; ii++) { 
	//		if (ii == 0 && ac_flag && ch_flag) { // Handle Chroma dc coeff
	//			dequant = 16 * Dmat[qp % 6][0][0];
	//			coeff_dc = dc_hold[((bidx&1)<<0)+((bidx&2)<<1)]; // sample 0,1,4,5
	//			f[0] = ((coeff_dc * dequant) << (qp / 6)) >> 5;
	//		}
	//		else if (ii == 0 && ac_flag) { // Intra 16 dc coeff
	//			dequant = 16 * Dmat[qp % 6][0][0];
	//			coeff_dc = dc_hold[((bidx & 1) << 0) + ((bidx & 2) << 1) + ((bidx & 4) >> 1) + ((bidx & 8) << 0)];
	//			if (qp >= 36) {
	//				f[0] = (coeff_dc * dequant) << (qp / 6 - 6);
	//			}
	//			else { // qp < 36
	//				f[0] = (coeff_dc * dequant + (1 << (5 - qp / 6))) >> (6 - qp / 6);
	//			}
	//		}
	//		else { // normal 4x4 quant
	//			dequant = 16 * Dmat[qp % 6][ii >> 2][ii & 3];
	//			if (qp >= 24) {
	//				f[ii] = (coeff[ii] * dequant) << (qp / 6 - 4);
	//			}
	//			else { // qp < 24
	//				f[ii] = (coeff[ii] * dequant + (1 << (3 - qp / 6))) >> (4 - qp / 6);
	//			}
	//		}
	//	}
	//}

	/////////////////////////////////////////
	// Inverse Transform (f->res)
	/////////////////////////////////////////

    // assert f[16] shall fit in 16 bit signed.
    
	//for (int row = 0; row < 4; row++) {// row 1d transforms
	//	g[0] = f[row * 4 + 0] + f[row * 4 + 2];
	//	g[1] = f[row * 4 + 0] - f[row * 4 + 2];
	//	g[2] = (f[row * 4 + 1] >> ((dc_flag)?0:1)) - f[row * 4 + 3];
	//	g[3] = f[row * 4 + 1] + (f[row * 4 + 3] >> ((dc_flag) ? 0 : 1));
	//	h[row * 4 + 0] = g[0] + g[3]; // 0+2+1+3
	//	h[row * 4 + 1] = g[1] + g[2]; // 0-2+1-3
	//	h[row * 4 + 2] = g[1] - g[2]; // 0-2-1+3
	//	h[row * 4 + 3] = g[0] - g[3]; // 0+2-1-3
	//}
	//// assert g[4], h[16] in 16bit signed
    //
	//for (int col = 0; col < 4; col++) {// col 1d transforms
	//	k[0] = h[col + 4 * 0] + h[col + 4 * 2];
	//	k[1] = h[col + 4 * 0] - h[col + 4 * 2];
	//	k[2] = (h[col + 4 * 1] >> ((dc_flag) ? 0 : 1)) - h[col + 4 * 3];
	//	k[3] = h[col + 4 * 1] + (h[col + 4 * 3] >> ((dc_flag) ? 0 : 1));
	//	m[col + 4 * 0] = k[0] + k[3];
	//	m[col + 4 * 1] = k[1] + k[2];
	//	m[col + 4 * 2] = k[1] - k[2];
	//	m[col + 4 * 3] = k[0] - k[3];
	//}
	//// assert k[16], m[4] in 16 bits
    //
	//if (dc_flag) { // save results to DC hold
	//	for (int ii = 0; ii < 16; ii++) {
	//		dc_hold[ii] = m[ii]; // save away inverse transformed DC for following AC
	//	}
	//}
	//else { // Luma / Chroma 4x4 transform
	//	for (int ii = 0; ii < 16; ii++) {
	//		res[ii] = (m[ii] + 32) >> 6;
	//	}
	//}


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
        last_coeff = ( sig_coeff_flag[15] ) ? 5'd16 :
                     ( sig_coeff_flag[14] ) ? 5'd15 :
                     ( sig_coeff_flag[13] ) ? 5'd14 :
                     ( sig_coeff_flag[12] ) ? 5'd13 :
                     ( sig_coeff_flag[11] ) ? 5'd12 :
                     ( sig_coeff_flag[10] ) ? 5'd11 :
                     ( sig_coeff_flag[ 9] ) ? 5'd10 :
                     ( sig_coeff_flag[ 8] ) ? 5'd9 :
                     ( sig_coeff_flag[ 7] ) ? 5'd8 :
                     ( sig_coeff_flag[ 6] ) ? 5'd7 :
                     ( sig_coeff_flag[ 5] ) ? 5'd6 :
                     ( sig_coeff_flag[ 4] ) ? 5'd5 :
                     ( sig_coeff_flag[ 3] ) ? 5'd4 :
                     ( sig_coeff_flag[ 2] ) ? 5'd3 :
                     ( sig_coeff_flag[ 1] ) ? 5'd2 :
                     ( sig_coeff_flag[ 0] ) ? 5'd1 : 5'd0;
         total_zeros = last_coeff - num_coeff;
    end

	//////////////////////////////////////////
	// Syntax Element: Trailing_ones_sign_flag
	//////////////////////////////////////////


    logic [15:0] one_flag;
    logic [15:0] gt1_flag;
    logic [15:0][1:0] t1_count;
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

	// int coeff_table_idx;
	// vlc_t vlc_coeff_token;
    // 
	// if (ch_flag && dc_flag) {
	// 	coeff_table_idx = 4;
	// } else if ( dc_flag ) {
	// 	int nc = lefnc[0] + abvnc[0];
	// 	coeff_table_idx = (nc < 2) ? 0 : (nc < 4) ? 1 : (nc < 8) ? 2 : 3;
	// }
	// else {
	// 	int abv_idx = (bidx & 1) + ((bidx & 4) >> 1);
	// 	int lef_idx = ((bidx & 2) >> 1) + ((bidx & 8) >> 2);
	// 	int nc;
	// 	if (lefnc[lef_idx] != -1 && abvnc[abv_idx] != -1) {
	// 		nc = (lefnc[lef_idx] + abvnc[abv_idx] +1)>>1;
	// 	}
	// 	else if (lefnc[lef_idx] != -1) {
	// 		nc = lefnc[lef_idx];
	// 	}
	// 	else if (abvnc[abv_idx] != -1) {
	// 		nc = abvnc[abv_idx];
	// 	}
	// 	else {
	// 		nc = 0;
	// 	}
	// 	coeff_table_idx = (nc < 2) ? 0 : (nc < 4) ? 1 : (nc < 8) ? 2 : 3;
	// 	// Update 
	// 	lefnc[lef_idx] = num_coeff;
	// 	abvnc[abv_idx] = num_coeff;
	// }
    // 
	// vlc_coeff_token = ( num_coeff == 0 ) ? x264_coeff0_token[coeff_table_idx] : x264_coeff_token[coeff_table_idx][num_coeff-1][trailing_ones];

   
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

	// vlc_t vlc_run_before[14];
    // 
	// for (int ii = 0; ii < 14; ii++) {
	// 	vlc_run_before[ii].i_size = 0;
	// 	vlc_run_before[ii].i_bits = 0;
	// }
    // 
	// int zeros = total_zeros;
	// int run = 0;
	// int last_sig;
	// if (num_coeff > 1 && total_zeros) {
	// 	for (last_sig = max_coeff - 1; scan[last_sig] == 0; last_sig--); // find last sign coeff
	// 	for (int coeff_idx = last_sig-1, sig_count = 0; (sig_count < num_coeff-1) && zeros; coeff_idx--) {
	// 		if (scan[coeff_idx]) {
	// 			vlc_run_before[sig_count] = x264_run_before_init[MIN(zeros-1, 6)][run];
	// 			sig_count++;
	// 			zeros -= run;
	// 			run = 0;
	// 		}
	// 		else {
	// 			run++;
	// 		}
	// 	}
	// }

	///////////////////////////////////////////////
	// Syntax Element: level_prefix, level_suffix
	///////////////////////////////////////////////
	
	// vlc_t vlc_level[16]; // Prefix + suffix
	// int suffix_length;
    // 
	// for (int ii = 0; ii < 16; ii++) {
	// 	vlc_level[ii].i_size = 0;
	// 	vlc_level[ii].i_bits = 0;
	// }
    // 
	// // select starting suffix.
	// suffix_length = ( num_coeff > 10 && trailing_ones < 3) ? 1 : 0;
    // 
	// // Code significant coeffs
	// if (num_coeff && num_coeff > trailing_ones) { // encode the coeffs
	// 	int level_code;
	// 	for (int sig_count = 0, coeff_idx = (max_coeff - 1); sig_count < num_coeff; coeff_idx--) {
	// 		if (scan[coeff_idx]) {
	// 			sig_count++;
	// 			if (sig_count > trailing_ones) { // Encode coeff scan[coeff_idx]
	// 				vlc_level[coeff_idx].i_size = 0;
	// 				vlc_level[coeff_idx].i_bits = 0;
	// 				// calculate level code
	// 				level_code = (scan[coeff_idx] > 0) ? ((scan[coeff_idx] - 1) * 2) : ((-scan[coeff_idx] - 1) * 2 + 1);
	// 				level_code -= (trailing_ones < 3 && sig_count == (trailing_ones + 1)) ? 2 : 0;
	// 				// encode as prefix/suffix
	// 				if (suffix_length == 0) { // handle special case of 14
	// 					if (level_code < 14) { // unary + 0
	// 						vlc_level[coeff_idx].i_size = level_code+1;
	// 						vlc_level[coeff_idx].i_bits = 1;
	// 					}
	// 					else if (level_code < 30) { // prefix 14, 1, 34
	// 						vlc_level[coeff_idx].i_size = 19;
	// 						vlc_level[coeff_idx].i_bits = 16 + level_code - 14;
	// 					}
	// 					else { // prefix 15, 1, 12
	// 						vlc_level[coeff_idx].i_size = 28;
	// 						vlc_level[coeff_idx].i_bits = 4096 + level_code - 30;
	// 					}
	// 				}
	// 				else  { // suffix length 1 ... 6
	// 					if (level_code < (30 << (suffix_length - 1))) {
	// 						vlc_level[coeff_idx].i_size = (level_code>>suffix_length) + 1 + suffix_length;
	// 						vlc_level[coeff_idx].i_bits = (1<<suffix_length) + (level_code & ((1<<suffix_length)-1)); // mask suffix length bits.
	// 					}
	// 					else { // Prefix 15, 1, 12
	// 						vlc_level[coeff_idx].i_size = 28;
	// 						vlc_level[coeff_idx].i_bits = 4096 + level_code - (30<<(suffix_length-1));
	// 					}
	// 				}
	// 				// update suffix_length state
	// 				if (suffix_length == 0)
	// 					suffix_length = 1;
	// 				if (ABS(scan[coeff_idx]) > (3 << (suffix_length - 1)) && suffix_length < 6)
	// 					suffix_length++;
	// 			}
	// 		}
	// 	}
	// }
	
	
    
endmodule

module table_9_10_run_before
(
    input logic [3:0] run_before,
    input logic [3:0] zeros_left,
    output logic [71:0] vlc32
);   
    always_comb begin
        unique case( { zeros_left[2:0], run_before[3:0] } ) // synopsys parallel_case  
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