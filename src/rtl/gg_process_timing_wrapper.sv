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

// This is a register wrapper for the combinayorial gg_process
// it is used during synthesis to get a feeling for Area vs Fmax

module gg_process_timing_wrapper(
    input  logic clk,
    input  logic [0:15][11:0]     orig_d,
    input  logic [0:15][11:0]     pred_d,
    output logic [0:15][7:0]   recon_q,
    input  logic [7:0] offset_d, // [0.8] with max of 128 to give 0.5 rounding
    input  logic [15:0] deadzone_d, // [8.8], with effective min of 255
    input  logic [5:0] qpy_d,
    input  logic [2:0] cidx_d, // cidx={0-luma, 1-acluma, 2-cb, 3-cr, 4-dccb, 5-dccr, 6-dcy}
    input  logic [3:0] bidx_d, // block IDX in h264 order
    output logic [11:0] sad_q, // 4x4 sum absolute difference
    output logic [19:0] ssd_q, // 4x4 sum of squared difference
    output logic [8:0] bitcount_q, // bitcount to code block
    output logic [511:0] bits_q, // output bits (max 501
    output logic [511:0] mask_q, // mask of valid output bits
    output logic [4:0] num_coeff_q, // Count of non-zero block coeffs
    input  logic abv_out_of_pic_d,
    input  logic left_out_of_pic_d,
    output logic [6:0] overflow_q
    );


    logic [0:15][11:0]  orig;
     logic [0:15][11:0]  pred;
     logic [7:0]   offset; // [0.8] with max of 128 to give 0.5 rounding
     logic [15:0] deadzone; // [8.8], with effective min of 255
     logic [5:0] qpy;
     logic [2:0] cidx; // cidx={0-luma, 1-acluma, 2-cb, 3-cr, 4-dccb, 5-dccr, 6-dcy}
     logic [3:0] bidx; // block IDX in h264 order
     logic abv_out_of_pic;
     logic left_out_of_pic;
     logic [3:0][7:0] above_nc_y;
     logic [1:0][7:0] above_nc_cb;
     logic [1:0][7:0] above_nc_cr;
    // Dut outputs
     logic [0:15][7:0]   recon;
     logic [8:0] bitcount;
     logic [511:0] bits;
     logic [511:0] mask;
     logic [11:0] sad;
     logic [19:0] ssd;
     logic [3:0][7:0] below_nc_y;
     logic [1:0][7:0] below_nc_cb;
     logic [1:0][7:0] below_nc_cr;
     logic [6:0] overflow;
     logic [4:0] num_coeff;
     logic [15:0][15:0] dc_hold;
     logic [15:0][15:0] dc_hold_dout;
     logic [0:3][7:0] left_nc_y;    
     logic [0:1][7:0] left_nc_cb;    
     logic [0:1][7:0] left_nc_cr;
     logic [0:3][7:0] right_nc_y;    
     logic [0:1][7:0] right_nc_cb;    
     logic [0:1][7:0] right_nc_cr;    
    
 gg_process  
   #(
        .BIT_LEN  ( 17 ), 
        .WORD_LEN ( 16 )
    ) gg_process_dut_
    (
        .clk ( clk ),  
        // Inputs
        .orig            ( orig           ), 
        .pred            ( pred           ), 
        .offset          ( offset         ), // [0.8] with max of 128 to give 0.5 rounding
        .deadzone        ( deadzone       ), // [8.8] with effective min of 255
        .qpy             ( qpy            ), 
        .cidx            ( cidx           ), // cidx={0-luma 1-acluma 2-cb 3-cr 4-dccb 5-dccr 6-dcy}
        .bidx            ( bidx           ), // block IDX in h264 order
        .abv_out_of_pic  ( abv_out_of_pic ), 
        .left_out_of_pic ( left_out_of_pic ), 
        .above_nc_y      ( above_nc_y     ), 
        .above_nc_cb     ( above_nc_cb    ), 
        .above_nc_cr     ( above_nc_cr    ), 
        .left_nc_y       ( left_nc_y      ), 
        .left_nc_cb      ( left_nc_cb     ), 
        .left_nc_cr      ( left_nc_cr     ), 
        .dc_hold         ( dc_hold        ),
        // Outputs
        .dc_hold_dout    ( dc_hold_dout   ),
        .recon           ( recon          ), 
        .bitcount        ( bitcount       ), // bitcount to code block
        .bits            ( bits           ), // output bits (max 497 bits)
        .mask            ( mask           ), // mask of valid output bits
        .num_coeff       ( num_coeff      ), // Count of non-zero block coeffs
        .sad             ( sad            ), // 4x4 sum absolute difference
        .ssd             ( ssd            ), // 4x4 sum of squared difference
        .below_nc_y      ( below_nc_y     ), // Num Coeff holding registers
        .below_nc_cb     ( below_nc_cb    ), //     to be saved for the below Macroblock Row inputs
        .below_nc_cr     ( below_nc_cr    ), //     these are updated with num_coeff 
        .right_nc_y      ( right_nc_y     ), 
        .right_nc_cb     ( right_nc_cb    ), 
        .right_nc_cr     ( right_nc_cr    ), 
        .overflow        ( overflow       )  // Overflow: 0-qdz, 1-iquant, 2..5-itran, 6-vlcp15
    );
    
    // Add State flops for left/above_nc, and dc_hold.
    
    always_ff @(posedge clk) begin
        dc_hold     <= dc_hold_dout;
        left_nc_y   <= right_nc_y;
        left_nc_cb  <= right_nc_cb;
        left_nc_cr  <= right_nc_cr;
        above_nc_y  <= below_nc_y;
        above_nc_cb <= below_nc_cb;
        above_nc_cr <= below_nc_cr;
    end
    
    // Add Input Flops
    
    always_ff @(posedge clk) begin
         orig <= orig_d;
         pred <= pred_d;
         offset <= offset_d;
         deadzone <=  deadzone_d;
         qpy <= qpy_d;
         cidx <= cidx_d;
         bidx <= bidx_d;
         sad <= sad_q;
         ssd <= ssd_q;
         abv_out_of_pic <= abv_out_of_pic_d;
         left_out_of_pic <= left_out_of_pic_d;
         end
     
    // Add Output Flops
    
    always_ff @(posedge clk) begin
          recon_q <= recon;
          bitcount_q <= bitcount;
          bits_q <= bits;
          mask_q <= mask;
          num_coeff_q <= num_coeff;
          overflow_q <= overflow;
    end
      
endmodule
