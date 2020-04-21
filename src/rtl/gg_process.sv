`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/20/2020 10:57:41 AM
// Design Name: 
// Module Name: gg_process
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


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
    
    logic [12:0] qptab[102];
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
        {qp[5:0], qpmod6[2:0], qpdiv6[3:0]} = qptab[{qpy[5:0], ch_flag}][12:0];
    end
  
    // Create forward quant matrix
    
    logic [13:0] fvmat0[6], fvmat1[6], fvmat2[6];
    logic [13:0] fvm0, fvm1, fvm2;
    logic [13:0] quant[16];
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

	
    
endmodule
