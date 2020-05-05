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
     logic [0:2][15:0][15:0] dc_hold;
     logic [0:2][15:0][15:0] dc_hold_dout;
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
    
    
 ///////////////////////////////////////////
 //
 //              TESTs
 //
 ///////////////////////////////////////////        
    
    logic [0:25][0:15][11:0] orig_mb_vec; // Very first test macroblock
   
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
   
    initial begin
    #1;
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
       #100; // 10 cycles

       // Step thru a basic (all zero) MB
       cidx = 0; // Luma
       for( int ii = 0; ii < 16; ii++ ) begin
           bidx[3:0] = ii;
           #10;
       end 
       bidx = 0;
       cidx = 4; // cr dc
       #10;
       cidx = 5; // cb dc
       #10;
       cidx = 2; // cr ac
       for( int ii = 0; ii < 4; ii++ ) begin
           bidx[3:0] = ii;
           #10;
       end
       cidx = 3; // cb ac
       for( int ii = 0; ii < 4; ii++ ) begin
           bidx[3:0] = ii;
           #10;
       end
       #50;
       
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
        #10;
        #50;
       

       // Step thru 1st full pintra macroblock, visual debug
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
           #10;
       end 
       bidx = 0;
       cidx = 4; // cr dc
       orig = orig_mb_vec[16];
       #10;
       cidx = 5; // cb dc
       orig = orig_mb_vec[17];
       #10;
       cidx = 2; // cr ac
       for( int ii = 0; ii < 4; ii++ ) begin
           bidx[3:0] = ii;
           orig = orig_mb_vec[18+ii];
           #10;
       end
       cidx = 3; // cb ac
       for( int ii = 0; ii < 4; ii++ ) begin
           bidx[3:0] = ii;
           orig = orig_mb_vec[22+ii];
           #10;
       end
       #50;
               
       
       
       
    end

endmodule
