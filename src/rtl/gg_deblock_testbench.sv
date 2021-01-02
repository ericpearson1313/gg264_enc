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
        #(200000ns);
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
         
    logic [0:23][0:15][7:0] ref_in, ref_out;
    logic [0:23] ref_nz;
    
    assign ref_nz = 24'b1111_1111_1111_1111_1011_0000;
    
    assign ref_in = {
        128'h2C2C2C2C3D3D3D3D6060606071717171,
        128'h2C2C2C2C3D3D3D3D6060606071717171,
        128'h554E525D45404855383746563B3B4E60,
        128'h6765605E5E5A524E71695A538C837067,
        128'h322F2A2738352F2D44413B384946413E,
        128'h22194E8D261B4C892D1E49823120477E,
        128'h494C5154494C5154494C5154494C5154,
        128'h524646524C46464C515757515D69695D,
        128'h2B1331673A27416F473B4F6E453D4D64,
        128'h9AA0896CA6AC95789AA18A6C83897255,
        128'h2E1F24392E1F24392E1F24392E1F2439,
        128'h586161586A73736A7B84847B7B84847B,
        128'h4F46464F4F46464F4F46464F4F46464F,
        128'h65615A565E5C5957515356584B4E5559,
        128'h51515151565656566262626268686868,
        128'h3D50686E4C6A8D926A9ED7DC79B8FCFF,
        128'h8A8A8A8A87878787828282827F7F7F7F,
        128'h80808080808080808080808080808080,
        128'h7C85857C7C85857C7C85857C7C85857C,
        128'h7F82878A7F82878A7F82878A7F82878A,
        128'h82828282828282828282828282828282,
        128'h82828282828282828282828282828282,
        128'h82828282828282828282828282828282,
        128'h82828282828282828282828282828282
        };
    assign ref_out = {
        128'h2C2C2C2C3D3D3D3D6060606071717171,
        128'h2C2C2D2E3D3D3C3C6060606071717171,
        128'h554E525D45404855383746563B3B4E60,
        128'h6765605D5E5A524D71695A538C837067,
        128'h302F2A2739352F2D44413B384948433E,
        128'h22194E8D261B4C892D1E49823120477E,
        128'h4A4A4F54494B50524A4B50524B4A4E52,
        128'h524646524E47464C535657515D69695D,
        128'h2B1331673A27416F473B4F6E453D4D64,
        128'h9AA0896CA6AC95789AA18A6C83897255,
        128'h2E1F24392E1F24392E1F24392E1F2439,
        128'h586161586A73736A7B84847B7B84847B,
        128'h4D4849514E4747504F4747504F48484F,
        128'h65615A565E5C5957515356584B4E5559,
        128'h514F4F51565656566262626268686868,
        128'h3D50686E4C6A8D926A9ED7DC79B8FCFF,
        128'h8A8A8A8887878785828282817E81817E,
        128'h82808080828080808180808080818282,
        128'h7D83837D7C85857C7C85857C7C85857C,
        128'h7F8185887F82878A7F82878A7F82878A,
        128'h82828282828282828282828282828282,
        128'h82828282828282828282828282828282,
        128'h82828282828282828282828282828282,
        128'h82828282828282828282828282828282
    };
    logic [0:23][7:0] test_idx;
    logic [0:23] test_ale;
    int err;
    
    assign test_ale =  24'b_0__0__0__1__0__0__1__1__0__1__0__1__1__1__1__1__0__0__0__1__0__0__0__1;
    assign test_idx = 192'h00_00_00_00_00_00_01_04_00_02_00_08_03_06_09_0C_00_00_00_10_00_00_00_14;
    int fd;
    string line;
    logic [7:0] command;
    logic [3:0] vmask;
    logic [0:15][7:0] tb_data;
    logic [0:15][7:0] sel_out;
   
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
 
        // Use hard coded data for single macroblock
        err = 0;
        
        qpy = 29;
        refidx = 1;
        mvx = 0;
        mvy = 0;
        mbx = 0;
        mby = 0;
        valid = 1;
        for( int ii = 0; ii < 24; ii++ ) begin
            recon = ref_in[ii];
            num_coeff = ref_nz[ii];
            cidx = ( ii > 19 ) ? 3 : ( ii > 15 ) ? 2 : 0;
            bidx[3:0] = ( ii > 19 ) ? ii - 20 : ( ii > 15 ) ? ii - 16 : ii;
            @(negedge clk);
            if( ale_valid != test_ale[ii] ) begin
                $write("ERROR: ale_valid = %d, test_ale[%d] = %d\n", ale_valid, ii, test_ale[ii] );
                err++;
            end
            if( test_ale[ii] && ale_filt != ref_out[test_idx[ii]] ) begin
                $write("ERROR: ale_filtered mismatch blk[%d]\n", ii );
                $write("ERROR: ale_filt = %0h\n", ale_filt );
                $write("ERROR: ref_filt = %0h\n", ref_out[test_idx[ii]] );
                err++;
            end
            @(posedge clk);
        end 
        
        valid = 0;
        for( int ii = 0; ii < 5; ii++ ) @(posedge clk);
        
        
        fd = $fopen( "C:/Users/ecp/Documents/gg264_enc/src/test/deblock_test2.txt", "r");
        $write("*****************************************************************\n");
        $write("** \n");
        $write("** F I L E       V E C T O R      T E S T\n");
        $write("** \n");
        $write("*****************************************************************\n");
        $write("\n");
        
        valid = 0;
        while( !$feof( fd ) ) begin
            // read stimulus vector from file
            $fgets( line, fd ); // line 1 - params
            $sscanf( line, "%h", command );
            if( command == 0 ) begin // frame info
                $fgets( line, fd ); // line 1 - params
                $sscanf( line, "%h %h %h %h %h", disable_deblock_filter_idc, FilterOffsetA, FilterOffsetB, mb_width, mb_height  );
                
            end else if( command == 1 ) begin // macroblock info
                $fgets( line, fd ); // line 1 - params
                $sscanf( line, "%h %h %h %h %h %h %h", mbx, mby, qpy, mbtype, refidx, mvx, mvy );
                valid = 0;
                for( int ii = 0; ii < 5; ii++ ) @(posedge clk);
                valid = 1;
            end else if( command == 2 ) begin // compare one output
                $fgets( line, fd ); // line 1 - params
                $sscanf( line, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h", vmask, tb_data[0] , tb_data[1] , tb_data[2] , tb_data[3],
                  tb_data[4] , tb_data[5] , tb_data[6] , tb_data[7], tb_data[8] , tb_data[9] , 
                  tb_data[10], tb_data[11], tb_data[12], tb_data[13], tb_data[14], tb_data[15] );
                // check valid flag asserted
                if( vmask == 0 && !ale_valid || vmask == 1 && !abv_valid || vmask == 2 && !lef_valid || vmask == 3 && !cur_valid ) begin
                    $write("ERROR: Mask mismatch mb[%h,%h], cidx %h, bidx %h, mask %h\n", mbx, mby, cidx, bidx, vmask );
                    $write("ERROR: mask idx %h, flags [3:0]= [%d,%d,%d,%d]\n", vmask, cur_valid, lef_valid, abv_valid,  ale_valid );
                    err++;
                end
                // check write data
                sel_out = ( vmask == 0 ) ? ale_filt : 
                          ( vmask == 1 ) ? abv_filt :
                          ( vmask == 2 ) ? lef_filt : cur_filt;
                if( sel_out != tb_data ) begin
                    $write("ERROR: Filtered mismatch mb[%h,%h], cidx %h, bidx %h, mask %h\n", mbx, mby, cidx, bidx, vmask );
                    $write("ERROR: dut_filt = %0h\n", sel_out );
                    $write("ERROR: ref_filt = %0h\n", tb_data );
                    err++;
                end
            end else if( command == 3 ) begin // load stimulus
                $fgets( line, fd ); // line 1 - params
                #(0.1ns);
                 $sscanf( line, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h", cidx, bidx, num_coeff, recon[0] , recon[1] , recon[2] , recon[3],
                  recon[4] , recon[5] , recon[6] , recon[7], recon[8] , recon[9] , recon[10], recon[11], recon[12], recon[13], recon[14], recon[15] );
                @(negedge clk); // advance simulaiton to check stage   
                         
            end else if( command == 4 ) begin // Advance sim to end of cycle
                @(posedge clk);
            end
       end // feof
       valid = 0;
       
        if( err ) begin
            $write("ERROR: test failed with %d errors\n", err );
        end else begin
            $write("PASS: test passed without failures\n" );
        end
   
       
        // Finish
       for( int ii = 0; ii < 5; ii++ ) @(posedge clk);
       $write("GOBBLE: Sim completed\n");
       $fclose( fd );
       $finish;
    end

    

endmodule
