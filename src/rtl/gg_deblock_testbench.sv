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


module gg_deblock_testbench(

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
    
    logic reset;
    initial begin
        reset = 1'b1;
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        reset = 1'b0;
    end
    ///////////////////////
    // End of Time Default
    ///////////////////////
    
    initial begin
        #(20000ns);
        $write("GOBBLE: Sim terminated; hard coded time limit reached.\n");
        $finish;
    end
    
    
    
    //////////////////////
    // Device Under Test
    //////////////////////

    // Frame Inputs
    logic [1:0] disable_deblock_filter_idc; // 1-disable deblocking
    logic [4:0] FilterOffsetA; // -12 to +12
    logic [4:0] FilterOffsetB; // -12 to +12
    // Macroblock positional information
    logic [7:0] mb_width;  // width - 1
    logic [7:0] mb_height; // height - 1
    logic [7:0] mbx; // macroblock horiz position
    logic [7:0] mby; // macroblock horiz position
    // Macroblock level blk info
    logic [5:0] qpy;
    logic [1:0] mbtype; // 0-skip, 1-pcm, 2-inter, 3-intra
    logic [3:0] refidx;
    logic [9:0] mvx; // motion vector mvx -128.00 to 127.75
    logic [9:0] mvy; // -128.00 to 127.75
    // Block info and recon data
    logic       valid;
    logic [2:0] cidx; // cidx={0-luma, 1-acluma, 2-cb, 3-cr, 4-dccb, 5-dccr, 6-dcy}
    logic [3:0] bidx; // block IDX in h264 order
    logic [4:0] num_coeff; // Count of non-zero block coeffs
    logic [0:15][7:0] recon; // input block
    // Filtered output valid flags
    logic ale_valid;
    logic abv_valid;
    logic lef_valid;
    logic cur_valid;
    // filtered output data
    logic [0:15][7:0] ale_filt; // 0 - above left 
    logic [0:15][7:0] abv_filt; // 1 - above
    logic [0:15][7:0] lef_filt; // 2 - left
    logic [0:15][7:0] cur_filt; // 3 - current, Combinatorial output of current block
    

   gg_deblock_process
   #(
        .BIT_LEN  ( 17 ), 
        .WORD_LEN ( 16 )
    ) gg_deblock_dut_
    (
        .clk ( clk ),  
        .reset ( reset ),
        // Frame level deblock controls
        .disable_deblock_filter_idc ( disable_deblock_filter_idc ), // 1-disable deblocking
        .FilterOffsetA              ( FilterOffsetA              ), // -12 to +12
        .FilterOffsetB              ( FilterOffsetB              ), // -12 to +12
        // Macroblock positional information
        .mb_width   ( mb_width  ),  // width - 1
        .mb_height  ( mb_height ), // height - 1
        .mbx        ( mbx       ), // macroblock horiz position
        .mby        ( mby       ), // macroblock horiz position
        // Macroblock level blk info
        .qpy        ( qpy    ),
        .mbtype     ( mbtype ), 
        .refidx     ( refidx ),
        .mvx        ( mvx    ), 
        .mvy        ( mvy    ), 
        // Block info and recon data
        .valid      ( valid     ),
        .cidx       ( cidx      ), 
        .bidx       ( bidx      ), 
        .num_coeff  ( num_coeff ), 
        .recon      ( recon     ), 
        // Filtered output valid flags
        .ale_valid  ( ale_valid ),
        .abv_valid  ( abv_valid ),
        .lef_valid  ( lef_valid ),
        .cur_valid  ( cur_valid ),
        // filtered output data
        .ale_filt   ( ale_filt ), 
        .abv_filt   ( abv_filt ), 
        .lef_filt   ( lef_filt ), 
        .cur_filt   ( cur_filt )  
    );
        
 ///////////////////////////////////////////
 //
 //              TESTs
 //
 ///////////////////////////////////////////        
    
    
         // testbench decl
       
    initial begin
        // frame
        disable_deblock_filter_idc = 0;
        FilterOffsetA              = 0;  
        FilterOffsetB              = 0;  
        // position
        mb_width    = 44;
        mb_height   = 29;
        mbx      = 0;
        mby      = 0;
        // Mb info
        qpy    = 29;
        mbtype = 2;
        refidx = 1;
        mvx    = 0;
        mvy    = 0;
        // Blk Info
        valid = 0;
        cidx = 0;
        bidx = 0;
        num_coeff = 1;
        recon = {16{8'h80}};
             
        // startup delay (for future reset)
        for( int ii = 0; ii < 10; ii++ ) @(posedge clk); // 10 cycles

       // Step thru a basic (all zero) MB
       mb_width = 2;
       mb_height = 2;
       for( int yy = 0; yy < 3; yy++ ) begin
            for( int xx = 0; xx < 3; xx ++ ) begin
                qpy = 29 + xx + 3 * yy;
                refidx = xx + 3* yy;
                mvx = 16 + xx + 3* yy;
                mvy = 32 + xx + 3 * yy;
                mbx = xx;
                mby = yy;
                valid = 1;
                cidx = 0; // Luma
                for( int ii = 0; ii < 16; ii++ ) begin
                    for( int jj = 0; jj < 16; jj++ )
                        recon[jj] = ii + 32* (xx + 3* yy);
                    bidx[3:0] = ii;
                    @(posedge clk);
                end 
                cidx = 2; // cr ac
                for( int ii = 0; ii < 4; ii++ ) begin
                    for( int jj = 0; jj < 16; jj++ )
                        recon[jj] = ii + 16 + 32* (xx + 3* yy);
                    bidx[3:0] = ii;
                    @(posedge clk);
                end
                cidx = 3; // cb ac
                for( int ii = 0; ii < 4; ii++ ) begin
                    for( int jj = 0; jj < 16; jj++ )
                        recon[jj] = ii + 20 + 32* (xx + 3* yy);
                    bidx[3:0] = ii;
                    @(posedge clk);
                end
                valid = 0;
                for( int ii = 0; ii < 5; ii++ ) @(posedge clk);
            end
        end
 
       
       valid = 0;

        // End Delay
       for( int ii = 0; ii < 5; ii++ ) @(posedge clk);
       $finish;
    end

    

endmodule
