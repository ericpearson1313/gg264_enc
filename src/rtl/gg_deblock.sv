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

// Deblock process for a transform block
// combinatorial output of current filtered block along with left, above and above left, all 4 with valid strobes
// Includes all internal memories and state to process a frame of 4x4 blocks in decode order
// valid signals present output blocks (up to four simultaneously) as they are completed.

module gg_deblock_process
   #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
    )
    (
    // System controls
    input  logic clk,   
    input  logic reset, // Sync reset
    
    // Frame level deblock controls
    input  logic [1:0] disable_deblock_filter_idc, // 1-disable deblocking
    input  logic [4:0] FilterOffsetA, // -12 to +12
    input  logic [4:0] FilterOffsetB, // -12 to +12
    
    // Macroblock positional information
    input  logic [7:0] mb_width,  // width - 1
    input  logic [7:0] mb_height, // height - 1
    input  logic [7:0] mbx, // macroblock horiz position
    input  logic [7:0] mby, // macroblock horiz position
    
    // Macroblock level blk info
    input  logic [5:0] qpy,
    input  logic [1:0] mbtype, // 0-skip, 1-pcm, 2-inter, 3-intra
    input  logic [3:0] refidx,
    input  logic [9:0] mvx, // motion vector mvx -128.00 to 127.75
    input  logic [9:0] mvy, // -128.00 to 127.75

    // Block info and recon data
    input  logic       valid,  // indicates valid input blk
    input  logic [2:0] cidx, // cidx={0-luma, 1-acluma, 2-cb, 3-cr, 4-dccb, 5-dccr, 6-dcy}
    input  logic [3:0] bidx, // block IDX in h264 order
    input  logic [4:0] num_coeff, // Count of non-zero block coeffs
    input  logic [0:15][7:0] recon, // input block
    
    // Filtered output valid flags
    output logic ale_valid,
    output logic abv_valid,
    output logic lef_valid,
    output logic cur_valid,
    
    // filtered output data
    output logic [0:15][7:0] ale_filt, // 0 - above left 
    output logic [0:15][7:0] abv_filt, // 1 - above
    output logic [0:15][7:0] lef_filt, // 2 - left
    output logic [0:15][7:0] cur_filt  // 3 - current, Combinatorial output of current block
    );
    
    // Flags
    logic dc_flag;
	logic ac_flag;
	logic ch_flag;
	logic cb_flag;
	logic cr_flag;
	logic y_flag ;

	assign dc_flag = ( cidx[2:0] == 4 || cidx[2:0] == 5 || cidx[2:0] == 6) ? 1'b1 : 1'b0;
	assign ac_flag = ( cidx[2:0] == 1 || cidx[2:0] == 2 || cidx[2:0] == 3) ? 1'b1 : 1'b0;
	assign ch_flag = ( cidx[2:0] == 2 || cidx[2:0] == 3 || cidx[2:0] == 4 || cidx[2:0] == 5) ? 1'b1 : 1'b0;    
	assign cb_flag = ( cidx[2:0] == 2 || cidx[2:0] == 4 ) ? 1'b1 : 1'b0;
	assign cr_flag = ( cidx[2:0] == 3 || cidx[2:0] == 5 ) ? 1'b1 : 1'b0;
	assign y_flag  = ( cidx[2:0] == 0 || cidx[2:0] == 1 || cidx[2:0] == 6 ) ? 1'b1 : 1'b0;

    logic [1:0] blkx;
    logic [1:0] blky;
    logic last_blk  ;

    assign blkx      = { bidx[2], bidx[0] };
    assign blky      = { bidx[3], bidx[1] };
    assign last_blk  = ( cidx[2:0] == 3 && bidx[1:0] == 3 ) ? valid : 1'b0;

    logic [0:15][7:0] cur_recon, lef_recon, abv_recon, ale_recon;
    
    // Positional strobes   
    logic ntop;
    logic nlef;
    logic rpic;
    logic bpic;
    logic nlbp;
    logic brcn;
    logic alwy;

    assign ntop = ( mby != 0 ) ? valid : 1'b0; // not top pic mb row                                        
    assign nlef = ( mbx != 0 ) ? valid : 1'b0;  // not left pic mb col                                      
    assign rpic = ( mbx == mb_width ) ? valid : 1'b0; // right picture edge                             
    assign bpic = ( mby == mb_height ) ? valid : 1'b0; // Bottom picture edge                           
    assign nlbp = ( mby == mb_height && mbx != 0 ) ? valid : 1'b0;  // Bottom pic edge, but not left corner 
    assign brcn = ( mbx == mb_width && mby == mb_height ) ? valid : 1'b0;  // bottom right corner       
    assign alwy = valid;                                                                                

    // current blk context
    logic [5:0] lef_qpz   , ale_qpz   , abv_qpz   , cur_qpz;
    logic [1:0] lef_mbtype, ale_mbtype, abv_mbtype, cur_mbtype; 
    logic [3:0] lef_refidx, ale_refidx, abv_refidx, cur_refidx; 
    logic [9:0] lef_mvx   , ale_mvx   , abv_mvx   , cur_mvx   ; 
    logic [9:0] lef_mvy   , ale_mvy   , abv_mvy   , cur_mvy   ; 
    logic       lef_nz    , ale_nz    , abv_nz    , cur_nz    ;
    
    // Calc cur blk info from input
    assign cur_qpz = ( mbtype == 1 ) ? 6'd0 : qpy;
    assign cur_mbtype = mbtype;
    assign cur_refidx = refidx;
    assign cur_mvx = mvx;
    assign cur_mvy = mvy;
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Above 4x4 block ram (16KByte)
    // Contains the partially filtered results from the previous macroblock row
    // Size: 128 macroblocks wide, with 8 blocks, each with a 4x4 array of 8 bit pels, plus a nz bit.
    // 2 Banks of 512 words of 128+1 bit, totalling 16 Kbytes.
    // Future: Can use 1r1w sync read memories, with pre-increment on the address
    //////////////////////////////////////////////////////////////////////////////////////////////////
 
    // Outputs from above ram
    logic [0:15][7:0] above_ale_blk, above_abv_blk;
    logic             above_ale_nz , above_abv_nz ;
    
    // above ram interface (read and write to same addr)
    logic         abvblk_mem_we[2];
    logic [8:0]   abvblk_mem_addr[2];
    logic [128:0] abvblk_mem_din[2];
    logic [128:0] abvblk_mem_dout[2];
    
    logic above_ale_we, above_abv_we;

    genvar ii;    
    generate
        for( ii = 0; ii < 2; ii++ ) begin
            db_sram_1r1w_async #( 512, 9, 129 ) _above_blk_ram
            (
                 .clk      ( clk ),
                 .we       ( abvblk_mem_we[ii]   ),
                 .raddr    ( abvblk_mem_addr[ii] ),
                 .waddr    ( abvblk_mem_addr[ii] ),
                 .din      ( abvblk_mem_din[ii]  ),
                 .dout     ( abvblk_mem_dout[ii] )
             );
        end
    endgenerate
    
    always_comb begin : _abv_blk_ram_control
        // write along top MB edge if not top mb row (ntop)
        above_abv_we = ( cidx == 0 && bidx == 15 ||
                         cidx == 2 && bidx == 3  ||
                         cidx == 3 && bidx == 3  ) ? rpic : 1'b0;
        above_ale_we = ( cidx == 0 && bidx == 10 ) ? nlef :
                       ( cidx == 0 && bidx == 11 ) ? alwy :
                       ( cidx == 0 && bidx == 14 ) ? alwy :
                       ( cidx == 0 && bidx == 15 ) ? alwy :
                       ( cidx == 2 && bidx == 2  ) ? nlef : 
                       ( cidx == 2 && bidx == 3  ) ? alwy : 
                       ( cidx == 3 && bidx == 2  ) ? nlef : 
                       ( cidx == 3 && bidx == 3  ) ? alwy : 1'b0;
        // generate addresses and mux data port 
        if( y_flag ) begin // luma
            if( blkx == 1 || blkx == 3 ) begin
                abvblk_mem_addr[0] = { mbx[5:0], 1'b0, blkx[1] };
                abvblk_mem_addr[1] = { mbx[5:0], 1'b0, blkx[1] };
                { above_ale_nz, above_ale_blk } = abvblk_mem_dout[0];
                { above_abv_nz, above_abv_blk } = abvblk_mem_dout[1];
                abvblk_mem_din[0] = { lef_nz, lef_filt };
                abvblk_mem_din[1] = { cur_nz, cur_filt };
                abvblk_mem_we[0] = above_ale_we;
                abvblk_mem_we[1] = above_abv_we;
            end 
            else if ( blkx[1:0] == 2 ) begin
                abvblk_mem_addr[0] = { mbx[5:0], 2'b01 };
                abvblk_mem_addr[1] = { mbx[5:0], 2'b00 };
                { above_ale_nz, above_ale_blk } = abvblk_mem_dout[1];
                { above_abv_nz, above_abv_blk } = abvblk_mem_dout[0];
                abvblk_mem_din[1] = { lef_nz, lef_filt };
                abvblk_mem_din[0] = { cur_nz, cur_filt };
                abvblk_mem_we[1] = above_ale_we;
                abvblk_mem_we[0] = above_abv_we;
            end 
            else begin // blkx == 0
                abvblk_mem_addr[0] = { mbx[5:0]    , 2'b00 };
                abvblk_mem_addr[1] = { mbx[5:0] - 1, 2'b01 };
                { above_ale_nz, above_ale_blk } = abvblk_mem_dout[1];
                { above_abv_nz, above_abv_blk } = abvblk_mem_dout[0];
                abvblk_mem_din[1] = { lef_nz, lef_filt };
                abvblk_mem_din[0] = { cur_nz, cur_filt };
                abvblk_mem_we[1] = above_ale_we;
                abvblk_mem_we[0] = above_abv_we;
            end
        end
        else if( ch_flag ) begin // chroma
            if( blkx == 1 ) begin
                abvblk_mem_addr[0] = { mbx[5:0], 1'b1, cr_flag };
                abvblk_mem_addr[1] = { mbx[5:0], 1'b1, cr_flag };
                { above_ale_nz, above_ale_blk } = abvblk_mem_dout[0];
                { above_abv_nz, above_abv_blk } = abvblk_mem_dout[1];
                abvblk_mem_din[0] = { lef_nz, lef_filt };
                abvblk_mem_din[1] = { cur_nz, cur_filt };
                abvblk_mem_we[0] = above_ale_we;
                abvblk_mem_we[1] = above_abv_we;
            end else begin // blkx = 0;
                abvblk_mem_addr[0] = { mbx[5:0]     , 1'b1 ,cr_flag };
                abvblk_mem_addr[1] = { mbx[5:0] - 1 , 1'b1 ,cr_flag };
                { above_ale_nz, above_ale_blk } = abvblk_mem_dout[1];
                { above_abv_nz, above_abv_blk } = abvblk_mem_dout[0];
                abvblk_mem_din[1] = { lef_nz, lef_filt };
                abvblk_mem_din[0] = { cur_nz, cur_filt };
                abvblk_mem_we[1] = above_ale_we;
                abvblk_mem_we[0] = above_abv_we;
            end
        end
    end
 
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Above MB INFO RAM (512Byte)
    // Contains the macroblock info for the above macroblocks
    // { [5:0] qpy, [1:0] mbtype, [3:0] refidx, [9:0] mvx, [9:0] mvy } = 32 bits
    // Size: 128 macroblocks, each with 32 bits of storage
    // 2 banks of 64 words of 32  bits, total of 512 Bytes
    //////////////////////////////////////////////////////////////////////////////////////////////////
    
    // output: current neighbourhood mb info 
    logic [5:0] lef_mb_qpz   , ale_mb_qpz   , abv_mb_qpz   ;
    logic [1:0] lef_mb_mbtype, ale_mb_mbtype, abv_mb_mbtype; 
    logic [3:0] lef_mb_refidx, ale_mb_refidx, abv_mb_refidx; 
    logic [9:0] lef_mb_mvx   , ale_mb_mvx   , abv_mb_mvx   ; 
    logic [9:0] lef_mb_mvy   , ale_mb_mvy   , abv_mb_mvy   ; 
    
    // memory interface
    logic        abvmb_mem_we;
    logic [6:0]  abvmb_mem_addr;
    logic [31:0] abvmb_mem_din;
    logic [31:0] abvmb_mem_dout;

    db_sram_1r1w_async #( 128, 7, 32 ) _above_mb_ram
    (
         .clk      ( clk ),
         .we       ( abvmb_mem_we    ),
         .raddr    ( abvmb_mem_addr ),
         .waddr    ( abvmb_mem_addr ),
         .din      ( abvmb_mem_din   ),
         .dout     ( abvmb_mem_dout  )
     );

    // Hold the left, prev macroblock info, update at end of last block
    // { [5:0] qpy, [1:0] mbtype, [3:0] refidx, [9:0] mvx, [9:0] mvy } = 32 bits
    always_ff @(posedge clk) begin : _lef_mb_info_regs
        if( last_blk ) begin
            // left <- cur
            lef_mb_qpz      <= cur_qpz;
            lef_mb_mbtype   <= cur_mbtype;
            lef_mb_refidx   <= cur_refidx;
            lef_mb_mvx      <= cur_mvx;
            lef_mb_mvy      <= cur_mvy;     
            // ale <- abv   
            ale_mb_qpz      <= abv_mb_qpz;
            ale_mb_mbtype   <= abv_mb_mbtype;
            ale_mb_refidx   <= abv_mb_refidx;
            ale_mb_mvx      <= abv_mb_mvx;
            ale_mb_mvy      <= abv_mb_mvy;      
        end
    end

    // Wire the current MB info to above at end of last block
    always_comb begin : _abv_mb_ram
        // write: cur MB data to above at last block
        abvmb_mem_we  = last_blk;
        abvmb_mem_din = { cur_qpz[5:0], cur_mbtype[1:0], cur_refidx[3:0], cur_mvx[9:0], cur_mvy[9:0] };
        abvmb_mem_addr = mbx[6:0];
        { abv_mb_qpz, abv_mb_mbtype, abv_mb_refidx, abv_mb_mvx, abv_mb_mvy } =  abvmb_mem_dout;

    end
    
    // combine lef and above MB and select current block neighbour info.
    always_comb begin : _blk_mb_info
        // left
        lef_qpz    = ( blkx == 0 ) ? lef_mb_qpz    : cur_qpz;
        lef_mbtype = ( blkx == 0 ) ? lef_mb_mbtype : cur_mbtype;  
        lef_refidx = ( blkx == 0 ) ? lef_mb_refidx : cur_refidx;
        lef_mvx    = ( blkx == 0 ) ? lef_mb_mvx    : cur_mvx;
        lef_mvy    = ( blkx == 0 ) ? lef_mb_mvy    : cur_mvy;
        // abv
        abv_qpz    = ( blky == 0 ) ? abv_mb_qpz    : cur_qpz;
        abv_mbtype = ( blky == 0 ) ? abv_mb_mbtype : cur_mbtype;  
        abv_refidx = ( blky == 0 ) ? abv_mb_refidx : cur_refidx;
        abv_mvx    = ( blky == 0 ) ? abv_mb_mvx    : cur_mvx;
        abv_mvy    = ( blky == 0 ) ? abv_mb_mvy    : cur_mvy;
        // ale
        ale_qpz    = ( blkx == 0 && blky == 0 ) ? ale_mb_qpz    : ( blkx == 0 ) ? lef_mb_qpz    : ( blky == 0 ) ? abv_mb_qpz    : cur_qpz;
        ale_mbtype = ( blkx == 0 && blky == 0 ) ? ale_mb_mbtype : ( blkx == 0 ) ? lef_mb_mbtype : ( blky == 0 ) ? abv_mb_mbtype : cur_mbtype;  
        ale_refidx = ( blkx == 0 && blky == 0 ) ? ale_mb_refidx : ( blkx == 0 ) ? lef_mb_refidx : ( blky == 0 ) ? abv_mb_refidx : cur_refidx;
        ale_mvx    = ( blkx == 0 && blky == 0 ) ? ale_mb_mvx    : ( blkx == 0 ) ? lef_mb_mvx    : ( blky == 0 ) ? abv_mb_mvx    : cur_mvx;
        ale_mvy    = ( blkx == 0 && blky == 0 ) ? ale_mb_mvy    : ( blkx == 0 ) ? lef_mb_mvy    : ( blky == 0 ) ? abv_mb_mvy    : cur_mvy;
     end
    
    //////////////////////////////////////////////////////////////////////////////////////////////////    
    // prev 4x4 block ram (1Kbyte)
    // Holds the previous 4x4 blocks, to allow access to an arbitrary 2 by 2 block array
    // Size: 48 blocks, each with a 4x4 array of 8 bit pels, plus a nz bit.
    // 4 banks of 12 words of 128+1 bits. Async Read, Simultaneous RW, with read getting new write data.
    //////////////////////////////////////////////////////////////////////////////////////////////////
    
    logic         prevblk_mem_we[4];
    logic [3:0]   prevblk_mem_addr[4];
    logic [128:0] prevblk_mem_din[4];
    logic [128:0] prevblk_mem_dout[4];
    
    generate
        for( ii = 0; ii < 4; ii++ ) begin
            db_sram_1r1w_async #( 16, 4, 129 ) _prev_blk_ram
            (
                 .clk      ( clk ),
                 .we       ( prevblk_mem_we[ii]   ),
                 .raddr    ( prevblk_mem_addr[ii] ),
                 .waddr    ( prevblk_mem_addr[ii] ),
                 .din      ( prevblk_mem_din[ii]  ),
                 .dout     ( prevblk_mem_dout[ii] )
             );
        end
    endgenerate
    
    
    // Toggle - toggle the pmem bank for each macroblock
    reg toggle;
    always_ff @(posedge clk) begin 
        if( reset ) begin
            toggle <= 0;
        end else begin
            toggle <= last_blk ^ toggle;
        end
    end

    logic [128:0] pm0, pm1, pm2, pm3;
    always_comb begin : _pmem_input_mux
        pm0 = ( bidx[0] ) ? { lef_nz, lef_filt } : { cur_nz, cur_filt };
        pm1 = ( bidx[0] ) ? { cur_nz, cur_filt } : { lef_nz, lef_filt };
        pm2 = ( bidx[0] ) ? { ale_nz, ale_filt } : { abv_nz, abv_filt };
        pm3 = ( bidx[0] ) ? { abv_nz, abv_filt } : { ale_nz, ale_filt };
        prevblk_mem_din[0] = ( bidx[1] ) ? pm2 : pm0;
        prevblk_mem_din[1] = ( bidx[1] ) ? pm3 : pm1;
        prevblk_mem_din[2] = ( bidx[1] ) ? pm0 : pm2;
        prevblk_mem_din[3] = ( bidx[1] ) ? pm1 : pm3;
    end

    // filter input muxing
    logic [128:0] fm0, fm1, fm2, fm3;
    always_comb begin : _filter_input_mux
        fm0 = ( bidx[0] ) ? prevblk_mem_dout[2] : prevblk_mem_dout[3];
        fm1 = ( bidx[0] ) ? prevblk_mem_dout[3] : prevblk_mem_dout[2];
        fm2 = ( bidx[0] ) ? prevblk_mem_dout[0] : prevblk_mem_dout[1];
        fm3 = ( bidx[0] ) ? prevblk_mem_dout[1] : prevblk_mem_dout[0];
        { ale_nz, ale_recon } = ( blky == 0 ) ? { above_ale_nz, above_ale_blk } : ( bidx[1] ) ? fm2 : fm0;
        { abv_nz, abv_recon } = ( blky == 0 ) ? { above_abv_nz, above_abv_blk } : ( bidx[1] ) ? fm3 : fm1;
        { lef_nz, lef_recon } = ( bidx[1] ) ? fm0 : fm2;
        { cur_nz, cur_recon } = { ( num_coeff != 0 ) ? 1'b1 : 1'b0, recon }; // directly from input
    end

    // Addr - pmem addressing - lookup table
    logic [0:23][0:3][3:0] amux = { 
        64'h09FF_00FF_0909_0000,
        64'h10FF_11FF_1010_1111,
        64'h2B09_2200_2B2B_2222,
        64'h3210_3311_3232_3333,
        64'h4CFF_44FF_4C4C_4444,
        64'h5DFF_55FF_5D5D_5555 };
    logic [4:0] bptr; // 0 to 23
    always_comb begin : _pmem_addressing
            bptr = ( cb_flag ) ? { 3'b100, bidx[1:0] } : ( cr_flag ) ? { 3'b101, bidx[1:0] } : { 1'b0, bidx[3:0] };
            prevblk_mem_addr[0] = { toggle ^ amux[bptr][0][3], amux[bptr][0][2:0] };
            prevblk_mem_addr[1] = { toggle ^ amux[bptr][1][3], amux[bptr][1][2:0] };
            prevblk_mem_addr[2] = { toggle ^ amux[bptr][2][3], amux[bptr][2][2:0] };
            prevblk_mem_addr[3] = { toggle ^ amux[bptr][3][3], amux[bptr][3][2:0] };
            // prev mem write enable, always write except at boundary
            prevblk_mem_we[0] = ( amux[bptr][0] != 4'd15 ) ? alwy : 1'b0; //nlef;
            prevblk_mem_we[1] = ( amux[bptr][1] != 4'd15 ) ? alwy : 1'b0; //nlef | ntop;
            prevblk_mem_we[2] = ( amux[bptr][2] != 4'd15 ) ? alwy : 1'b0; //ntop;
            prevblk_mem_we[3] = ( amux[bptr][3] != 4'd15 ) ? alwy : 1'b0;

    end
    
    //////////////////////////////////////////////////////////////////////////////////////////////////    
    // Block Strenght
    // Calculate for 3 edges: 0-cur/lef, 1-lef/ale, 2-cur/abv
    // However postitional information determines whether to force bS = 0
    //////////////////////////////////////////////////////////////////////////////////////////////////
  
   // calculate the three bs values
   logic [2:0] bs_cur_abv, bs_lef_ale, bs_cur_lef;

   deblock_bs_calc _bs0_calc (
        .mb_edge   ( blkx == 0  ),
        .p_nz      ( lef_nz     ), .q_nz      ( cur_nz     ),              
        .p_mbtype  ( lef_mbtype ), .q_mbtype  ( cur_mbtype ),              
        .p_refidx  ( lef_refidx ), .q_refidx  ( cur_refidx ),              
        .p_mvx     ( lef_mvx    ), .q_mvx     ( cur_mvx    ),              
        .p_mvy     ( lef_mvy    ), .q_mvy     ( cur_mvy    ),                      
        .bs        ( bs_cur_lef )
   );

   deblock_bs_calc _bs1_calc (
        .mb_edge   ( blky == 0  ),
        .p_nz      ( ale_nz     ), .q_nz      ( lef_nz     ),              
        .p_mbtype  ( ale_mbtype ), .q_mbtype  ( lef_mbtype ),              
        .p_refidx  ( ale_refidx ), .q_refidx  ( lef_refidx ),              
        .p_mvx     ( ale_mvx    ), .q_mvx     ( lef_mvx    ),              
        .p_mvy     ( ale_mvy    ), .q_mvy     ( lef_mvy    ),                      
        .bs        ( bs_lef_ale )
   );

   deblock_bs_calc _bs2_calc (
        .mb_edge   ( blky == 0  ),
        .p_nz      ( abv_nz     ), .q_nz      ( cur_nz     ),              
        .p_mbtype  ( abv_mbtype ), .q_mbtype  ( cur_mbtype ),              
        .p_refidx  ( abv_refidx ), .q_refidx  ( cur_refidx ),              
        .p_mvx     ( abv_mvx    ), .q_mvx     ( cur_mvx    ),              
        .p_mvy     ( abv_mvy    ), .q_mvy     ( cur_mvy    ),                      
        .bs        ( bs_cur_abv )
   );
 
     // save cur-lef, cur-abv bs for later re-use during chroma filtering
    reg [0:15][2:0] bsl, bsa;
    always_ff @(posedge clk) begin : _bS_regs
        if( reset ) begin
            bsl <= 0;
            bsa <= 0;
        end else begin
            for( int jj = 0; jj < 16; jj++ ) begin
                if( cidx == 0 && bidx == jj ) begin // save each luma bs
                    bsl[jj] <= bs_cur_lef;
                    bsa[jj] <= bs_cur_abv;
                end
            end
        end    
    end
        
    // Bs select and gate
    // based on position and asap edge filtering and picture boundary
    // gate (using bs=0) the raw bS values, and for chroma select regs (2ea) to be used 
    
    logic [0:1][2:0] bs0, bs1, bs2;
    always_comb begin : _bs_edge_control
        // default to not filter
        bs0 = 0;
        bs1 = 0;
        bs2 = 0;
        // calculate output block valids based on cidx, bidx    
        if( disable_deblock_filter_idc != 2'd1 ) begin
            unique case( { cidx, bidx } ) 
            { 3'd0, 4'h0 } : begin bs0 = (nlef)?{2{bs_cur_lef}}:6'd0; end
            { 3'd0, 4'h1 } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (ntop)?{2{bs_lef_ale}}:6'd0; end
            { 3'd0, 4'h2 } : begin bs0 = (nlef)?{2{bs_cur_lef}}:6'd0; end
            { 3'd0, 4'h3 } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (alwy)?{2{bs_lef_ale}}:6'd0; end    
                 
            { 3'd0, 4'h4 } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (ntop)?{2{bs_lef_ale}}:6'd0; end
            { 3'd0, 4'h5 } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (ntop)?{2{bs_lef_ale}}:6'd0; bs2 = (ntop)?{2{bs_cur_abv}}:6'd0; end
            { 3'd0, 4'h6 } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (alwy)?{2{bs_lef_ale}}:6'd0; end
            { 3'd0, 4'h7 } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (alwy)?{2{bs_lef_ale}}:6'd0; bs2 = (alwy)?{2{bs_cur_abv}}:6'd0; end
            
            { 3'd0, 4'h8 } : begin bs0 = (nlef)?{2{bs_cur_lef}}:6'd0; end
            { 3'd0, 4'h9 } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (alwy)?{2{bs_lef_ale}}:6'd0; end
            { 3'd0, 4'hA } : begin bs0 = (nlef)?{2{bs_cur_lef}}:6'd0; end
            { 3'd0, 4'hB } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (alwy)?{2{bs_lef_ale}}:6'd0; end
            
            { 3'd0, 4'hC } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (alwy)?{2{bs_lef_ale}}:6'd0; end
            { 3'd0, 4'hD } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (alwy)?{2{bs_lef_ale}}:6'd0; bs2 = (alwy)?{2{bs_cur_abv}}:6'd0; end
            { 3'd0, 4'hE } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (alwy)?{2{bs_lef_ale}}:6'd0; end
            { 3'd0, 4'hF } : begin bs0 = (alwy)?{2{bs_cur_lef}}:6'd0; bs1 = (alwy)?{2{bs_lef_ale}}:6'd0; bs2 = (alwy)?{2{bs_cur_abv}}:6'd0; end
            
            { 3'd2, 4'h0 } : begin bs0 = (nlef)?{bsl[0], bsl[2]} :6'd0; end
            { 3'd2, 4'h1 } : begin bs0 = (alwy)?{bsl[4], bsl[6]} :6'd0; bs1 = (ntop)?{bsa[0],bsa[1]}:6'd0; bs2 = (ntop)?{bsa[4],bsa[5]}:6'd0; end
            { 3'd2, 4'h2 } : begin bs0 = (nlef)?{bsl[8], bsl[10]}:6'd0; end
            { 3'd2, 4'h3 } : begin bs0 = (alwy)?{bsl[12],bsl[14]}:6'd0; bs1 = (alwy)?{bsa[8],bsa[9]}:6'd0; bs2 = (alwy)?{bsa[12],bsa[13]}:6'd0; end
            
            { 3'd3, 4'h0 } : begin bs0 = (nlef)?{bsl[0], bsl[2]} :6'd0; end
            { 3'd3, 4'h1 } : begin bs0 = (alwy)?{bsl[4], bsl[6]} :6'd0; bs1 = (ntop)?{bsa[0],bsa[1]}:6'd0; bs2 = (ntop)?{bsa[4],bsa[5]}:6'd0; end
            { 3'd3, 4'h2 } : begin bs0 = (nlef)?{bsl[8], bsl[10]}:6'd0; end
            { 3'd3, 4'h3 } : begin bs0 = (alwy)?{bsl[12],bsl[14]}:6'd0; bs1 = (alwy)?{bsa[8],bsa[9]}:6'd0; bs2 = (alwy)?{bsa[12],bsa[13]}:6'd0; end
            endcase
        end
    end

    // Quad blk filter
    gg_deblock_filter _core_filter
    (
        .clk        ( clk      ), // not used, combinatorial block
        .blki       ( { ale_recon, abv_recon, lef_recon, cur_recon } ), // operate with current block as input
        .ch_flag    ( ch_flag  ),
        .blko       ( { ale_filt, abv_filt, lef_filt, cur_filt } ),
        .qpz        ( { ale_qpz, abv_qpz, lef_qpz, cur_qpz } ),
        .bs         ( { { bs0[0], bs0[1] } , { bs1[0], bs1[1] }, { bs2[0], bs2[1] } } ),
        .FilterOffsetA ( FilterOffsetA ),
        .FilterOffsetB ( FilterOffsetB )
    );     

    
    always_comb begin : _deblock_valids
        // default
        ale_valid = 0;
        lef_valid = 0;
        abv_valid = 0;
        cur_valid = 0;
        // calculate output block valids based on cidx, bidx    
        if( disable_deblock_filter_idc == 2'd1 ) begin
            cur_valid = alwy;
        end else begin
            unique case( { cidx, bidx } ) 
            { 3'd0, 4'h0 } : begin lef_valid = nlef; end
            { 3'd0, 4'h1 } : begin ale_valid = ntop; end
            { 3'd0, 4'h2 } : begin lef_valid = nlef; end
            { 3'd0, 4'h3 } : begin ale_valid = alwy; end
            
            { 3'd0, 4'h4 } : begin ale_valid = ntop; end
            { 3'd0, 4'h5 } : begin ale_valid = ntop; abv_valid = ntop; end
            { 3'd0, 4'h6 } : begin ale_valid = alwy; end
            { 3'd0, 4'h7 } : begin ale_valid = alwy; abv_valid = rpic; end

            { 3'd0, 4'h8 } : begin lef_valid = nlef; end
            { 3'd0, 4'h9 } : begin ale_valid = alwy; end
            { 3'd0, 4'hA } : begin lef_valid = nlbp; end
            { 3'd0, 4'hB } : begin ale_valid = alwy; lef_valid = bpic; end

            { 3'd0, 4'hC } : begin ale_valid = alwy; end
            { 3'd0, 4'hD } : begin ale_valid = alwy; abv_valid = rpic; end
            { 3'd0, 4'hE } : begin ale_valid = alwy; lef_valid = bpic; end
            { 3'd0, 4'hF } : begin ale_valid = alwy; abv_valid = rpic; lef_valid = bpic; cur_valid = brcn; end
            
            { 3'd2, 4'h0 } : begin lef_valid = nlef; end
            { 3'd2, 4'h1 } : begin ale_valid = ntop; abv_valid = ntop; end
            { 3'd2, 4'h2 } : begin lef_valid = nlbp; end
            { 3'd2, 4'h3 } : begin ale_valid = alwy; abv_valid = rpic; lef_valid = bpic; cur_valid = brcn; end

            { 3'd3, 4'h0 } : begin lef_valid = nlef; end
            { 3'd3, 4'h1 } : begin ale_valid = ntop; abv_valid = ntop; end
            { 3'd3, 4'h2 } : begin lef_valid = nlbp; end
            { 3'd3, 4'h3 } : begin ale_valid = alwy; abv_valid = rpic; lef_valid = bpic; cur_valid = brcn; end
            endcase
        end
    end
endmodule

module deblock_bs_calc (
        input logic       mb_edge ,
        input logic       p_nz    ,               
        input logic [1:0] p_mbtype, // 0-skip, 1-pcm, 2-inter, 3-intra              
        input logic [3:0] p_refidx,               
        input logic [9:0] p_mvx   ,               
        input logic [9:0] p_mvy   ,
        input logic       q_nz    ,
        input logic [1:0] q_mbtype, // 0-skip, 1-pcm, 2-inter, 3-intra
        input logic [3:0] q_refidx,
        input logic [9:0] q_mvx   ,
        input logic [9:0] q_mvy   ,
        output logic [2:0] bs      
   ); 
    always_comb begin : _bs_calc
        if( mb_edge && ( p_mbtype == 2'd3 || q_mbtype == 2'd3 )) begin
            bs = 4;
        end else if( !mb_edge && ( p_mbtype == 2'd3 || q_mbtype == 2'd3 )) begin
            bs = 3;
        end else if ( p_nz || q_nz ) begin
            bs = 2;
        end else if ( p_refidx != q_refidx || 
                     !((( p_mvx - q_mvx < 4 ) || ( q_mvx - p_mvx < 4 )) &&
                        (( p_mvx - q_mvx < 4 ) || ( q_mvx - p_mvx < 4 )))) begin
            bs = 1;
        end else begin
            bs = 0;
        end
    end
endmodule


// Sync write, async read ram.
module db_sram_1r1w_async
    #( 
        parameter DEPTH = 64,
        parameter AWIDTH = 5,
        parameter WIDTH = 32
     )
     (
         input  logic clk,
         input  logic we,
         input  logic [AWIDTH-1:0] raddr,
         input  logic [AWIDTH-1:0] waddr,
         input  logic [WIDTH-1:0] din,
         output logic [WIDTH-1:0] dout
     );
     
     (* rom_style = "distributed" *) logic [WIDTH-1:0] memory[DEPTH];
     
     
     // Sync write
     always_ff @(posedge clk) begin
        if( we )
            memory[waddr] = din;
     end

    // async read
    assign dout = memory[raddr];
     
endmodule

// Decode process a transform block
// Input: bitstream, block predictor, qpy,  and block index
// Output: recon, bitcount
module gg_deblock_filter
   #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
    )
    (
    input  logic clk, // not used, combinatorial block
    
    input  logic [0:3][0:15][7:0]  blki,  // 512 bit unfiltered or partially deblocked input
    output logic [0:3][0:15][7:0]  blko, // 512 bit fully or partially deblocked output
    input  logic [0:2][0:1][2:0] bs, // deblock bS, 2 per edge, for 3 boundaries 0-cur/lef, 1-lef/ale, 2-cur/abv
    input  logic [0:3][5:0] qpz, // block quantization paramters [0-51], clipped to zero if IPCM
    input  logic [4:0] FilterOffsetA, // -12 to +12
    input  logic [4:0] FilterOffsetB, // -12 to +12
    input  logic ch_flag // chroma block filtering
    );     

    // Intermediate nodes
    logic [0:15][7:0] cur_blk;
    logic [0:15][7:0] lef_blk;
    
    // calc alpha, beta deblock thresholds 
    
    logic [0:2][7:0] alpha;
    logic [0:2][7:0] beta;
    logic [0:2][0:1][4:0] tc0;
    logic [0:2][0:1][1:0] bsidx;
        
    logic [5:0] qpavg[2:0];
    logic [6:0] qpofsA[2:0];
    logic [6:0] qpofsB[2:0];
    logic [5:0] indexA[2:0];
    logic [5:0] indexB[2:0];
    logic xx0, xx1, xx2; // dummy bits
    
    // Lookup Tables    
    logic [0:51][5:0] qpc_table;
    logic [0:51][7:0] alpha_table;
    logic [0:51][7:0] beta_table;
    logic [0:2][0:51][4:0] tc0_table;
    
    assign qpc_table =  { 6'd0,  6'd1,  6'd2,  6'd3,  6'd4,  6'd5,  6'd6,  6'd7,  6'd8,  6'd9,  6'd10, 6'd11, 
                          6'd12, 6'd13, 6'd14, 6'd15, 6'd16, 6'd17, 6'd18, 6'd19, 6'd20, 6'd21, 6'd22, 6'd23, 
                          6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29, 6'd29, 6'd30, 6'd31, 6'd32, 6'd32, 6'd33, 
                          6'd34, 6'd34, 6'd35, 6'd35, 6'd36, 6'd36, 6'd37, 6'd37, 6'd37, 6'd38, 6'd38, 6'd38, 
                          6'd39, 6'd39, 6'd39, 6'd39 };

    assign alpha_table = { 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 
                           8'd0, 8'd0, 8'd0, 8'd0, 8'd4, 8'd4, 8'd5, 8'd6, 8'd7, 8'd8, 8'd9, 8'd10, 
                           8'd12, 8'd13, 8'd15, 8'd17, 8'd20, 8'd22, 8'd25, 8'd28, 8'd32, 8'd36, 8'd40, 8'd45, 
                           8'd50, 8'd56, 8'd63, 8'd71, 8'd80, 8'd90, 8'd101, 8'd113, 8'd127, 8'd144, 8'd162, 8'd182, 
                           8'd203, 8'd226, 8'd255, 8'd255 };
                           
    assign beta_table  = { 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 
                           8'd0, 8'd0, 8'd0, 8'd0, 8'd2, 8'd2, 8'd2, 8'd3, 8'd3, 8'd3, 8'd3, 8'd4, 
                           8'd4, 8'd4, 8'd6, 8'd6, 8'd7, 8'd7, 8'd8, 8'd8, 8'd9, 8'd9, 8'd10, 8'd10, 
                           8'd11, 8'd11, 8'd12, 8'd12, 8'd13, 8'd13, 8'd14, 8'd14, 8'd15, 8'd15, 8'd16, 8'd16, 
                           8'd17, 8'd17, 8'd18, 8'd18 };

    assign tc0_table =  {{ 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 
                           5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd1, 
                           5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd2, 5'd2, 5'd2, 
                           5'd2, 5'd3, 5'd3, 5'd3, 5'd4, 5'd4, 5'd4, 5'd5, 5'd6, 5'd6, 5'd7, 5'd8, 
                           5'd9, 5'd10, 5'd11, 5'd13  },
                         { 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 
                           5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd1, 5'd1, 5'd1, 
                           5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd2, 5'd2, 5'd2, 5'd2, 5'd3, 
                           5'd3, 5'd3, 5'd4, 5'd4, 5'd5, 5'd5, 5'd6, 5'd7, 5'd8, 5'd8, 5'd10, 5'd11, 
                           5'd12, 5'd13, 5'd15, 5'd17 },
                         { 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 
                           5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 5'd1, 
                           5'd1, 5'd1, 5'd1, 5'd2, 5'd2, 5'd2, 5'd2, 5'd3, 5'd3, 5'd3, 5'd4, 5'd4, 
                           5'd4, 5'd5, 5'd6, 5'd6, 5'd7, 5'd8, 5'd9, 5'd10, 5'd11, 5'd13, 5'd14, 5'd16, 
                           5'd18, 5'd20, 5'd23, 5'd25 } };

    
    always_comb begin
        // calc qp avg for the edges
        { qpavg[0][5:0], xx0 } = ch_flag ? (qpc_table[qpz[2]] + qpc_table[qpz[3]] + 1) : ( qpz[2] + qpz[3] + 1);  
        { qpavg[1][5:0], xx1 } = ch_flag ? (qpc_table[qpz[0]] + qpc_table[qpz[2]] + 1) : ( qpz[0] + qpz[2] + 1);  
        { qpavg[2][5:0], xx2 } = ch_flag ? (qpc_table[qpz[1]] + qpc_table[qpz[3]] + 1) : ( qpz[1] + qpz[3] + 1);  
        // loop thru edges to derive alpha, beta
        for( int ii = 0; ii < 3; ii++ ) begin
            // Deblock offset params
            qpofsA[ii][6:0] = { 1'b0, qpavg[ii][5:0] } + { {2{FilterOffsetA[4]}}, FilterOffsetA[4:0] };
            qpofsB[ii][6:0] = { 1'b0, qpavg[ii][5:0] } + { {2{FilterOffsetB[4]}}, FilterOffsetB[4:0] };
            // Clipped to [0,51] to give indexA, B
            indexA[ii][5:0] = ( qpofsA[ii][6] ) ? 6'd0 : ( qpofsA[ii][5:0] > 6'd51 ) ? 6'd51 : qpofsA[ii][5:0];
            indexB[ii][5:0] = ( qpofsB[ii][6] ) ? 6'd0 : ( qpofsB[ii][5:0] > 6'd51 ) ? 6'd51 : qpofsB[ii][5:0];
            // lookup alpha, beta
            alpha[ii][7:0] = alpha_table[indexA[ii]];
            beta[ii][7:0]  = beta_table[indexB[ii]];
            bsidx[ii][0][1:0] = (bs[ii]==2)?2'd1:(bs[ii][0]==3)?2'd2:2'd0;
            bsidx[ii][1][1:0] = (bs[ii]==2)?2'd1:(bs[ii][1]==3)?2'd2:2'd0; // different for chroma
            tc0[ii][0][4:0]   = tc0_table[bsidx[ii][0]][indexA[ii]];
            tc0[ii][1][4:0]   = tc0_table[bsidx[ii][1]][indexA[ii]];
         end
    end
    
        
    genvar ii;
    generate
        // Vertical edge 0 Filter:  cur | lef = filter ( blki[2] | blki[3] )
        for (ii=0; ii<4; ii=ii+1) begin
            gg_deblock_filter_1x8 _filt0 ( 
                .clk        ( clk      ),
                .ch_flag    ( ch_flag  ),
                .bs         ( ( ii < 2 ) ? bs[0][0] : bs[0][1] ),
                .alpha      ( alpha[0] ),
                .beta       ( beta[0]  ),
                .tc0        ( ( ii < 2 ) ? tc0[0][0] : tc0[0][1] ),
                .qi         ( { blki[3][0+4*ii], blki[3][1+4*ii], blki[3][2+4*ii], blki[3][3+4*ii] } ),
                .pi         ( { blki[2][3+4*ii], blki[2][2+4*ii], blki[2][1+4*ii], blki[2][0+4*ii] } ),
                .qo         ( { cur_blk[0+4*ii], cur_blk[1+4*ii], cur_blk[2+4*ii], cur_blk[3+4*ii] } ),
                .po         ( { lef_blk[3+4*ii], lef_blk[2+4*ii], lef_blk[1+4*ii], lef_blk[0+4*ii] } )
            );
        end
        
        // Horizontal edge 1 filter: blko[2] | blko[0] =  filter ( lef | blki[0] )
        for (ii=0; ii<4; ii=ii+1) begin
            gg_deblock_filter_1x8 _filt1 ( 
                .clk        ( clk      ),
                .ch_flag    ( ch_flag  ),
                .bs         ( ( ii < 2 ) ? bs[1][0] : bs[1][1] ),
                .alpha      ( alpha[1] ),
                .beta       ( beta[1]  ),
                .tc0        ( ( ii < 2 ) ? tc0[1][0] : tc0[1][1] ),
                .qi         ( { lef_blk[0*4+ii], lef_blk[1*4+ii], lef_blk[2*4+ii], lef_blk[3*4+ii] } ),
                .pi         ( { blki[0][3*4+ii], blki[0][2*4+ii], blki[0][1*4+ii], blki[0][0*4+ii] } ),
                .qo         ( { blko[2][0*4+ii], blko[2][1*4+ii], blko[2][2*4+ii], blko[2][3*4+ii] } ),
                .po         ( { blko[0][3*4+ii], blko[0][2*4+ii], blko[0][1*4+ii], blko[0][0*4+ii] } )
            );
        end
    
        // Horizontal edge 2 filter: blko[3] | blko[1] =  filter ( cur | blki[1] )
        for (ii=0; ii<4; ii=ii+1) begin
            gg_deblock_filter_1x8 _filt2 ( 
                .clk        ( clk      ),
                .ch_flag    ( ch_flag  ),
                .bs         ( ( ii < 2 ) ? bs[2][0] : bs[2][1] ),
                .alpha      ( alpha[2] ),
                .beta       ( beta[2]  ),
                .tc0        ( ( ii < 2 ) ? tc0[2][0] : tc0[2][1] ),
                .qi         ( { cur_blk[0*4+ii], cur_blk[1*4+ii], cur_blk[2*4+ii], cur_blk[3*4+ii] } ),
                .pi         ( { blki[1][3*4+ii], blki[1][2*4+ii], blki[1][1*4+ii], blki[1][0*4+ii] } ),
                .qo         ( { blko[3][0*4+ii], blko[3][1*4+ii], blko[3][2*4+ii], blko[3][3*4+ii] } ),
                .po         ( { blko[1][3*4+ii], blko[1][2*4+ii], blko[1][1*4+ii], blko[1][0*4+ii] } )
            );
        end
    endgenerate    
endmodule

module gg_deblock_filter_1x8
(
    input logic clk,
    input logic ch_flag,
    input logic [2:0] bs,
    input logic [7:0] alpha,
    input logic [7:0] beta,
    input logic [4:0] tc0,
    input logic [0:3][7:0] pi,
    input logic [0:3][7:0] qi,
    output logic [0:3][7:0] po,
    output logic [0:3][7:0] qo
 );

    logic filterSamplesFlag;
    logic aq1_lt_beta, ap1_lt_beta, aq2_lt_beta, ap2_lt_beta, pq_lt_alpha, pq_lt_alpha_d4;
    logic [4:0]  tc;
    logic [2:0]  dummy1;
    logic [5:0]  delta_clip;
    logic [11:0] delta;
    logic [9:0]  p0pd, q0md;
    logic [7:0]  p0pd_clip, q0md_clip;
    logic [10:0] p1d, q1d;
    logic [5:0]  p1d_clip, q1d_clip;
    logic [7:0]  p1pd, q1pd;
    logic [7:0]  alpha_d4;
    logic [10:0] p0f, p1f, p2f, p0cf;
    logic [10:0] q0f, q1f, q2f, q0cf;

    always_comb begin
        // make filter decision based on thresholds    
        aq2_lt_beta =   ( { 1'b0, qi[2] } - { 1'b0, qi[0] } < { 1'b0, beta  } || 
                         { 1'b0, qi[0] } - { 1'b0, qi[2] } < { 1'b0, beta  } ) ? 1'b1 : 1'b0;
        ap2_lt_beta =   ( { 1'b0, pi[2] } - { 1'b0, pi[0] } < { 1'b0, beta  } || 
                         { 1'b0, pi[0] } - { 1'b0, pi[2] } < { 1'b0, beta  } ) ? 1'b1 : 1'b0;
        aq1_lt_beta =   ( { 1'b0, qi[1] } - { 1'b0, qi[0] } < { 1'b0, beta  } || 
                         { 1'b0, qi[0] } - { 1'b0, qi[1] } < { 1'b0, beta  } ) ? 1'b1 : 1'b0;
        ap1_lt_beta =   ( { 1'b0, pi[1] } - { 1'b0, pi[0] } < { 1'b0, beta  } || 
                         { 1'b0, pi[0] } - { 1'b0, pi[1] } < { 1'b0, beta  } ) ? 1'b1 : 1'b0;

        pq_lt_alpha =  ( { 1'b0, pi[0] } - { 1'b0, qi[0] } < { 1'b0, alpha } || 
                         { 1'b0, qi[0] } - { 1'b0, pi[0] } < { 1'b0, alpha } ) ? 1'b1 : 1'b0 ;
        alpha_d4      = alpha[7:2] + 2;
        pq_lt_alpha_d4 =  ( { 1'b0, pi[0] } - { 1'b0, qi[0] } < { 1'b0, alpha_d4 } || 
                          { 1'b0, qi[0] } - { 1'b0, pi[0] } < { 1'b0, alpha_d4 } ) ? 1'b1 : 1'b0 ;
     
        // Bs < 4 decision flag
        filterSamplesFlag = pq_lt_alpha & ap1_lt_beta & aq1_lt_beta;

        // Calculate p0, q0 for Bs < 4 
        tc = tc0 + (( ch_flag ) ? 5'd1 : ({ 4'b0, ap2_lt_beta } + { 4'b0, aq2_lt_beta }));
        delta[11:0] = ( { 2'b00  , qi[0], 2'b00 } - { 2'b00  , pi[0], 2'b00 } ) +
                      ( { 4'b0000, pi[1]        } - { 4'b0000, qi[1]        } ) + 12'd4;
        delta_clip[5:0] = ( !delta[11] && delta[11:3] >  { 4'b0000,  tc[4:0] } ) ? { 1'b0,  tc[4:0] } :
                          (  delta[11] && delta[11:3] <= { 4'b1111, ~tc[4:0] } ) ? { 1'b1, ~tc[4:0] } + 6'd1 : delta[8:3];
        p0pd[9:0] = { 2'b00, pi[0][7:0] } + { {4{delta_clip[5]}}, delta_clip[5:0] } ;
        q0md[9:0] = { 2'b00, qi[0][7:0] } - { {4{delta_clip[5]}}, delta_clip[5:0] } ;
        p0pd_clip[7:0] = ( p0pd[9] ) ? 8'h00 : ( p0pd[8] ) ? 8'hFF : p0pd[7:0];  
        q0md_clip[7:0] = ( q0md[9] ) ? 8'h00 : ( q0md[8] ) ? 8'hFF : q0md[7:0];  
        
        // Calculate p1, q1 for Luma Bs < 4 
        p1d[10:0] = { 2'b00, pi[2], 1'b1 } + { 3'b000, pi[0] } + { 3'b000, qi[0] } - { 1'b0, pi[1], 2'b00 };
        q1d[10:0] = { 2'b00, qi[2], 1'b1 } + { 3'b000, pi[0] } + { 3'b000, qi[0] } - { 1'b0, qi[1], 2'b00 };

        p1d_clip = ( !p1d[10] && p1d[10:1] >  {5'b00000,  tc0[4:0]} ) ? { 1'b0,  tc0[4:0] } :
                   (  p1d[10] && p1d[10:1] <= {5'b11111, ~tc0[4:0]} ) ? { 1'b1, ~tc0[4:0] } + 6'd1 : p1d[6:1];
        q1d_clip = ( !q1d[10] && q1d[10:1] >  {5'b00000,  tc0[4:0]} ) ? { 1'b0,  tc0[4:0] } :
                   (  q1d[10] && q1d[10:1] <= {5'b11111, ~tc0[4:0]} ) ? { 1'b1, ~tc0[4:0] } + 6'd1 : q1d[6:1];
        p1pd = pi[1] + { {2{p1d_clip[5]}}, p1d_clip };
        q1pd = qi[1] + { {2{q1d_clip[5]}}, q1d_clip };
        
        // Calculate functions for p0, p1, p2, q0, q1, q2
        
        p0f  = (pi[2] + {pi[1], 1'b0}) + ({pi[0],1'b0} + {qi[0],1'b0}) + (qi[1] + 4);
        p1f  = (pi[2] + pi[1]) + (pi[0] + qi[0]) + 2;
        p2f  = (({pi[3],1'b0} + {pi[2],1'b0}) + (pi[2] + pi[1])) + ((pi[0] + qi[0]) + 4);
        p0cf = ({pi[1],1'b0} + pi[0]) + (qi[1] + 2);      

        q0f  = (qi[2] + {qi[1], 1'b0}) + ({qi[0],1'b0} + {pi[0],1'b0}) + (pi[1] + 4);
        q1f  = (qi[2] + qi[1]) + (qi[0] + pi[0]) + 2;
        q2f  = (({qi[3],1'b0} + {qi[2],1'b0}) + (qi[2] + qi[1])) + ((qi[0] + pi[0]) + 4);
        q0cf = ({qi[1],1'b0} + qi[0]) + (pi[1] + 2);      
        
        // Output default and bS decision       
        po = pi;
        qo = qi;
        // Bs == 4
        if( filterSamplesFlag && bs[2:0] == 3'd4 ) begin
            if( ap2_lt_beta && pq_lt_alpha_d4 && !ch_flag ) begin
                po[0] = p0f[10:3];
                po[1] = p1f[9:2];
                po[2] = p2f[10:3];
            end else begin
                po[0] = p0cf[9:2];
            end
            if( aq2_lt_beta && pq_lt_alpha_d4 && !ch_flag ) begin
                qo[0] = q0f[10:3];
                qo[1] = q1f[9:2];
                qo[2] = q2f[10:3];
            end else begin
                qo[0] = q0cf[9:2]; 
            end       
        end

        // Bs 1-3 - Luma
        else if( filterSamplesFlag && bs[2:0] != 3'd0 ) begin
            po[0] = p0pd;
            qo[0] = q0md;
            if( ap2_lt_beta && !ch_flag )
                po[1] = p1pd;
            if( aq2_lt_beta && !ch_flag )
                qo[1] = q1pd;
        end
    end   
endmodule