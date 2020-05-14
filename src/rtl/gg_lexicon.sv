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

// Lexicon of emitted H.264 codewords and phrases: 
// Input: phrase selection index, 
//        basic inputs frame number, frame size, etc ... 
// Output: selected word/phrase in vlc format for immediate encoding into the bitstream
//         post_byte_alignment flag (indicates that zero filled byte alignment after phrase

// UE bit functions (pass in x + 1)
`define GG_UE_BITS(x) (x)

`define GG_UE_LEN(x) \
   (((x) & (1<<31)) ? 'd63 : \
    ((x) & (1<<30)) ? 'd61 : \
    ((x) & (1<<29)) ? 'd59 : \
    ((x) & (1<<28)) ? 'd57 : \
    ((x) & (1<<27)) ? 'd55 : \
    ((x) & (1<<26)) ? 'd53 : \
    ((x) & (1<<25)) ? 'd51 : \
    ((x) & (1<<24)) ? 'd49 : \
    ((x) & (1<<23)) ? 'd47 : \
    ((x) & (1<<22)) ? 'd45 : \
    ((x) & (1<<21)) ? 'd43 : \
    ((x) & (1<<20)) ? 'd41 : \
    ((x) & (1<<19)) ? 'd39 : \
    ((x) & (1<<18)) ? 'd37 : \
    ((x) & (1<<17)) ? 'd35 : \
    ((x) & (1<<16)) ? 'd33 : \
    ((x) & (1<<15)) ? 'd31 : \
    ((x) & (1<<14)) ? 'd29 : \
    ((x) & (1<<13)) ? 'd27 : \
    ((x) & (1<<12)) ? 'd25 : \
    ((x) & (1<<11)) ? 'd23 : \
    ((x) & (1<<10)) ? 'd21 : \
    ((x) & (1<<9 )) ? 'd19 : \
    ((x) & (1<<8 )) ? 'd17 : \
    ((x) & (1<<7 )) ? 'd15 : \
    ((x) & (1<<6 )) ? 'd13 : \
    ((x) & (1<<5 )) ? 'd11 : \
    ((x) & (1<<4 )) ? 'd9 : \
    ((x) & (1<<3 )) ? 'd7 : \
    ((x) & (1<<2 )) ? 'd5 : \
    ((x) & (1<<1 )) ? 'd3 : \
    ((x) & (1<<0 )) ? 'd1 : 0 )
    
`define GG_UE_MASK(x) \
   (((x) & (1<<31)) ? 'h7FFFFFFFFFFFFFFF : \
    ((x) & (1<<30)) ? 'h1FFFFFFFFFFFFFFF : \
    ((x) & (1<<29)) ? 'h7FFFFFFFFFFFFFF : \
    ((x) & (1<<28)) ? 'h1FFFFFFFFFFFFFF : \
    ((x) & (1<<27)) ? 'h7FFFFFFFFFFFFF : \
    ((x) & (1<<26)) ? 'h1FFFFFFFFFFFFF : \
    ((x) & (1<<25)) ? 'h7FFFFFFFFFFFF : \
    ((x) & (1<<24)) ? 'h1FFFFFFFFFFFF : \
    ((x) & (1<<23)) ? 'h7FFFFFFFFFFF : \
    ((x) & (1<<22)) ? 'h1FFFFFFFFFFF : \
    ((x) & (1<<21)) ? 'h7FFFFFFFFFF : \
    ((x) & (1<<20)) ? 'h1FFFFFFFFFF : \
    ((x) & (1<<19)) ? 'h7FFFFFFFFF : \
    ((x) & (1<<18)) ? 'h1FFFFFFFFF : \
    ((x) & (1<<17)) ? 'h7FFFFFFFF : \
    ((x) & (1<<16)) ? 'h1FFFFFFFF : \
    ((x) & (1<<15)) ? 'h7FFFFFFF : \
    ((x) & (1<<14)) ? 'h1FFFFFFF : \
    ((x) & (1<<13)) ? 'h7FFFFFF  : \
    ((x) & (1<<12)) ? 'h1FFFFFF  : \
    ((x) & (1<<11)) ? 'h7FFFFF   : \
    ((x) & (1<<10)) ? 'h1FFFFF   : \
    ((x) & (1<<9 )) ? 'h7FFFF    : \
    ((x) & (1<<8 )) ? 'h1FFFF    : \
    ((x) & (1<<7 )) ? 'h7FFF     : \
    ((x) & (1<<6 )) ? 'h1FFF     : \
    ((x) & (1<<5 )) ? 'h7FF      : \
    ((x) & (1<<4 )) ? 'h1FF      : \
    ((x) & (1<<3 )) ? 'h7F       : \
    ((x) & (1<<2 )) ? 'h1F       : \
    ((x) & (1<<1 )) ? 'h7        : \
    ((x) & (1<<0 )) ? 'h1        : 0 )
    
    
   
   
module gg_lexicon
   #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
    )
    (
    input  logic clk,
    input  logic [7:0] phrase_sel,
    input  logic [7:0] level_idc,
    input  logic [3:0] frame_num,
    input  logic [3:0] poc_lsb, // pic_order_cnt_lsb
    input  logic [15:0] mb_width,
    input  logic [15:0] mb_height,
    input  logic [3:0] alpha_offset,
    input  logic [3:0] beta_offset,
    input  logic [1:0] disable_deblocking_filter_idc,
    input  logic [23:0] skip_run,
    input  logic [5:0] dqp, // delta QP -26 to +25
    input  logic [5:0] cbp,
    input  logic       refidx,
    input  logic [127:0] pcm_byte_data,
    input  logic [1039:0] transform_block,
    output logic [1039:0] vlc512_phrase,
    output logic vlc512_byte_align, // Indicates byte alignment after the vlc is emitted
    output logic [3:0] vlc512_startcode_mark // indicates given byte is part of a startcode
    );

    logic [23:0] skip_run_plus1 = skip_run + 1;
    logic [31:0] frame_mb_plus1 = (mb_width * mb_height) + 1;
    logic [5:0] dqp_code_plus1 = ( dqp ) ? ( (dqp[5])? {(~dqp[4:0] + 1), 1'b1 } : {dqp[4:0],1'b0} ): 1;

    logic [0:47][5:0] cbp_intra_code_plus1 = {  6'd1 ,6'd3 ,6'd4 ,6'd8 ,6'd5 ,6'd9 ,6'd18,6'd14,
                                                6'd6 ,6'd19,6'd10,6'd15,6'd11,6'd16,6'd17,6'd12,
                                                6'd2 ,6'd33,6'd34,6'd37,6'd35,6'd38,6'd45,6'd41,
                                                6'd36,6'd46,6'd39,6'd42,6'd40,6'd43,6'd44,6'd20,
                                                6'd7 ,6'd25,6'd26,6'd21,6'd27,6'd22,6'd47,6'd29,
                                                6'd28,6'd48,6'd23,6'd30,6'd24,6'd31,6'd32,6'd13 };
    logic [5:0] cbp_code_plus1 = cbp_intra_code_plus1[cbp[5:0]][5:0];
    //////////////////////////////////////////////////////
    // 'h00: SPS( level, width, height )
    //////////////////////////////////////////////////////

    logic [519:0] vlc256_sps_nal;
    logic [263:0] vlc128_sps_nal_int[6];
 
    // 32 : 0x00 0x00 0x00 0x01
    //  8 : 0_01_00111 = 0x 27 = nal unit header PPS
    //  8 : 0x66 - profile_idc
    //  8 : 11100000_ - constraint flags, reserve zero 2bits
    //  8 : U(8, level)
    //  3 : 1_1_1 = UE(seq_parameter_set_id=0), UE(log2_max_frame_num_minus4=0), UE(pic_order_cnt_type=0)
    //  5 : 1_011_1 = UE(log2_max_pic_order_cnt_lsb_minus4=0), UE(max_num_ref_frames=2), gaps_in_frame_num_value_allowed_flag=1
    // --
    // 72
    assign vlc128_sps_nal_int[0][263:135] = {72{1'b1}};
    assign vlc128_sps_nal_int[0][134:  8] = { 56'h00_00_00_01_27_66_E0, level_idc[7:0], 8'b1_1_1_1_011_1 };
    assign vlc128_sps_nal_int[0][  7:  0] = 'd72; 
    
    // UE( mb_width - 1 );
    assign vlc128_sps_nal_int[1][263:135] = GG_UE_MASK( mb_width );
    assign vlc128_sps_nal_int[1][134:  8] = mb_width;
    assign vlc128_sps_nal_int[1][  7:  0] = GG_UE_LEN(  mb_width );
    
    // UE( mb_height - 1 );
    assign vlc128_sps_nal_int[2][263:135] = GG_UE_MASK( mb_height );
    assign vlc128_sps_nal_int[2][134:  8] = mb_height;
    assign vlc128_sps_nal_int[2][  7:  0] = GG_UE_LEN(  mb_width );
    
    // 1_0_0_0 = frame_mbs_only_flag=1, direct_8x8_inference_flag=0, frame_cropping_flag=0, vui_parameters_present_flag
    // 1_ : rbsp stop bit     
    assign vlc128_sps_nal_int[3][263:135] = 'b1_1_1_1_1;
    assign vlc128_sps_nal_int[3][134:  8] = 'b1_0_0_0_1;
    assign vlc128_sps_nal_int[3][  7:  0] = 'd5;
 
    // Put together phrase
     vlc_cat #(103,  72, 31, 128, 8, 128, 8 ) cat_sps_0_ ( .abcat(  vlc128_sps_nal_int[4]  ), .a(  vlc128_sps_nal_int[0]  ), .b( vlc128_sps_nal_int[1] ) );
     vlc_cat #( 36,  31,  5, 128, 8, 128, 8 ) cat_sps_1_ ( .abcat(  vlc128_sps_nal_int[5]  ), .a(  vlc128_sps_nal_int[2]  ), .b( vlc128_sps_nal_int[3] ) );
     vlc_cat #(139, 103, 36, 128, 8, 256, 8 ) cat_sps_2_ ( .abcat(  vlc256_sps_nal         ), .a(  vlc128_sps_nal_int[4]  ), .b( vlc128_sps_nal_int[5] ) );
 
    //////////////////////////////////////////////////////
    // 'h10: PPS
    //////////////////////////////////////////////////////

    logic [263:0] vlc128_pps_nal;

    // 32 : 0x00 0x00 0x00 0x01
    //  8 : 0_01_01000 = 0x 28 = nal unit header PPS
    //  2 : 1_1 = UE(PPSid=0), UE(SPSid=0)
    //  2 : 0_0 = entropy, bot feild poc
    //  5 : 1_010_1 = UE(0), UE(num_refix_minus1=1), UE(0)
    //  3 : 0_00 = weighted pred flag=0 and bipred_idc=0
    //  3 : 1_1_1 = SE(pic_init_qp_minus26=0), SE(pic_init_qs_minus26=0), SE(chroma_qp_index_offset=0)
    //  3 : 1_0_0 = deblock control present=1, constrained intra = 0, redundant pic cnt present = 0;
    //  1 : 1_ : rbsp stop bit  
    // --
    // 59
    assign vlc128_pps_nal[263:135] = {59{1'b1}};
    assign vlc128_pps_nal[134:  8] = { 40'h00_00_00_01_28, 19'b1_1_0_0_1_010_1_0_00_1_1_1_1_0_0_1 };
    assign vlc128_pps_nal[  7:  0] = 'd59 ;
    
    //////////////////////////////////////////////////////
    // 'h20: GREY_IDC_SLICE_HEADER
    //////////////////////////////////////////////////////
    
    logic [263:0] vlc128_grey_slice;
 
    assign vlc128_grey_slice[263:135] = {52{1'b1}};
    assign vlc128_grey_slice[134:  8] = 'h00_00_01_25_b8_41_A;
    assign vlc128_grey_slice[  7:  0] = 'd52;
    
    //////////////////////////////////////////////////////
    // 'h21: GREY_MACROBLOCK - Intra16, dc, cbp=0, qpd=0, no dc coeff.
    //////////////////////////////////////////////////////

    logic [ 71:0] vlc32_grey_intra;
    
    // _00100_ intra16 dc with cbp=0
    // _1_ chroma dc pred,
    // _1_ dqp=00, 
    // _1_=no chroma dc coeffs
    assign vlc32_grey_intra[71:40] = 'hff;
    assign vlc32_grey_intra[39: 8] = 'b00100_1_1_1;
    assign vlc32_grey_intra[ 7: 0] = 'd8;
    
    //////////////////////////////////////////////////////
    // 'h22: RBSP_STOP_ONE_BIT_INTRA
    //////////////////////////////////////////////////////
   
    logic [ 71:0] vlc32_stop_intra;
    
    assign vlc32_stop_intra[71:40] = 1;
    assign vlc32_stop_intra[39: 8] = 1;
    assign vlc32_stop_intra[ 7: 0] = 1;
    
    //////////////////////////////////////////////////////
    // 'h30: SKIP_FRAME( frame_num, mb_width, mb_height, disable_deblocking_filter_idc )
    //////////////////////////////////////////////////////

    logic [263:0] vlc128_skip_frame;
    logic [263:0] vlc128_skip_frame_int[2];

    // 24 : 0x00 0x00 0x01 startcode
    //  8 : 0_01_00001 = 0x21 nal unit header
    //  3 : 1_1_1 = first_mb_in_slice=UE(0), slice_type=UE(0) (P), pic_param_set=UE(0)
    //  4 : U(4, frame_num )
    //  4 : U(4, pic_order_cnt = frame_num )
    //  4 : 0_0_0_1 = ref_idx_override, pic_list_mod, adaptive pic_marking, slice_qp_delta=UE(0)
    //  3 : 010 = UE( disable_deblocking_filter_idc = 1 ) 
    // --
    // 50
    assign vlc128_skip_frame_int[0][263:135] = {50{1'b1}};
    assign vlc128_skip_frame_int[0][134:  8] = { 32'h00_00_00_01_21, 3'b1_1_1, frame_num[3:0], poc_lsb[3:0], 7'b0_0_0_1_010 };
    assign vlc128_skip_frame_int[0][  7:  0] = 'd50;
   
    // UE ( mb_width * mb_height )
    // 1_ : rbsp stop bit   
    assign vlc128_skip_frame_int[1][263:135] = { GG_UE_MASK( frame_mb_plus1 ), 1'b1 };
    assign vlc128_skip_frame_int[1][134:  8] = { frame_mb_plus1, 1'b1 };
    assign vlc128_skip_frame_int[1][  7:  0] =   GG_UE_LEN(  frame_mb_plus1 ) + 1;
     
    // Put together phrase
     vlc_cat #(114,  50, 64, 128, 8, 128, 8 ) cat_skf_0_ ( .abcat(  vlc128_skip_frame ), .a(  vlc128_skip_frame_int[0]  ), .b( vlc128_skip_frame_int[1] ) );

    //////////////////////////////////////////////////////
    // 'h40: P_FRAME_SLICE_HEADER ( frame_num, deblock_flag, dqp )
    //////////////////////////////////////////////////////

    logic [263:0] vlc128_slice_hdr;
    logic [263:0] vlc128_slice_hdr_int[2];

    // 24 : 0x00 0x00 0x01 startcode
    //  8 : 0_01_00001 = 0x21 nal unit header
    //  3 : 1_1_1 = first_mb_in_slice=UE(0), slice_type=UE(0) (P), pic_param_set=UE(0)
    //  4 : U(4, frame_num )
    //  4 : U(4, pic_order_cnt = frame_num )
    //  3 : 0_0_0 = ref_idx_override, pic_list_mod, adaptive pic_marking
    // --
    // 46
    assign vlc128_slice_hdr_int[0][263:135] = {46{1'b1}};
    assign vlc128_slice_hdr_int[0][134:  8] = { 32'h00_00_01_21, 3'b1_1_1, frame_num[3:0], poc_lsb[3:0], 3'b0_0_0 };
    assign vlc128_slice_hdr_int[0][  7:  0] = 'd46;
    
    // SE( dqp )
    // 010_ = UE( disable_deblocking_filter_idc = 1 ) 
    assign vlc128_slice_hdr_int[1][263:135] = { GG_UE_MASK( dqp_code_plus1 ), 3'b111 };
    assign vlc128_slice_hdr_int[1][134:  8] = { GG_UE_BITS( dqp_code_plus1 ), 3'b010 };
    assign vlc128_slice_hdr_int[1][  7:  0] =   GG_UE_LEN(  dqp_code_plus1 ) + 3;

    // Put together phrase
     vlc_cat #(80,  46, 34, 128, 8, 128, 8 ) cat_shi_0_ ( .abcat(  vlc128_slice_hdr ), .a(  vlc128_slice_hdr_int[0]  ), .b( vlc128_slice_hdr_int[1] ) );

    //////////////////////////////////////////////////////
    // 'h41: PCM_MACROBLOCK_INTER( skip_run )
    //////////////////////////////////////////////////////

    logic [ 71:0] vlc32_ipcm_inter;

    // UE ( skip_run )
    // 0000_1_1111 : UE(30) - pcm mb
    assign vlc32_ipcm_inter[71:40] = { GG_UE_MASK( skip_run_plus1 ), {9{1'b1}} };
    assign vlc32_ipcm_inter[39: 8] = { skip_run_plus1, 9'b0000_1_1111 };
    assign vlc32_ipcm_inter[ 7: 0] =   GG_UE_LEN(  skip_run_plus1 ) + 9;
    // <align> 
    
    //////////////////////////////////////////////////////
    // 'h42: P16_MACROBLOCK( skip_run, refidx, cbp, dqp )
    //////////////////////////////////////////////////////

    logic [263:0] vlc128_p16_0_0_mb;
    logic [263:0] vlc128_p16_0_0_mb_int[4];

    // UE( skip_run )
    // 1_ = UE(mbtype=0) - P16x16
    // TE( refidx ) // Just complement of refidx
    // 1_1 = SE(dx=0), SE(dy=0)
    assign vlc128_p16_0_0_mb_int[0][263:135] = { GG_UE_MASK( skip_run_plus1 ), 3'b111 };
    assign vlc128_p16_0_0_mb_int[0][134:  8] = { GG_UE_BITS( skip_run_plus1 ), 1'b1, refidx^1, 1'b1 };
    assign vlc128_p16_0_0_mb_int[0][  7:  0] =   GG_UE_LEN(  skip_run_plus1 ) + 3;
    
    // ME( cbp )
    assign vlc128_p16_0_0_mb_int[1][263:135] = GG_UE_MASK( cbp_code_plus1 );
    assign vlc128_p16_0_0_mb_int[1][134:  8] = GG_UE_BITS( cbp_code_plus1 );
    assign vlc128_p16_0_0_mb_int[1][  7:  0] = GG_UE_LEN(  cbp_code_plus1 );
    
    // SE( qps ), present only if cbp != 0;
    assign vlc128_p16_0_0_mb_int[2][263:135] = ( |cbp ) ? GG_UE_MASK( dqp_code_plus1 ) : 0;
    assign vlc128_p16_0_0_mb_int[2][134:  8] = ( |cbp ) ? GG_UE_MASK( dqp_code_plus1 ) : 0;
    assign vlc128_p16_0_0_mb_int[2][  7:  0] = ( |cbp ) ? GG_UE_LEN(  dqp_code_plus1 ) : 0;

    // Put together phrase
     vlc_cat #(80,  46, 34, 128, 8, 128, 8 ) cat_p16_0_ ( .abcat(  vlc128_p16_0_0_mb_int[3] ), .a(  vlc128_p16_0_0_mb_int[0]  ), .b( vlc128_p16_0_0_mb_int[1] ) );
     vlc_cat #(80,  46, 34, 128, 8, 128, 8 ) cat_p16_2_ ( .abcat(  vlc128_p16_0_0_mb )       , .a(  vlc128_p16_0_0_mb_int[3]  ), .b( vlc128_p16_0_0_mb_int[2] ) );

       
    //////////////////////////////////////////////////////
    // 'h43: RBSP_STOP_ONE_BIT_INTER( skip_run ) - for end of frame skip run
    //////////////////////////////////////////////////////
 
     logic [ 71:0] vlc32_stop_inter;
     
    // UE ( skip_run )
    // 1 : rbsp stop bit  
    assign vlc32_stop_inter[71:40] = { GG_UE_MASK( skip_run_plus1 ), 1'b1 };
    assign vlc32_stop_inter[39: 8] = { skip_run_plus1, 1'b1 };
    assign vlc32_stop_inter[ 7: 0] = GG_UE_LEN( skip_run_plus1 ) + 1;
    
    //////////////////////////////////////////////////////
    // Output VLC Mux
    //////////////////////////////////////////////////////

    logic [1044:0] omux;
    always_comb begin
        unique case( phrase_sel[7:0] )
            8'h00 : begin omux = { 1'b0, 4'b0111, 256'b0, vlc256_sps_nal[   519:264], 256'b0, vlc256_sps_nal[   263:8], 8'b0, vlc256_sps_nal[   7:0] }; end    
            8'h10 : begin omux = { 1'b0, 4'b0111, 384'b0, vlc128_pps_nal[   263:136], 384'b0, vlc128_pps_nal[   135:8], 8'b0, vlc128_pps_nal[   7:0] }; end    
            8'h20 : begin omux = { 1'b0, 4'b0111, 384'b0, vlc128_grey_slice[263:136], 384'b0, vlc128_grey_slice[135:8], 8'b0, vlc128_grey_slice[7:0] }; end    
            8'h21 : begin omux = { 1'b0, 4'b0000, 480'b0, vlc32_grey_intra[  71:40 ], 480'b0, vlc32_grey_intra[  39:8], 8'b0, vlc32_grey_intra[ 7:0] }; end
            8'h22 : begin omux = { 1'b1, 4'b0000, 480'b0, vlc32_stop_intra[  71:40 ], 480'b0, vlc32_stop_intra[  39:8], 8'b0, vlc32_stop_intra[ 7:0] }; end
            8'h30 : begin omux = { 1'b1, 4'b0111, 384'b0, vlc128_skip_frame[263:136], 384'b0, vlc128_skip_frame[135:8], 8'b0, vlc128_skip_frame[7:0] }; end    
            8'h40 : begin omux = { 1'b0, 4'b0111, 384'b0, vlc128_slice_hdr[ 263:136], 384'b0, vlc128_slice_hdr[ 135:8], 8'b0, vlc128_slice_hdr[ 7:0] }; end    
            8'h41 : begin omux = { 1'b1, 4'b0000, 480'b0, vlc32_ipcm_inter[  71:40 ], 480'b0, vlc32_ipcm_inter[  39:8], 8'b0, vlc32_ipcm_inter[ 7:0] }; end    
            8'h42 : begin omux = { 1'b0, 4'b0000, 480'b0, vlc128_p16_0_0_mb[ 71:40 ], 480'b0, vlc128_p16_0_0_mb[ 39:8], 8'b0, vlc128_p16_0_0_mb[7:0] }; end
            8'h43 : begin omux = { 1'b1, 4'b0000, 480'b0, vlc32_stop_inter[  71:40 ], 480'b0, vlc32_stop_inter[  39:8], 8'b0, vlc32_stop_inter[ 7:0] }; end
            8'h50 : begin omux = { 1'b0, 4'b0000, 384'h0, {128{1'b1}}               , 384'h0,     pcm_byte_data[127:0], 8'b0,                 8'd128 }; end
            8'h60 : begin omux = { 1'b0, 4'b0000, transform_block }; end
        endcase
    end
    
    //////////
    // DONE
    //////////
   
    assign vlc512_phrase = omux[1039:0];
    assign vlc512_byte_align = omux[1044]; // Indicates byte alignment after the vlc is emitted
    assign vlc512_startcode_mark = omux[1043:1040]; // indicates given byte is part of a startcode

endmodule




