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


module gg_lexicon
   #(
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16
    )
    (
    input  logic clk,
    input  logic [7:0] phrase_sel,
    input  logic [3:0] frame_num,
    input  logic [15:0] mb_width,
    input  logic [15:0] mb_height,
    input  logic [3:0] alpha_offset,
    input  logic [3:0] beta_offset,
    input  logic [1:0] disable_deblocking_filter_idc,
    input  logic [23:0] skip_run,
    input  logic [5:0] dqp, // delta QP -26 to +25
    output logic [1039:0] vlc512_phrase,
    output logic vlc512_byte_align, // Indicates byte alignment after the vlc is emitted
    output logic [3:0] vlc512_startcode_mark // indicates given byte is part of a startcode
    );

    //////////////////////////////////////////////////////
    // 'h00: SPS( level, width, height )
    //////////////////////////////////////////////////////

    // 0x00 0x00 0x00 0x01
    // 0_01_00111 = 0x 27 = nal unit header PPS
    // 0x66 - profile_idc
    // 11100000_ - constraint flags, reserve zero 2bits
    // U(8, level)
    // 1_1_1 = UE(seq_parameter_set_id=0), UE(log2_max_frame_num_minus4=0), UE(pic_order_cnt_type=0)
    // 1_011_1 = UE(log2_max_pic_order_cnt_lsb_minus4=0), UE(max_num_ref_frames=2), gaps_in_frame_num_value_allowed_flag=1
    // UE( mb_width - 1 );
    // UE( mb_height - 1 );
    // 1_0_0_0 = frame_mbs_only_flag=1, direct_8x8_inference_flag=0, frame_cropping_flag=0, vui_parameters_present_flag
    // 1_ : rbsp stop bit     
    // <align> 
    
    //////////////////////////////////////////////////////
    // 'h10: PPS
    //////////////////////////////////////////////////////

    // 0x00 0x00 0x00 0x01
    // 0_01_01000 = 0x 28 = nal unit header PPS
    // 1_1 = UE(PPSid=0), UE(SPSid=0)
    // 0_0 = entropy, bot feild poc
    // 1_010_1 = UE(0), UE(num_refix_minus1=1), UE(0)
    // 0_00 = weighted pred flag=0 and bipred_idc=0
    // 1_1_1 = SE(pic_init_qp_minus26=0), SE(pic_init_qs_minus26=0), SE(chroma_qp_index_offset=0)
    // 1_0_0 = deblock control present=1, constrained intra = 0, redundant pic cnt present = 0;
    // 1_ : rbsp stop bit     
    // <align> 
    
    //////////////////////////////////////////////////////
    // 'h20: GREY_IDC_SLICE_HEADER
    //////////////////////////////////////////////////////
    
    logic [135:0] vlc64_grey_idc_header;
    
    assign vlc64_grey_idc_header = { 64'hffff_ffff_ffff_f, 64'h00_00_01_25_b8_41_A, 8'd52 };
    
    //////////////////////////////////////////////////////
    // 'h21: GREY_MACROBLOCK - Intra16, dc, cbp=0, qpd=0, no dc coeff.
    //////////////////////////////////////////////////////
    
    logic [71:0] vlc32_grey_macroblock;
    // _00100_ intra16 dc with cbp=0
    // _1_ chroma dc pred,
    // _1_ dqp=00, 
    // _1_=no chroma dc coeffs
    assign vlc32_grey_macroblock = { 32'hff, 32'b00100_1_1_1, 8'd8 }; 
    
    //////////////////////////////////////////////////////
    // 'h22: RBSP_STOP_ONE_BIT_INTRA
    //////////////////////////////////////////////////////
    
    logic [71:0] vlc32_rbsp_stop_intra;
    assign vlc32_rbsp_stop_intra = { 32'h1, 32'b1, 8'd1 }; 
    // <align> 
    
    //////////////////////////////////////////////////////
    // 'h30: SKIP_FRAME( frame_num, mb_width, mb_height, disable_deblocking_filter_idc )
    //////////////////////////////////////////////////////

    // 0x00 0x00 0x01 startcode
    // 0_01_00001 = 0x21 nal unit header
    // 1_1_1 = first_mb_in_slice=UE(0), slice_type=UE(0) (P), pic_param_set=UE(0)
    // U(4, frame_num )
    // U(4, pic_order_cnt = frame_num )
    // 0_0_0_1 = ref_idx_override, pic_list_mod, adaptive pic_marking, slice_qp_delta=UE(0)
    // 010 = UE( disable_deblocking_filter_idc = 1 ) 
    // UE ( mb_width * mb_height )
    // 1_ : rbsp stop bit     
    // <align> 

    //////////////////////////////////////////////////////
    // 'h40: P_FRAME_SLICE_HEADER ( frame_num, deblock_flag, dqp )
    //////////////////////////////////////////////////////

    // 0x00 0x00 0x01 startcode
    // 0_01_00001 = 0x21 nal unit header
    // 1_1_1 = first_mb_in_slice=UE(0), slice_type=UE(0) (P), pic_param_set=UE(0)
    // U(4, frame_num )
    // U(4, pic_order_cnt = frame_num )
    // 0_0_0 = ref_idx_override, pic_list_mod, adaptive pic_marking
    // SE( dqp )
    // 010_ = UE( disable_deblocking_filter_idc = 1 ) 

    //////////////////////////////////////////////////////
    // 'h41: PCM_MACROBLOCK_INTER( skip_run )
    //////////////////////////////////////////////////////

    // UE ( skip_run )
    // 0000_1_1111 : UE(30) - pcm mb
    // <align> 
    
    //////////////////////////////////////////////////////
    // 'h42: P16_MACROBLOCK( skip_run, refidx, cbp, dqp )
    //////////////////////////////////////////////////////

    // UE( skip_run )
    // 1_ = UE(mbtype=0) - P16x16
    // TE( refidx )
    // 1_1 = SE(dx=0), SE(dy=0)
    // ME( cbp )
    // SE( qps ), present only if cbp != 0;
       
    //////////////////////////////////////////////////////
    // 'h43: RBSP_STOP_ONE_BIT_INTER( skip_run ) - for end of frame skip run
    //////////////////////////////////////////////////////
    
    // UE ( skip_run )
    // 1 : rbsp stop bit     
    // <align> 
    
    //////////
    // DONE
    //////////
endmodule




