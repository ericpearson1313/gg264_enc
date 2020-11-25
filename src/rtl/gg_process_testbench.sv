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


module gg_process_testbench(

    );
    
    //////////////////////
    // Let there be Clock!
    //////////////////////
    
    logic clk;
    initial begin
        clk = 1'b1;
        forever begin
            #(5ns) clk = ~clk;
        end 
    end
    
    ///////////////////////
    // End of Time Default
    ///////////////////////
    
    initial begin
        #(900ns);
        $write("GOBBLE: Sim terminated; hard coded time limit reached.\n");
        $finish;
    end
    
    
    
    //////////////////////
    // Device Under Test
    //////////////////////

    // Dut inputs
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
    
    // Add testbench Flip Flops for left_nc, and dc_hold.
    
    always_ff @(posedge clk) begin
        dc_hold     <= dc_hold_dout;
        left_nc_y   <= right_nc_y;
        left_nc_cb  <= right_nc_cb;
        left_nc_cr  <= right_nc_cr;
        above_nc_y  <= below_nc_y;
        above_nc_cb <= below_nc_cb;
        above_nc_cr <= below_nc_cr;
    end
    
    // Decode testbench
    
     logic [3:0][7:0] iabove_nc_y;
     logic [1:0][7:0] iabove_nc_cb;
     logic [1:0][7:0] iabove_nc_cr;
     logic [3:0][7:0] ibelow_nc_y;
     logic [1:0][7:0] ibelow_nc_cb;
     logic [1:0][7:0] ibelow_nc_cr;
     logic [0:3][7:0] ileft_nc_y;    
     logic [0:1][7:0] ileft_nc_cb;    
     logic [0:1][7:0] ileft_nc_cr;
     logic [0:3][7:0] iright_nc_y;    
     logic [0:1][7:0] iright_nc_cb;    
     logic [0:1][7:0] iright_nc_cr;
     logic [15:0][15:0] idc_hold;
     logic [15:0][15:0] idc_hold_dout;
     logic [0:15][7:0]  irecon;
     logic [8:0] ibitcount;   
     logic [6:0] ioverflow;
     logic [4:0] inum_coeff;
     
   gg_iprocess  
   #(
        .BIT_LEN  ( 17 ), 
        .WORD_LEN ( 16 )
    ) gg_iprocess_dut_
    (
        .clk ( clk ),  
        // Inputs
        .pred            ( pred           ), 
        .qpy             ( qpy            ), 
        .cidx            ( cidx           ), // cidx={0-luma 1-acluma 2-cb 3-cr 4-dccb 5-dccr 6-dcy}
        .bidx            ( bidx           ), // block IDX in h264 order
        .abv_out_of_pic  ( abv_out_of_pic ), 
        .left_out_of_pic ( left_out_of_pic ), 
        .above_nc_y      ( iabove_nc_y     ), 
        .above_nc_cb     ( iabove_nc_cb    ), 
        .above_nc_cr     ( iabove_nc_cr    ), 
        .left_nc_y       ( ileft_nc_y      ), 
        .left_nc_cb      ( ileft_nc_cb     ), 
        .left_nc_cr      ( ileft_nc_cr     ), 
        .dc_hold         ( idc_hold        ),
        .bits            ( bits            ), // input bits (max 497 bits)
        .start_ofs       ( 512 - bitcount  ),
        // Outputs
        .dc_hold_dout    ( idc_hold_dout   ),
        .recon           ( irecon          ), 
        .bitcount        ( ibitcount       ), // bitcount to code block
        .num_coeff       ( inum_coeff      ), // Count of non-zero block coeffs
        .below_nc_y      ( ibelow_nc_y     ), // Num Coeff holding registers
        .below_nc_cb     ( ibelow_nc_cb    ), //     to be saved for the below Macroblock Row inputs
        .below_nc_cr     ( ibelow_nc_cr    ), //     these are updated with num_coeff 
        .right_nc_y      ( iright_nc_y     ), 
        .right_nc_cb     ( iright_nc_cb    ), 
        .right_nc_cr     ( iright_nc_cr    ), 
        .overflow        ( ioverflow       )  // Overflow: 0-qdz, 1-iquant, 2..5-itran, 6-vlcp15
    );

    // Add testbench Flip Flops for left_nc, and dc_hold.
    
    always_ff @(posedge clk) begin
        idc_hold     <= idc_hold_dout;
        ileft_nc_y   <= iright_nc_y;
        ileft_nc_cb  <= iright_nc_cb;
        ileft_nc_cr  <= iright_nc_cr;
        iabove_nc_y  <= ibelow_nc_y;
        iabove_nc_cb <= ibelow_nc_cb;
        iabove_nc_cr <= ibelow_nc_cr;
    end
    
 ///////////////////////////////////////////
 //
 //              TESTs
 //
 ///////////////////////////////////////////        
    
    logic [0:25][0:15][11:0] orig_mb_vec; // Very first test macroblock
    logic [0:23][0:15][ 7:0] recon_mb_vec; // frist mb recon (no chroma dc)
    logic [0:25][1032:0] vlc_mb_vec; // VLC format, 16 len, 512 data, 512 mask 
       
    assign orig_mb_vec = {
        { 12'h21, 12'h24, 12'h25, 12'h2C, 12'h44, 12'h41, 12'h3E, 12'h3E, 12'h62, 12'h5C, 12'h60, 12'h5E, 12'h74, 12'h72, 12'h74, 12'h77 },
        { 12'h24, 12'h26, 12'h24, 12'h24, 12'h39, 12'h36, 12'h3E, 12'h3C, 12'h5C, 12'h61, 12'h5A, 12'h51, 12'h7A, 12'h7B, 12'h79, 12'h68 },
        { 12'h55, 12'h58, 12'h58, 12'h5F, 12'h40, 12'h3D, 12'h44, 12'h52, 12'h3C, 12'h38, 12'h3F, 12'h5C, 12'h2D, 12'h29, 12'h43, 12'h73 },
        { 12'h63, 12'h68, 12'h63, 12'h5A, 12'h59, 12'h58, 12'h52, 12'h47, 12'h6F, 12'h6B, 12'h61, 12'h4E, 12'h96, 12'h92, 12'h73, 12'h5A },
        { 12'h27, 12'h27, 12'h2A, 12'h24, 12'h2F, 12'h27, 12'h2B, 12'h24, 12'h49, 12'h40, 12'h35, 12'h2F, 12'h51, 12'h49, 12'h42, 12'h41 },
        { 12'h1E, 12'h17, 12'h3E, 12'h95, 12'h19, 12'h1D, 12'h4F, 12'h91, 12'h29, 12'h1B, 12'h3B, 12'h85, 12'h39, 12'h33, 12'h4A, 12'h77 },
        { 12'h4F, 12'h47, 12'h46, 12'h47, 12'h3C, 12'h41, 12'h4C, 12'h50, 12'h42, 12'h41, 12'h50, 12'h58, 12'h48, 12'h46, 12'h55, 12'h5C },
        { 12'h48, 12'h3B, 12'h3D, 12'h5A, 12'h52, 12'h4D, 12'h3E, 12'h3E, 12'h5B, 12'h5C, 12'h54, 12'h43, 12'h69, 12'h6D, 12'h65, 12'h5C },
        { 12'h22, 12'h10, 12'h25, 12'h6A, 12'h2F, 12'h21, 12'h3A, 12'h7F, 12'h40, 12'h39, 12'h47, 12'h71, 12'h49, 12'h40, 12'h41, 12'h5C },
        { 12'hA3, 12'hA8, 12'h8E, 12'h6B, 12'hAD, 12'hB4, 12'h91, 12'h6B, 12'hA0, 12'hAA, 12'h94, 12'h71, 12'h7C, 12'h80, 12'h6D, 12'h5B },
        { 12'h34, 12'h2E, 12'h25, 12'h33, 12'h1F, 12'h17, 12'h17, 12'h3B, 12'h24, 12'h19, 12'h1B, 12'h3E, 12'h2A, 12'h19, 12'h18, 12'h3A },
        { 12'h55, 12'h61, 12'h5B, 12'h57, 12'h65, 12'h70, 12'h6C, 12'h61, 12'h7A, 12'h99, 12'h89, 12'h77, 12'h7E, 12'h8D, 12'h81, 12'h72 },
        { 12'h4C, 12'h43, 12'h49, 12'h54, 12'h4C, 12'h3A, 12'h3D, 12'h49, 12'h55, 12'h4A, 12'h44, 12'h4A, 12'h50, 12'h48, 12'h48, 12'h4A },
        { 12'h62, 12'h65, 12'h65, 12'h5F, 12'h58, 12'h5B, 12'h4F, 12'h5A, 12'h4C, 12'h4A, 12'h4A, 12'h5B, 12'h48, 12'h4B, 12'h4B, 12'h69 },
        { 12'h4B, 12'h4C, 12'h4B, 12'h42, 12'h5F, 12'h5F, 12'h59, 12'h44, 12'h6A, 12'h66, 12'h68, 12'h61, 12'h67, 12'h64, 12'h66, 12'h6A },
        { 12'h39, 12'h47, 12'h61, 12'h6A, 12'h4C, 12'h7A, 12'h99, 12'h9F, 12'h63, 12'h96, 12'hDC, 12'hF0, 12'h78, 12'hC5, 12'hFE, 12'hFE },
        { 12'h883, 12'h00, 12'h80F, 12'h00, 12'h00, 12'h00, 12'h00, 12'h00, 12'h7FD, 12'h00, 12'h820, 12'h00, 12'h00, 12'h00, 12'h00, 12'h00 },
        { 12'h7F7, 12'h00, 12'h843, 12'h00, 12'h00, 12'h00, 12'h00, 12'h00, 12'h848, 12'h00, 12'h84D, 12'h00, 12'h00, 12'h00, 12'h00, 12'h00 },
        { 12'h94, 12'h91, 12'h90, 12'h8B, 12'h90, 12'h91, 12'h92, 12'h8C, 12'h7B, 12'h82, 12'h84, 12'h7E, 12'h7A, 12'h88, 12'h8B, 12'h78 },
        { 12'h83, 12'h7E, 12'h7F, 12'h92, 12'h83, 12'h83, 12'h7D, 12'h86, 12'h7D, 12'h84, 12'h7E, 12'h7A, 12'h7C, 12'h82, 12'h7F, 12'h7E },
        { 12'h81, 12'h8C, 12'h89, 12'h74, 12'h81, 12'h81, 12'h7D, 12'h74, 12'h7A, 12'h83, 12'h88, 12'h7C, 12'h7F, 12'h82, 12'h87, 12'h77 },
        { 12'h75, 12'h7E, 12'h7D, 12'h7F, 12'h79, 12'h80, 12'h81, 12'h87, 12'h7F, 12'h80, 12'h8E, 12'h98, 12'h7B, 12'h7E, 12'h8B, 12'h87 },
        { 12'h7F, 12'h7C, 12'h81, 12'h83, 12'h79, 12'h79, 12'h7A, 12'h7A, 12'h82, 12'h80, 12'h7F, 12'h7F, 12'h87, 12'h87, 12'h82, 12'h82 },
        { 12'h84, 12'h83, 12'h83, 12'h84, 12'h7E, 12'h83, 12'h83, 12'h84, 12'h84, 12'h86, 12'h83, 12'h85, 12'h88, 12'h88, 12'h86, 12'h85 },
        { 12'h85, 12'h89, 12'h84, 12'h81, 12'h83, 12'h84, 12'h84, 12'h85, 12'h86, 12'h86, 12'h86, 12'h83, 12'h82, 12'h88, 12'h85, 12'h81 },
        { 12'h87, 12'h88, 12'h85, 12'h84, 12'h88, 12'h86, 12'h84, 12'h85, 12'h87, 12'h83, 12'h86, 12'h82, 12'h85, 12'h83, 12'h84, 12'h80 }
        };
   
   assign recon_mb_vec = {
        { 8'h2C, 8'h2C, 8'h2C, 8'h2C, 8'h3D, 8'h3D, 8'h3D, 8'h3D, 8'h60, 8'h60, 8'h60, 8'h60, 8'h71, 8'h71, 8'h71, 8'h71 },
        { 8'h2C, 8'h2C, 8'h2C, 8'h2C, 8'h3D, 8'h3D, 8'h3D, 8'h3D, 8'h60, 8'h60, 8'h60, 8'h60, 8'h71, 8'h71, 8'h71, 8'h71 },
        { 8'h55, 8'h4E, 8'h52, 8'h5D, 8'h45, 8'h40, 8'h48, 8'h55, 8'h38, 8'h37, 8'h46, 8'h56, 8'h3B, 8'h3B, 8'h4E, 8'h60 },
        { 8'h67, 8'h65, 8'h60, 8'h5E, 8'h5E, 8'h5A, 8'h52, 8'h4E, 8'h71, 8'h69, 8'h5A, 8'h53, 8'h8C, 8'h83, 8'h70, 8'h67 },
        { 8'h32, 8'h2F, 8'h2A, 8'h27, 8'h38, 8'h35, 8'h2F, 8'h2D, 8'h44, 8'h41, 8'h3B, 8'h38, 8'h49, 8'h46, 8'h41, 8'h3E },
        { 8'h22, 8'h19, 8'h4E, 8'h8D, 8'h26, 8'h1B, 8'h4C, 8'h89, 8'h2D, 8'h1E, 8'h49, 8'h82, 8'h31, 8'h20, 8'h47, 8'h7E },
        { 8'h49, 8'h4C, 8'h51, 8'h54, 8'h49, 8'h4C, 8'h51, 8'h54, 8'h49, 8'h4C, 8'h51, 8'h54, 8'h49, 8'h4C, 8'h51, 8'h54 },
        { 8'h52, 8'h46, 8'h46, 8'h52, 8'h4C, 8'h46, 8'h46, 8'h4C, 8'h51, 8'h57, 8'h57, 8'h51, 8'h5D, 8'h69, 8'h69, 8'h5D },
        { 8'h2B, 8'h13, 8'h31, 8'h67, 8'h3A, 8'h27, 8'h41, 8'h6F, 8'h47, 8'h3B, 8'h4F, 8'h6E, 8'h45, 8'h3D, 8'h4D, 8'h64 },
        { 8'h9A, 8'hA0, 8'h89, 8'h6C, 8'hA6, 8'hAC, 8'h95, 8'h78, 8'h9A, 8'hA1, 8'h8A, 8'h6C, 8'h83, 8'h89, 8'h72, 8'h55 },
        { 8'h2E, 8'h1F, 8'h24, 8'h39, 8'h2E, 8'h1F, 8'h24, 8'h39, 8'h2E, 8'h1F, 8'h24, 8'h39, 8'h2E, 8'h1F, 8'h24, 8'h39 },
        { 8'h58, 8'h61, 8'h61, 8'h58, 8'h6A, 8'h73, 8'h73, 8'h6A, 8'h7B, 8'h84, 8'h84, 8'h7B, 8'h7B, 8'h84, 8'h84, 8'h7B },
        { 8'h4F, 8'h46, 8'h46, 8'h4F, 8'h4F, 8'h46, 8'h46, 8'h4F, 8'h4F, 8'h46, 8'h46, 8'h4F, 8'h4F, 8'h46, 8'h46, 8'h4F },
        { 8'h65, 8'h61, 8'h5A, 8'h56, 8'h5E, 8'h5C, 8'h59, 8'h57, 8'h51, 8'h53, 8'h56, 8'h58, 8'h4B, 8'h4E, 8'h55, 8'h59 },
        { 8'h51, 8'h51, 8'h51, 8'h51, 8'h56, 8'h56, 8'h56, 8'h56, 8'h62, 8'h62, 8'h62, 8'h62, 8'h68, 8'h68, 8'h68, 8'h68 },
        { 8'h3D, 8'h50, 8'h68, 8'h6E, 8'h4C, 8'h6A, 8'h8D, 8'h92, 8'h6A, 8'h9E, 8'hD7, 8'hDC, 8'h79, 8'hB8, 8'hFC, 8'hFF },
        { 8'h8A, 8'h8A, 8'h8A, 8'h8A, 8'h87, 8'h87, 8'h87, 8'h87, 8'h82, 8'h82, 8'h82, 8'h82, 8'h7F, 8'h7F, 8'h7F, 8'h7F },
        { 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80, 8'h80 },
        { 8'h7C, 8'h85, 8'h85, 8'h7C, 8'h7C, 8'h85, 8'h85, 8'h7C, 8'h7C, 8'h85, 8'h85, 8'h7C, 8'h7C, 8'h85, 8'h85, 8'h7C },
        { 8'h7F, 8'h82, 8'h87, 8'h8A, 8'h7F, 8'h82, 8'h87, 8'h8A, 8'h7F, 8'h82, 8'h87, 8'h8A, 8'h7F, 8'h82, 8'h87, 8'h8A },
        { 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82 },
        { 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82 },
        { 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82 },
        { 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82, 8'h82 } 
        };
     
    assign vlc_mb_vec = {
         { 9'd30, 512'b00000111_0000000001_00000101_110_0 , 512'b111111111111111111111111111111 },
         { 9'd28, 512'b000111_0000000001_00000101_110_0 , 512'b1111111111111111111111111111 },
         { 9'd32, 512'b001000_000_1_011_0000000000011_000001 , 512'b11111111111111111111111111111111 },
         { 9'd24, 512'b01000_1_1_011_010_0000011_0101 , 512'b111111111111111111111111 },
         { 9'd43, 512'b0000111_01_10_0000000000000001000000000001_0101 , 512'b1111111111111111111111111111111111111111111 },
         { 9'd36, 512'b00000111_00001_101_000111_0001001_0101_1_00 , 512'b111111111111111111111111111111111111 },
         { 9'd28, 512'b01111_1_0000000000000010101_111 , 512'b1111111111111111111111111111 },
         { 9'd29, 512'b000101_00_01_00000000011_110_001_1_0 , 512'b11111111111111111111111111111 },
         { 9'd37, 512'b001010_0_001_11_11_011_00011_000000101_00001_0 , 512'b1111111111111111111111111111111111111 },
         { 9'd28, 512'b0001011_01_011_010_00010_110_0100_0 , 512'b1111111111111111111111111111 },
         { 9'd42, 512'b001000_1_11_0000000000000001000000000111_101_00 , 512'b111111111111111111111111111111111111111111 },
         { 9'd23, 512'b01011_11_0001_0011_0101_01_1_0 , 512'b11111111111111111111111 },
         { 9'd31, 512'b01111_0_0000000000000010111_011_000 , 512'b1111111111111111111111111111111 },
         { 9'd33, 512'b001001_00_0000000000000010001_110_01_0 , 512'b111111111111111111111111111111111 },
         { 9'd21, 512'b000111_01_000000011_110_0 , 512'b111111111111111111111 },
         { 9'd43, 512'b00000110_0_01_0010_00000000011_000111_1110_111_01_1_0 , 512'b1111111111111111111111111111111111111111111 },
         { 9'd9, 512'b001_00_00_00 , 512'b111111111 },
         { 9'd3, 512'b1_0_1 , 512'b111 },
         { 9'd6, 512'b01_0_011 , 512'b111111 },
         { 9'd1, 512'b1 , 512'b1 },
         { 9'd7, 512'b01_1_0010 , 512'b1111111 },
         { 9'd4, 512'b01_1_1 , 512'b1111 },
         { 9'd1, 512'b1 , 512'b1 },
         { 9'd1, 512'b1 , 512'b1 },
         { 9'd1, 512'b1 , 512'b1 },
         { 9'd1, 512'b1 , 512'b1 }
        };  
       
    initial begin
       orig = 192'h0;
       pred = 192'h0;
       offset = 8'h0;
       deadzone = 16'h00;
       qpy  = 6'd0;
       cidx = 3'd0;
       bidx = 4'd0;
       abv_out_of_pic  = 1'b1;
       left_out_of_pic = 1'b1;

       
       // startup delay (for future reset)
       for( int ii = 0; ii < 10; ii++ ) @(posedge clk); // 10 cycles

       // Step thru a basic (all zero) MB
       cidx = 0; // Luma
       for( int ii = 0; ii < 16; ii++ ) begin
           bidx[3:0] = ii;
           @(posedge clk);
       end 
       bidx = 0;
       cidx = 4; // cr dc
       @(posedge clk);
       cidx = 5; // cb dc
       @(posedge clk);
       cidx = 2; // cr ac
       for( int ii = 0; ii < 4; ii++ ) begin
           bidx[3:0] = ii;
           @(posedge clk);
       end
       cidx = 3; // cb ac
       for( int ii = 0; ii < 4; ii++ ) begin
           bidx[3:0] = ii;
           @(posedge clk);
       end
       for( int ii = 0; ii < 5; ii++ ) @(posedge clk);
       
       // Step thru a real block, for visual debug
       
       orig = { 12'd33 , 12'd36 , 12'd37 , 12'd44 , 
                12'd68 , 12'd65 , 12'd62 , 12'd62 , 
                12'd98 , 12'd92 , 12'd96 , 12'd94 , 
                12'd116, 12'd114, 12'd116, 12'd119};
       pred = {16{12'd128}};
       offset = 8'h0;
       deadzone = 16'h00;
       qpy  = 6'd29;
       cidx = 3'd0;
       bidx = 4'd0;
       abv_out_of_pic  = 1'b1;
       left_out_of_pic = 1'b1;
       @(posedge clk);
       for( int ii = 0; ii < 5; ii++ ) @(posedge clk);
       

       // Step thru 1st full pintra macroblock, with checking 
       pred = {16{12'd128}};
       offset = 8'h0;
       deadzone = 16'h00;
       qpy  = 6'd29;
       cidx = 3'd0;
       bidx = 4'd0;
       abv_out_of_pic  = 1'b1;
       left_out_of_pic = 1'b1;
 
       cidx = 0; // Luma
       for( int ii = 0; ii < 16; ii++ ) begin
           bidx[3:0] = ii;
           orig = orig_mb_vec[ii];
           @(negedge clk);
           if( recon != recon_mb_vec[ii] ) begin
                $write("ERROR: Recon[%d].Y mismatch\n", ii );
           end
           if( irecon != recon_mb_vec[ii] ) begin
                $write("ERROR: iRecon[%d].Y mismatch\n", ii );
           end
           if( { bitcount, bits, mask } != vlc_mb_vec[ii] ) begin
                $write("ERROR: Bitstream[%0d].Y mismatch\n", ii );
                $write("  ref: %0d %0h %0h\n", bitcount, bits, mask );
                $write("  vec: %0d %0h %0h\n", vlc_mb_vec[ii][1032:1024], vlc_mb_vec[ii][1023:512], vlc_mb_vec[ii][511:0] );
           end           
           $write("\ndut Y  recon = { ");
           for( int bb = 0; bb < 16; bb++ ) 
               $write("%0h ", recon[bb] );
           $write(" }\n");
           $write(  "dut Y irecon = { ");
           for( int bb = 0; bb < 16; bb++ ) 
               $write("%0h ", irecon[bb] );
           $write(" }\n");
           $write(  "ref Y  recon = { ");
           for( int bb = 0; bb < 16; bb++ ) 
               $write("%0h ", recon_mb_vec[ii][bb] );
           $write(" }\n");
           @(posedge clk);
       end 
       // chroma dc pred
       pred = {12'h800, 12'h0, 12'h800, 12'h0, 12'h0, 12'h0, 12'h0, 12'h0, 12'h800, 12'h0, 12'h800, 12'h0, 12'h0, 12'h0, 12'h0, 12'h0 };
       bidx = 0;
       cidx = 4; // cr dc
      orig = orig_mb_vec[16];
           @(negedge clk);
           if( { bitcount, bits, mask } != vlc_mb_vec[16] ) begin
                $write("ERROR: Bitstream.DcCb mismatch\n" );
           end           
           @(posedge clk);
       cidx = 5; // cb dc
       orig = orig_mb_vec[17];
           @(negedge clk);
           if( { bitcount, bits, mask } != vlc_mb_vec[17] ) begin
                $write("ERROR: Bitstream.DcCr mismatch\n" );
           end           
           @(posedge clk);
       pred = {16{12'd128}};
       cidx = 2; // cr ac
       for( int ii = 0; ii < 4; ii++ ) begin
           bidx[3:0] = ii;
           orig = orig_mb_vec[18+ii];
           @(negedge clk);
           if( recon != recon_mb_vec[16+ii] ) begin
                $write("ERROR: recon[%d].Cb mismatch\n", ii );
           end
           if( irecon != recon_mb_vec[16+ii] ) begin
                $write("ERROR: irecon[%d].Cb mismatch\n", ii );
           end
           if( { bitcount, bits, mask } != vlc_mb_vec[18+ii] ) begin
                $write("ERROR: Bitstream[%d].Cb mismatch\n", ii );
           end           

           $write("\ndut Cb recon = { ");
           for( int bb = 0; bb < 16; bb++ ) 
               $write("%0h ", recon[bb] );
           $write(" }\n");
           $write(  "dut Cbirecon = { ");
           for( int bb = 0; bb < 16; bb++ ) 
               $write("%0h ", irecon[bb] );
           $write(" }\n");
           $write(  "ref Cb recon = { ");
           for( int bb = 0; bb < 16; bb++ ) 
               $write("%0h ", recon_mb_vec[16+ii][bb] );
           $write(" }\n");
           @(posedge clk);
       end
       cidx = 3; // cb ac
       for( int ii = 0; ii < 4; ii++ ) begin
           bidx[3:0] = ii;
           orig = orig_mb_vec[22+ii];
           @(negedge clk);
           if( recon != recon_mb_vec[20+ii] ) begin
                $write("ERROR: recon[%d].Cr mismatch\n", ii );
           end
           if( irecon != recon_mb_vec[20+ii] ) begin
                $write("ERROR: irecon[%d].Cr mismatch\n", ii );
           end

           if( { bitcount, bits, mask } != vlc_mb_vec[22+ii] ) begin
                $write("ERROR: Bitstream[%d].Cr mismatch\n", ii );
           end           
           $write("\ndut Cr recon = { ");
           for( int bb = 0; bb < 16; bb++ ) 
               $write("%0h ", recon[bb] );
           $write(" }\n");
           $write(  "dut Crirecon = { ");
           for( int bb = 0; bb < 16; bb++ ) 
               $write("%0h ", irecon[bb] );
           $write(" }\n");
           $write( "ref Cr recon = { ");
           for( int bb = 0; bb < 16; bb++ ) 
               $write("%0h ", recon_mb_vec[20+ii][bb] );
           $write(" }\n");
           @(posedge clk);
       end
       for( int ii = 0; ii < 5; ii++ ) @(posedge clk);
    end

endmodule
