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


// Decode a row slice rbsp (
// Row slice MBs have no above context, difficult for lattice due to skip runs.
// Runs in parallel with gg_parse_lattice, and gg_parge_macroblock
// Input: bits[], start_slice[] 
//   start_slice = pointer to 1st bit, which is byte aligned, of the slice_layer_rbsp() 
//   The slice is terminated when more_rbsp_data() = 0 following a macroblock or skip_run > 0.
//   more_rbps_data()=0 when following is: {stop_one_bit, alignment_zero_bits, 23'b0}
// Output: end_slice[].
//   Slice ends after stop and alignment bits, so it's byte aligned.


module gg_parse_lattice_rowslice
   #(
     parameter int WIDTH             = 32,
     parameter int BYTE_WIDTH        = WIDTH / 8
    )
    (
    // System
    input  logic clk,
    input  logic reset,
    // Input bits
    input  logic [WIDTH-1:0] in_bits, // bitstream, bit endian packed
    input  logic [31:0]      in_pad, // Lookahead of 32 bits
    // Input mb_start trigger
    input  logic [BYTE_WIDTH-1:0] slice_start, // byte aligned input trigger
    output logic [BYTE_WIDTH-1:0] slice_end, // byte aligned completion
    // macroblock lattice interface 
    output logic             mb_above_oop, // alays 1 for a row slice!
    output logic [WIDTH-1:0] mb_left_skip, // sent with mb_start, if preceeding skip_run != 0
    output logic [WIDTH-1:0] mb_left_oop,  
    output logic [WIDTH-1:0] mb_start, // macroblock parse trigger
    input  logic [WIDTH-1:0] mb_end // macroblock end pulse    
    );

    parameter SLICE_SYNTAX_SLICE_TYPE = 0 ; // slice_type ue(v) 0=P Slice
    parameter SLICE_SYNTAX_PARAM_ID   = 1 ; // pic_parameter_set_id ue(v)
    parameter SLICE_SYNTAX_FRAME_NUM  = 2 ; // frame_num u(v=4)
    parameter SLICE_SYNTAX_POC_LSB    = 3 ; // pic_order_cnt_lsb u(v=4)
    parameter SLICE_SYNTAX_REF_OVR_FL = 4 ; // num_ref_idx_active_override_flag u(1)
    parameter SLICE_SYNTAX_REF_MOD_FL = 5 ; // ref_pic_list_modification_flag_l0 u(1)
    parameter SLICE_SYNTAX_REF_MARK_FL= 6 ; // adaptive_ref_pic_marking_mode_flag u(1)
    parameter SLICE_SYNTAX_QP_DELTA   = 7 ; // slice_qp_delta se(v) 
    parameter SLICE_SYNTAX_DBLK_IDC   = 8 ; // disable_deblocking_filter_idc ue(v)
    parameter SLICE_SYNTAX_DBLK_ALPHA = 9 ; // != 1 --> slice_alpha_c0_offset_div2 se(v)
    parameter SLICE_SYNTAX_DBLK_BETA  = 10; // != 1 --> slice_beta_offset_div2 se(v)
    parameter SLICE_SYNTAX_SKIP_RUN   = 11; // first mb_skip_run ue(v)
    parameter SLICE_SYNTAX_MB_START_0 = 12; // first MB in slice, skip=0
    parameter SLICE_SYNTAX_MB_START_1 = 13; // first MB in slice, skip>=1
    parameter SLICE_SYNTAX_MB_START_2 = 14; // MB in slice, skip=0
    parameter SLICE_SYNTAX_MB_START_3 = 15; // MB in slice, skip>=1
    
    parameter SLICE_SYNTAX_COUNT      = 16;

    logic [WIDTH+31:0][0:SLICE_SYNTAX_COUNT-1]           s_slice_syntax; // macroblock syntax elements 
    logic       [31:0][0:SLICE_SYNTAX_COUNT-1]           s_slice_syntax_reg; // macroblock syntax elements 
    logic [WIDTH+31:0][0:SLICE_SYNTAX_COUNT-1][0:16]   arc_slice_syntax; // [syntax element][ue/se prefix length] 

    logic [WIDTH+31:32]                      s_mb_start;    
    logic [WIDTH+31:32]                      s_left_skip;
    logic [WIDTH+31:32]                      s_left_oop;
      
    logic [WIDTH+31:0][0:15]               arc_last;
    logic [WIDTH+31:0]                      s_last;
    logic       [31:31]                      s_last_reg; 
    
    

    
    
    logic [WIDTH+31:0][0:15]            ue_prefix;
    logic [WIDTH+31:0]                  more_rbsp;
    
    logic [WIDTH+31:0] bits;
    logic [WIDTH+31:0] mb_end_flag;
    logic [WIDTH+31:0] slice_start_flag;
    
    // Set up array inputs
    always_comb begin
        slice_start_flag = 0;
        for( int ii = 0; ii < BYTE_WIDTH; ii++ ) begin
            slice_start_flag[WIDTH+31-ii*8] = slice_start[BYTE_WIDTH-1-ii];
        end
        mb_end_flag = { mb_end, 32'b0 };
        bits = { in_bits, in_pad };
    end

    // Loop Over bitpositions 
    always_comb begin : _lattice_slice_parse
        // Clear last arcs
        
        // Clear state arcs
        arc_slice_syntax = 0;
        arc_last = 0;
    
        // Clear state
        s_slice_syntax = 0;
        s_last = 0;
        s_mb_start = 0;
        s_left_oop = 0;
        s_left_skip = 0;

        // Clear decode arrays
        ue_prefix = 0;
        more_rbsp = 0;
        
        // Instantiate unqiue hardware for each bit of the input
        for( int bp = WIDTH-1+32; bp >= 32; bp-- ) begin : _slice_lattice_col
            begin : _ue_prefix
                ue_prefix[bp][0] = ( bits[bp-:1 ] == 1'b1                 ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][1] = ( bits[bp-:2 ] == 2'b01                ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][2] = ( bits[bp-:3 ] == 3'b001               ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][3] = ( bits[bp-:4 ] == 4'b0001              ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][4] = ( bits[bp-:5 ] == 5'b00001             ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][5] = ( bits[bp-:6 ] == 6'b000001            ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][6] = ( bits[bp-:7 ] == 7'b0000001           ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][7] = ( bits[bp-:8 ] == 8'b00000001          ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][8] = ( bits[bp-:9 ] == 9'b000000001         ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][9] = ( bits[bp-:10] == 10'b0000000001       ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][10] =( bits[bp-:11] == 11'b00000000001      ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][11] =( bits[bp-:12] == 12'b000000000001     ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][12] =( bits[bp-:13] == 13'b0000000000001    ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][13] =( bits[bp-:14] == 14'b00000000000001   ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][14] =( bits[bp-:15] == 15'b000000000000001  ) ? 1'b1 : 1'b0; 
                ue_prefix[bp][15] =( bits[bp-:16] == 16'b0000000000000001 ) ? 1'b1 : 1'b0; 
            end // ue prefix

            begin : _more_rbsp
                more_rbsp[bp] =(( bp % 8 == 3'd7 ) && bits[bp-:31] == 31'b10000000_00000000_00000000_0000000 ||
                                ( bp % 8 == 3'd6 ) && bits[bp-:30] == 30'b_1000000_00000000_00000000_0000000 ||
                                ( bp % 8 == 3'd5 ) && bits[bp-:29] == 29'b__100000_00000000_00000000_0000000 ||
                                ( bp % 8 == 3'd4 ) && bits[bp-:28] == 28'b___10000_00000000_00000000_0000000 ||
                                ( bp % 8 == 3'd3 ) && bits[bp-:27] == 27'b____1000_00000000_00000000_0000000 ||
                                ( bp % 8 == 3'd2 ) && bits[bp-:26] == 26'b_____100_00000000_00000000_0000000 ||
                                ( bp % 8 == 3'd1 ) && bits[bp-:25] == 25'b______10_00000000_00000000_0000000 ||
                                ( bp % 8 == 3'd0 ) && bits[bp-:24] == 24'b_______1_00000000_00000000_0000000 ) ? 1'b0 : 1'b1; // inverted
            end // more_rbsp



            begin : _slice_syntax 
                // Reduction OR the current arcs and previous registered ones too.           
                for( int ii = 0; ii < SLICE_SYNTAX_COUNT; ii++ ) begin
                    s_slice_syntax[bp][ii] = |arc_slice_syntax[bp][ii] | ((bp >= WIDTH) ? s_slice_syntax_reg[bp-WIDTH][ii] : 1'b0 ); // Reduction OR
                end
                // handle UE/SE (assume max 15 prefix length
                for( int pl=0; pl < 16; pl++ ) begin
                    arc_slice_syntax[bp-(pl*2+1)][SLICE_SYNTAX_SLICE_TYPE     ][pl] = ue_prefix[bp][pl] & slice_start_flag[bp]; // first_mb_in_slice  ue(v)   
                    arc_slice_syntax[bp-(pl*2+1)][SLICE_SYNTAX_PARAM_ID       ][pl] = ue_prefix[bp][pl] & s_slice_syntax[bp][SLICE_SYNTAX_SLICE_TYPE];   
                    arc_slice_syntax[bp-(pl*2+1)][SLICE_SYNTAX_FRAME_NUM      ][pl] = ue_prefix[bp][pl] & s_slice_syntax[bp][SLICE_SYNTAX_PARAM_ID];   
                    arc_slice_syntax[bp-(pl*2+1)][SLICE_SYNTAX_DBLK_IDC       ][pl] = ue_prefix[bp][pl] & s_slice_syntax[bp][SLICE_SYNTAX_QP_DELTA];   
                    arc_slice_syntax[bp-(pl*2+1)][SLICE_SYNTAX_DBLK_BETA      ][pl] = ue_prefix[bp][pl] & s_slice_syntax[bp][SLICE_SYNTAX_DBLK_ALPHA];   
                    arc_slice_syntax[bp-(pl*2+1)][SLICE_SYNTAX_SKIP_RUN       ][pl] = ue_prefix[bp][pl] & s_slice_syntax[bp][SLICE_SYNTAX_DBLK_BETA];  
                    if( pl == 0 ) begin
                        arc_slice_syntax[bp-(pl*2+1)][SLICE_SYNTAX_MB_START_0 ][pl] = ue_prefix[bp][pl] & s_slice_syntax[bp][SLICE_SYNTAX_SKIP_RUN];  
                        arc_slice_syntax[bp-(pl*2+1)][SLICE_SYNTAX_MB_START_2 ][pl] = ue_prefix[bp][pl] & more_rbsp[bp] & mb_end_flag[bp];  
                    end else begin
                        arc_slice_syntax[bp-(pl*2+1)][SLICE_SYNTAX_MB_START_1 ][pl] = ue_prefix[bp][pl] & s_slice_syntax[bp][SLICE_SYNTAX_SKIP_RUN];  
                        arc_slice_syntax[bp-(pl*2+1)][SLICE_SYNTAX_MB_START_3 ][pl] = ue_prefix[bp][pl] & more_rbsp[bp] & mb_end_flag[bp];  
                    end
                end // pl
                
                // Handle fixed length cases
                arc_slice_syntax[bp-4][SLICE_SYNTAX_POC_LSB    ][0] = s_slice_syntax[bp][SLICE_SYNTAX_FRAME_NUM];   
                arc_slice_syntax[bp-4][SLICE_SYNTAX_REF_OVR_FL ][0] = s_slice_syntax[bp][SLICE_SYNTAX_POC_LSB];  
                arc_slice_syntax[bp-1][SLICE_SYNTAX_REF_MOD_FL ][0] = s_slice_syntax[bp][SLICE_SYNTAX_REF_OVR_FL];    
                arc_slice_syntax[bp-1][SLICE_SYNTAX_REF_MARK_FL][0] = s_slice_syntax[bp][SLICE_SYNTAX_REF_MOD_FL];   
                arc_slice_syntax[bp-1][SLICE_SYNTAX_QP_DELTA   ][0] = s_slice_syntax[bp][SLICE_SYNTAX_REF_MARK_FL];   
                    
                // Handle deblock IDC branching
                arc_slice_syntax[bp-1][SLICE_SYNTAX_DBLK_ALPHA /* se() */  ][0] = (bits[bp-:1] == 1'b1  ) & s_slice_syntax[bp][SLICE_SYNTAX_DBLK_IDC];   // DEBLK_IDC == 0
                arc_slice_syntax[bp-3][SLICE_SYNTAX_DBLK_ALPHA /* se() */  ][1] = (bits[bp-:3] == 3'b011) & s_slice_syntax[bp][SLICE_SYNTAX_DBLK_IDC];   // DEBLK_IDC == 2
                arc_slice_syntax[bp-3][SLICE_SYNTAX_SKIP_RUN   /* ue() */  ][16]= (bits[bp-:3] == 3'b010) & s_slice_syntax[bp][SLICE_SYNTAX_DBLK_IDC];   // DEBLK_IDC == 1
            end // mv


            begin : _slice_macroblock_start_end // Handle the row macroblocks until !more_rbsp_data(), inclding skip runs
                // After each skip run, if more rbsp start mb
                s_mb_start[bp]  = s_slice_syntax[bp][SLICE_SYNTAX_MB_START_0]                 | 
                                  s_slice_syntax[bp][SLICE_SYNTAX_MB_START_1] & more_rbsp[bp] |
                                  s_slice_syntax[bp][SLICE_SYNTAX_MB_START_2]                 |
                                  s_slice_syntax[bp][SLICE_SYNTAX_MB_START_3] & more_rbsp[bp] ;
                                                   
                s_left_skip[bp] = s_slice_syntax[bp][SLICE_SYNTAX_MB_START_1] & more_rbsp[bp] | 
                                  s_slice_syntax[bp][SLICE_SYNTAX_MB_START_3] & more_rbsp[bp] ;
                                                  
                s_left_oop[bp]  = s_slice_syntax[bp][SLICE_SYNTAX_MB_START_0]                 ;
               
                // Last when no more rbsp after each MB and non-zero skip run
                arc_last[bp-1-(bp%8)][bp%8] = !more_rbsp[bp] & s_slice_syntax[bp][SLICE_SYNTAX_MB_START_1] |
                                              !more_rbsp[bp] & s_slice_syntax[bp][SLICE_SYNTAX_MB_START_3] |
                                              !more_rbsp[bp] & mb_end_flag[bp]; 
                // slice end Reduction OR
                s_last[bp] = |arc_last[bp] | ((bp == WIDTH+31) ? s_last_reg[31] : 1'b0 ); // Reduction OR
            end // _slice_data_syntax
        end // bp
    end // _lattice

    // Connect up the output bits
    always_comb begin
        for( int ii = 0; ii < BYTE_WIDTH; ii++ ) begin
            slice_end[BYTE_WIDTH-1-ii] = s_last[WIDTH+32-1-ii*8];
        end
        mb_start[WIDTH-1:0]     = s_mb_start[WIDTH+32-1:32];
        mb_left_oop[WIDTH-1:0]  = s_left_oop[WIDTH+32-1:32];
        mb_left_skip[WIDTH-1:0] = s_left_skip[WIDTH+32-1:32];
    end
    
    always_ff @(posedge clk) begin // Lower 32 set of states are flopped  
        if( reset ) begin
            // Handle variable length codes   
            s_slice_syntax_reg <= 0; 
            s_last_reg <= 0;  
        end else begin
            // Handle the variable lenght arcs (up to 31 bits)
            s_last_reg[31] <= |arc_last[31]; // Can only occur on 1st padding bit
            for( int bp = 31; bp >= 0; bp-- ) begin
                for( int ii = 0; ii < SLICE_SYNTAX_COUNT; ii++ ) begin
                    s_slice_syntax_reg[bp][ii] <= |arc_slice_syntax[bp][ii]; // Reduction OR
                end
            end // bp
        end // reset
    end // ff
endmodule

