// test1.cpp : This file contains the 'main' function. Program execution begins and ends there.
//

#define _CRT_SECURE_NO_WARNINGS 1
#include <stdio.h>
#include "gg_process.h"
#include "gg_deblock.h"

#define PIC_WIDTH 720
#define PIC_HEIGHT 480

int mb_width = PIC_WIDTH>>4;
int mb_height = PIC_HEIGHT>>4;

// Parameters 
int disable_deblocking_filter_idc = 1; // 0-enable, 1-disable, 2-disable across slices boundaries
int pintra_disable_deblocking_filter_idc = 0; // pintra frames :0-enable, 1-disable, 2-disable across slices boundaries
int filterOffsetA = 0;
int filterOffsetB = 0;

FILE* ggo_fp;
int ggo_bitpos;
char ggo_char;
int ggo_obc;

int ggo_frame;
int ggo_intra_col;

int ggo_prev_zero; // count of previous zero's

DeblockCtx dbp; // Deblock private data

// orig image
FILE* ggi_fp;
char ggi_y[1920 * 1088];
char ggi_cb[1920 * 1088 / 4];
char ggi_cr[1920 * 1088 / 4];
// recon image
FILE* ggo_recon_fp;
char ggo_recon_y[1920 * 1088];
char ggo_recon_cb[1920 * 1088 / 4];
char ggo_recon_cr[1920 * 1088 / 4];
// Reference pictures
char ggo_ref_y[2][1920 * 1088];
char ggo_ref_cb[2][1920 * 1088 / 4];
char ggo_ref_cr[2][1920 * 1088 / 4];
// recon stats
char recon_mb_stat[3][1920 * 1088 / 256];    // 0-qp, 1-refidx, 2-pcm
char recon_nz_y[1920 * 1088 / 16];  // non-zero coeffs in blk
char recon_nz_cb[1920 * 1088 / 64];
char recon_nz_cr[1920 * 1088 / 64];




void ggo_init(const char* name)
{
    ggo_fp = fopen(name, "wb");
    ggo_bitpos = 0;
    ggo_char = 0;
    ggo_obc  = 0;
    ggo_frame = 0;
    ggo_prev_zero = 0;
    ggo_intra_col = 0;
}





void ggo_close()
{
    fclose(ggo_fp);
}

void ggo_emulation_prev_putc( char obyte )
{
    if (ggo_prev_zero == 2 && obyte <= 3) {
        fputc(0x03, ggo_fp); // emulation prevention
        ggo_obc++;
        ggo_prev_zero = 0;
        printf("*EMU* ");
    }
    fputc(obyte, ggo_fp);
//    printf("%02x ", obyte & 0xff);
    if (obyte == 0)
        ggo_prev_zero++;
    else
        ggo_prev_zero = 0;
    ggo_obc++;
}

void ggo_putbit(int bit)
{
    int pos;
    pos = (ggo_bitpos == 0) ? 7 : ggo_bitpos - 1;
    ggo_char |= ((bit!=0)?1:0) << pos;
    if (pos == 0) {
        ggo_emulation_prev_putc( ggo_char );
        ggo_char = 0;
    }
    ggo_bitpos = pos;
}

void ggo_align()
{
    if (ggo_bitpos != 0) {
        ggo_emulation_prev_putc(ggo_char);
        ggo_bitpos = 0;
    }
    ggo_char = 0;
}

void ggo_pcm_putbyte(char val)
{
    //assumes alignment, and no pcm zero's allowed by profile
    fputc((val == 0) ? 1 : val, ggo_fp);
    ggo_obc++;
    ggo_bitpos = 0;
    ggo_prev_zero = 0;
}


void ggo_raw_putbits(int val, int len)
{
    for (int ii = 0; ii < len; ii++) {
        ggo_putbit((val >> (len-ii-1)) & 1);
    }
}

void ggo_put_start(int len)
{
    if (ggo_bitpos != 0) {
        printf("ERROR: start code asked for, but bitstream not byte aligned, skipping!!!\n");
    } else {
        printf("\n");
        ggo_bitpos = 0;
        ggo_char = 0;
        fputc(0, ggo_fp); 
        printf("%02x ", 0);
        ggo_obc++;
        fputc(0, ggo_fp); 
        printf("%02x ", 0);
        ggo_obc++;
        if (len == 4) {
            fputc(0, ggo_fp);
            printf("%02x ", 0);
            ggo_obc++;
        }
        fputc(1, ggo_fp); 
        printf("%02x ", 1);
        ggo_obc++;
        ggo_prev_zero = 0; // No emu prev on startcodes
    }
}

void ggo_putbits(int val, int len, const char *desc )
{
    ggo_raw_putbits(val, len);
}

void ggo_put_b8(int val, const char* desc)          { ggo_putbits(val, 8, desc); }

void ggo_put_fn(int val, int len, const char* desc) { ggo_putbits(val, len, desc); }

void ggo_put_in(int val, int len, const char* desc) { ggo_putbits(val, len, desc); }

void ggo_put_un(int val, int len, const char* desc) { ggo_putbits(val, len, desc); }

void ggo_put_ue(int val, const char *desc ) {
    int prefix = 0;
    for (int vv = ((val + 1) >> 1); vv != 0; prefix++) {
        vv = vv >> 1;
    }
    ggo_putbits(0, prefix, desc );
    ggo_raw_putbits(1, 1);
    ggo_raw_putbits(val + 1, prefix);
}


int ggo_put_ue_len(int val ) {
    int prefix = 0;
    for (int vv = ((val + 1) >> 1); vv != 0; prefix++) {
        vv = vv >> 1;
    }
    return(2 * prefix + 1);
}


void ggo_put_se(int val, const char *desc ) { ggo_put_ue((val > 0) ? (val * 2 - 1) : (-2 * val), desc ); }

void ggo_put_te(int val, int max, const char *desc ) {
    if (max == 1) {
        ggo_putbits((val) ? 0 : 1, 1 , desc );
    }
    else {
        ggo_put_ue(val, desc );
    }
}

int ggo_intra4_me[48] = { 3,29,30,17,31,18,37,8,32,38,19,9,20,10,11,2,16,33,34,21,35,22,39,4,36,40,23,5,24,6,7,1,41,42,43,25,44,26,46,12,45,47,27,13,28,14,15,0 };

int ggo_inter_me[48] = { 0,2,3,7,4,8,17,13,5,18,9,14,10,15,16,11,1,32,33,36,34,37,44,40,35,45,38,41,39,42,43,19,6,24,25,20,26,21,46,28,27,47,22,29,23,30,31,12 };


void ggo_put_me(int cbp, int intra4, const char *desc) { ggo_put_ue((intra4) ? ggo_intra4_me[cbp] : ggo_inter_me[cbp], desc); }

void ggo_rbsp_trailing_bits() {
    ggo_putbits(1, 1, "rbsp_stop_one_bit");
    ggo_align();
}

void ggo_put_null(const char* desc) { }

void ggo_sequence_parameter_set() { 
    // Nal unit 
    ggo_put_start(4);
    ggo_put_null("nal_unit( NumBytesInNALunit ) {  ");
    ggo_putbits(0, 1, "forbidden_zero_bit f(1)  ");
    ggo_putbits(1, 2, "nal_ref_idc u(2)         ");
    ggo_putbits(7, 5, "nal_unit_type u(5) 7=SPS ");
    ggo_put_null("}");
    // RBSP
    ggo_put_null("seq_parameter_set_rbsp( ) {");
    ggo_putbits(66, 8, "profile_idc u(8)");
    ggo_putbits( 1, 1, "constraint_set0_flag /* normally equal to 1 */ u(1)");
    ggo_putbits( 1, 1, "constraint_set1_flag /* normally equal to 1 */ u(1)");
    ggo_putbits( 1, 1, "constraint_set2_flag /* normally equal to 1 */ u(1)");
    ggo_putbits( 0, 1, "constraint_set3_flag u(1)");
    ggo_putbits( 0, 1, "constraint_set4_flag /* equal to 0; ignored by decoders */ u(1)");
    ggo_putbits( 0, 1, "constraint_set5_flag /* equal to 0; ignored by decoders */ u(1)");
    ggo_putbits( 0, 2, "reserved_zero_2bits /* equal to 0 */ u(2)");
    ggo_putbits(42, 8, "level_idc u(8)");
    ggo_put_ue ( 0,    "seq_parameter_set_id ue(v)");
    ggo_put_ue ( 0,    "log2_max_frame_num_minus4 ue(v)");
    ggo_put_ue ( 0,    "pic_order_cnt_type ue(v)");
    ggo_put_ue ( 0,    "log2_max_pic_order_cnt_lsb_minus4 ue(v)");
    ggo_put_ue ( 2,    "max_num_ref_frames ue(v)");
    ggo_putbits( 1, 1, "gaps_in_frame_num_value_allowed_flag u(1)");
    ggo_put_ue ( mb_width - 1,    "pic_width_in_mbs_minus1 ue(v)");
    ggo_put_ue ( mb_height- 1,    "pic_height_in_map_units_minus1 ue(v)");
    ggo_putbits( 1, 1, "frame_mbs_only_flag /*equal to 1*/ u(1)");
    ggo_putbits( 0, 1, "direct_8x8_inference_flag u(1)");
    ggo_putbits( 0, 1, "frame_cropping_flag u(1)");
    ggo_putbits( 0, 1, "vui_parameters_present_flag u(1)");
    ggo_rbsp_trailing_bits();
    ggo_put_null("}");
}

void ggo_picture_parameter_set() {
    // Nal unit 
    ggo_put_start(4);
    ggo_put_null("nal_unit( NumBytesInNALunit ) {  ");
    ggo_putbits(0, 1, "forbidden_zero_bit f(1)  ");
    ggo_putbits(1, 2, "nal_ref_idc u(2)         ");
    ggo_putbits(8, 5, "nal_unit_type u(5) 8=PPS ");
    ggo_put_null("}");
    // RBSP
    ggo_put_null("pic_parameter_set_rbsp() {");
    ggo_put_ue ( 0,    "pic_parameter_set_id ue(v)");
    ggo_put_ue ( 0,    "seq_parameter_set_id ue(v)");
    ggo_putbits( 0, 1, "entropy_coding_mode_flag /*equal to zero*/ u(1)");
    ggo_putbits( 0, 1, "bottom_field_pic_order_in_frame_present_flag u(1)");
    ggo_put_ue ( 0,    "num_slice_groups_minus1 /*equal to zero*/ ue(v)");
    ggo_put_ue ( 1,    "num_ref_idx_l0_default_active_minus1 ue(v)");
    ggo_put_ue ( 0,    "num_ref_idx_l1_default_active_minus1 ue(v)");
    ggo_putbits( 0, 1, "weighted_pred_flag /* = 0 */ u(1)");
    ggo_putbits( 0, 2, "weighted_bipred_idc /* = 0 */ u(2)");
    ggo_put_se ( 0,    "pic_init_qp_minus26 /* relative to 26 */ se(v)");
    ggo_put_se ( 0,    "pic_init_qs_minus26 /* relative to 26 */ se(v)");
    ggo_put_se ( 0,    "chroma_qp_index_offset se(v)");
    ggo_putbits( 1, 1, "deblocking_filter_control_present_flag u(1)");
    ggo_putbits( 0, 1, "constrained_intra_pred_flag u(1)");
    ggo_putbits( 0, 1, "redundant_pic_cnt_present_flag /* equal to zero*/ u(1)");
    ggo_rbsp_trailing_bits();
    ggo_put_null("}");
}

void ggo_long_term_grey_idc_slice() {
    // Nal unit 
    ggo_put_start(3);
    ggo_put_null("nal_unit( NumBytesInNALunit ) {  ");
    ggo_putbits(0, 1, "forbidden_zero_bit f(1)  ");
    ggo_putbits(1, 2, "nal_ref_idc u(2)         ");
    ggo_putbits(5, 5, "nal_unit_type u(5) 5=ISlice(IdrPicFlag)");
    ggo_put_null("}");
    // RBSP
    ggo_put_null("slice_header() {");
    ggo_put_ue( 0,    "first_mb_in_slice ue(v)     ");
    ggo_put_ue( 2,    "slice_type ue(v) 2=I Slice  ");
    ggo_put_ue( 0,    "pic_parameter_set_id ue(v)  ");
    ggo_putbits(ggo_frame, 4, "frame_num u(v)              ");
    ggo_put_ue( 0,    "idr_pic_id ue(v)        ");
    ggo_putbits(ggo_frame++, 4, "pic_order_cnt_lsb u(v)      ");

    ggo_put_null("dec_ref_pic_marking() {");
    ggo_putbits( 0, 1, "no_output_of_prior_pics_flag u(1)");
    ggo_putbits( 1, 1, "long_term_reference_flag u(1)");
    ggo_put_null("}");

    ggo_put_se( 0, "slice_qp_delta se(v)        ");
    ggo_put_ue( disable_deblocking_filter_idc , "disable_deblocking_filter_idc ue(v)");
    if (disable_deblocking_filter_idc != 1) {
        ggo_put_se(0, "slice_alpha_c0_offset_div2 se(v)");
        ggo_put_se(0, "slice_beta_offset_div2 se(v)");
    }
    ggo_put_null("}");

    // Macroblocks
    ggo_put_null("slice_data() {");
    for( int mby = 0; mby < mb_height; mby++ )
        for (int mbx = 0; mbx < mb_width; mbx++) {
            ggo_put_null("macroblock_layer() {           ");
            ggo_put_ue (3,    "mb_type ue(v)  3=Intra 16 DC, cbp=0");
            ggo_put_ue (0,    "intra_chroma_pred_mode ue(v) 0=DC  ");
            ggo_put_ue (0,    "mb_qp_delta se(v)              ");
            ggo_putbits(1, 1, "coeff_token ce(v) Luma DC, nC=0, TrailingOnes=0, TotalCeoff=0");
            ggo_put_null("}");
            // write recon
            for (int py = 0; py < 16; py++)
                for (int px = 0; px < 16; px++) {
                    ggo_recon_y[(mby * 16 + py) * mb_width * 16 + mbx * 16 + px] = 128;
                }
            for (int py = 0; py < 8; py++)
                for (int px = 0; px < 8; px++) {
                    ggo_recon_cb[(mby * 8 + py) * mb_width * 8 + mbx * 8 + px] = 128;
                    ggo_recon_cr[(mby * 8 + py) * mb_width * 8 + mbx * 8 + px] = 128;
                }
        }
    ggo_put_null("}");

    // stop slice
    ggo_rbsp_trailing_bits();
    ggo_put_null("}");
    }

void ggo_pskip_slice() {
    // Nal unit 
    ggo_put_start(3);
    ggo_put_null("nal_unit( NumBytesInNALunit ) {  ");
    ggo_putbits(0, 1, "forbidden_zero_bit f(1)  ");
    ggo_putbits(1, 2, "nal_ref_idc u(2)         ");
    ggo_putbits(1, 5, "nal_unit_type u(5) 1=non-idr");
    ggo_put_null("}");
    // RBSP
    ggo_put_null("slice_header() {");
    ggo_put_ue(0, "first_mb_in_slice ue(v)     ");
    ggo_put_ue(0, "slice_type ue(v) 0=P Slice  ");
    ggo_put_ue(0, "pic_parameter_set_id ue(v)  ");
    ggo_putbits(ggo_frame, 4, "frame_num u(v)          "); // Do we have to increment?
    ggo_putbits(ggo_frame++, 4, "pic_order_cnt_lsb u(v)  "); // Do we have to increment
    ggo_putbits(0, 1, "num_ref_idx_active_override_flag u(1)");

    ggo_put_null("ref_pic_list_modification() {");
    ggo_putbits(0, 1, "ref_pic_list_modification_flag_l0 u(1)");
    ggo_put_null("}");

    ggo_put_null("dec_ref_pic_marking() {");
    ggo_putbits(0, 1, "adaptive_ref_pic_marking_mode_flag u(1)");
    ggo_put_null("}");
        
    ggo_put_se(0, "slice_qp_delta se(v)        ");
    ggo_put_ue(disable_deblocking_filter_idc, "disable_deblocking_filter_idc ue(v)");
    if (disable_deblocking_filter_idc != 1) {
        ggo_put_se(0, "slice_alpha_c0_offset_div2 se(v)");
        ggo_put_se(0, "slice_beta_offset_div2 se(v)");
    }
    ggo_put_null("}");

    // Macroblocks
    ggo_put_null("slice_data() {");
    ggo_put_ue(mb_height* mb_width, "mb_skip_run ue(v) skip full frame");
    ggo_put_null("}");

    // stop slice
    ggo_rbsp_trailing_bits();
    ggo_put_null("}");
}

void ggo_ref1_copy_slice() {
    // Nal unit 
    ggo_put_start(3);
    ggo_put_null("nal_unit( NumBytesInNALunit ) {  ");
    ggo_putbits(0, 1, "forbidden_zero_bit f(1)  ");
    ggo_putbits(1, 2, "nal_ref_idc u(2)         ");
    ggo_putbits(1, 5, "nal_unit_type u(5) 1=non-idr");
    ggo_put_null("}");
    // RBSP
    ggo_put_null("slice_header() {");
    ggo_put_ue(0, "first_mb_in_slice ue(v)     ");
    ggo_put_ue(0, "slice_type ue(v) 0=P Slice  ");
    ggo_put_ue(0, "pic_parameter_set_id ue(v)  ");
    ggo_putbits(ggo_frame, 4, "frame_num u(v)          "); 
    ggo_putbits(ggo_frame++, 4, "pic_order_cnt_lsb u(v)  "); 
    ggo_putbits(0, 1, "num_ref_idx_active_override_flag u(1)");

    ggo_put_null("ref_pic_list_modification() {");
    ggo_putbits(0, 1, "ref_pic_list_modification_flag_l0 u(1)");
    ggo_put_null("}");

    ggo_put_null("dec_ref_pic_marking() {");
    ggo_putbits(0, 1, "adaptive_ref_pic_marking_mode_flag u(1)");
    ggo_put_null("}");

    ggo_put_se(0, "slice_qp_delta se(v)        ");
    ggo_put_ue(disable_deblocking_filter_idc, "disable_deblocking_filter_idc ue(v)");
    if (disable_deblocking_filter_idc != 1) {
        ggo_put_se(0, "slice_alpha_c0_offset_div2 se(v)");
        ggo_put_se(0, "slice_beta_offset_div2 se(v)");
    }
    ggo_put_null("}");

    // Macroblocks
    ggo_put_null("slice_data() {");
    for (int yy = 0; yy < mb_height; yy++)
        for (int xx = 0; xx < mb_width; xx++) {
            ggo_put_ue(0, "mb_skip_run ue(v)");
            ggo_put_null("macroblock_layer() {           ");
            ggo_put_ue(0, "mb_type ue(v)  P L0 16x16");
            //mb_pred(mb_type)
            ggo_put_null("mb_pred( mb_type ) {");
            ggo_put_te(1, 1, "ref_idx_l0[mbPartIdx] te(v)");
            ggo_put_se(0, "mvd_l0[ 0 ][ 0 ][ 0 ] se(v)");
            ggo_put_se(0, "mvd_l0[ 0 ][ 0 ][ 1 ] se(v)");
            ggo_put_null("}");
            ggo_put_me(0, 0, "coded_block_pattern me(v)");
            ggo_put_null("}");
        }
    ggo_put_null("}");

    // stop slice
    ggo_rbsp_trailing_bits();
    ggo_put_null("}");
}


void ggo_pcm_slice()
{
    // Nal unit 
    ggo_put_start(3);
    ggo_put_null("nal_unit( NumBytesInNALunit ) {  ");
    ggo_putbits(0, 1, "forbidden_zero_bit f(1)  ");
    ggo_putbits(1, 2, "nal_ref_idc u(2)         ");
    ggo_putbits(1, 5, "nal_unit_type u(5) 5=non_idr");
    ggo_put_null("}");
    // RBSP
    ggo_put_null("slice_header() {");
    ggo_put_ue(0, "first_mb_in_slice ue(v)     ");
    ggo_put_ue(2, "slice_type ue(v) 2=I Slice  ");
    ggo_put_ue(0, "pic_parameter_set_id ue(v)  ");
    ggo_putbits(ggo_frame, 4, "frame_num u(v)              ");
    ggo_putbits(ggo_frame++, 4, "pic_order_cnt_lsb u(v)      ");

    ggo_put_null("dec_ref_pic_marking() {");
    ggo_putbits(0, 1, "adaptive_ref_pic_marking_mode_flag u(1)");
    ggo_put_null("}");

    ggo_put_se(0, "slice_qp_delta se(v)        ");
    ggo_put_ue(disable_deblocking_filter_idc, "disable_deblocking_filter_idc ue(v)");
    if (disable_deblocking_filter_idc != 1) {
        ggo_put_se(0, "slice_alpha_c0_offset_div2 se(v)");
        ggo_put_se(0, "slice_beta_offset_div2 se(v)");
    }
    ggo_put_null("}");

    // Macroblocks
    ggo_put_null("slice_data() {");
    for( int yy = 0; yy < mb_height; yy++ )
        for (int xx = 0; xx < mb_width; xx++) {
            ggo_put_null("macroblock_layer() {");
            ggo_put_ue(25, "mb_type ue(v)");
            ggo_align();
            for (int py = 0; py < 16; py++)
                for (int px = 0; px < 16; px++)
                    ggo_pcm_putbyte(ggi_y[xx * 16 + px + (yy * 16 + py) * mb_width*16]);
            for (int py = 0; py < 8; py++)
                for (int px = 0; px < 8; px++)
                    ggo_pcm_putbyte(ggi_cb[xx * 8 + px + (yy * 8 + py) * mb_width*8 ]);
            for (int py = 0; py < 8; py++)
                for (int px = 0; px < 8; px++)
                    ggo_pcm_putbyte(ggi_cr[xx * 8 + px + (yy * 8 + py) * mb_width*8 ]);
            ggo_put_null("}");
            // Write Recon image
            for (int py = 0; py < 16; py++)
                for (int px = 0; px < 16; px++)
                    ggo_recon_y[xx * 16 + px + (yy * 16 + py) * mb_width * 16] = ggi_y[xx * 16 + px + (yy * 16 + py) * mb_width * 16];
            for (int py = 0; py < 8; py++)
                for (int px = 0; px < 8; px++) {
                    ggo_recon_cb[xx * 8 + px + (yy * 8 + py) * mb_width * 8] = ggi_cb[xx * 8 + px + (yy * 8 + py) * mb_width * 8];
                    ggo_recon_cr[xx * 8 + px + (yy * 8 + py) * mb_width * 8] = ggi_cr[xx * 8 + px + (yy * 8 + py) * mb_width * 8];
                }
        }
    ggo_put_null("}");

    // stop slice
    ggo_rbsp_trailing_bits();
    ggo_put_null("}");

}

void ggo_put_bitbuffer(bitbuffer* bits, const char *desc)
{
    ggo_put_null(desc);
    //printf("%s", desc);
    for( int idx = 0; idx < bits->num; idx++ ) {
    //    printf("(#%d,%x)", bits->vlc[idx].i_size, bits->vlc[idx].i_bits);
        ggo_putbits(bits->vlc[idx].i_bits, bits->vlc[idx].i_size, NULL);
    }
    //printf("\n");
}


/////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////

// Encode a frame using fixed 128 ref frame, mvd 0,0. (e.g. a P-intra block)
// skips are enabled if ref =0. For ref = 1, we could modify the ref pic list, but we want to test this mode
void ggo_inter_0_0_slice( int qp, int refidx, int intra_col_width ) {

    bitbuffer bits_y[16], bits_cb[4], bits_cr[4], bits_dc_cb, bits_dc_cr;
    int bitcount[8];
    int sad, ssd;
    int ref128[16] = { 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 };
    int ref2048[16] = { 2048, 0, 2048, 0, 0, 0, 0, 0, 2048, 0, 2048, 0, 0, 0, 0, 0 };
    int orig_y[16][16], recon_y[16][16], ref_y[16][16];
    int orig_cb[4][16], recon_cb[4][16], ref_cb[4][16];
    int orig_cr[4][16], recon_cr[4][16], ref_cr[4][16];
    int orig_dc_cb[16], recon_dc_cb[16], ref_dc_cb[16];
    int orig_dc_cr[16], recon_dc_cr[16], ref_dc_cr[16];
    int dc_hold[3][16];
    int skip_run = 0;
    int ofs = 0;
    int dz = 0;
    char abvnc_y[PIC_WIDTH >> 2], abvnc_cb[PIC_WIDTH >> 3], abvnc_cr[PIC_WIDTH >> 3];
    char lefnc_y[4], lefnc_cb[2], lefnc_cr[2];
    int num_coeff_y[16], num_coeff_cb[4], num_coeff_cr[4];

    // Nal unit 
    ggo_put_start(3);
    ggo_put_null("nal_unit( NumBytesInNALunit ) {  ");
    ggo_putbits(0, 1, "forbidden_zero_bit f(1)  ");
    ggo_putbits(1, 2, "nal_ref_idc u(2)         ");
    ggo_putbits(1, 5, "nal_unit_type u(5) 1=non-idr");
    ggo_put_null("}");
    // RBSP
    ggo_put_null("slice_header() {");
    ggo_put_ue(0, "first_mb_in_slice ue(v)     ");
    ggo_put_ue(0, "slice_type ue(v) 0=P Slice  ");
    ggo_put_ue(0, "pic_parameter_set_id ue(v)  ");
    ggo_putbits(ggo_frame, 4, "frame_num u(v)          ");
    ggo_putbits(ggo_frame++, 4, "pic_order_cnt_lsb u(v)  ");
    ggo_putbits(0, 1, "num_ref_idx_active_override_flag u(1)");

    ggo_put_null("ref_pic_list_modification() {");
    ggo_putbits(0, 1, "ref_pic_list_modification_flag_l0 u(1)");
    ggo_put_null("}");

    ggo_put_null("dec_ref_pic_marking() {");
    ggo_putbits(0, 1, "adaptive_ref_pic_marking_mode_flag u(1)");
    ggo_put_null("}");

    ggo_put_se( qp - 26, "slice_qp_delta se(v)        "); // assume pps default is 26. qp in {0,51}
    ggo_put_ue(pintra_disable_deblocking_filter_idc, "disable_deblocking_filter_idc ue(v)");
    if (pintra_disable_deblocking_filter_idc != 1) {
        ggo_put_se(0, "slice_alpha_c0_offset_div2 se(v)");
        ggo_put_se(0, "slice_beta_offset_div2 se(v)");
    }
    ggo_put_null("}");

    // Macroblocks
    ggo_put_null("slice_data() {");

    // Clear abvnc
    for (int ii = 0; ii < (PIC_WIDTH >> 2); ii++) {
        abvnc_y[ii] = -1;
    }
    for (int ii = 0; ii < (PIC_WIDTH >> 3); ii++) {
        abvnc_cb[ii] = -1;
        abvnc_cr[ii] = -1;
    }


    // Init Deblock;

    gg_deblock_init( &dbp, pintra_disable_deblocking_filter_idc, filterOffsetA, filterOffsetB, mb_width, mb_height ); // allocate and deblock for start of single slice frame

    // Process frame of macroblocks
    for (int yy = 0; yy < mb_height; yy++) {
        // Clear lefnc 
        for (int ii = 0; ii < 4 ; ii++) {
            lefnc_y[ii] = -1;
        }
        for (int ii = 0; ii < 2; ii++) {
            lefnc_cb[ii] = -1;
            lefnc_cr[ii] = -1;
        }

        for (int xx = 0; xx < mb_width; xx++) {
            int mb_type = 0;
            int cbp = 0;
            int macroblock_layer_length = 0;
            int num_coeff = 0;
            if (intra_col_width)
                refidx = (xx >= ggo_intra_col && xx < ggo_intra_col + intra_col_width) ? 1 : 0;

            //Load Luma orig and ref[refidx]
            for (int by = 0; by < 4; by++)
                for (int bx = 0; bx < 4; bx++)
                    for (int py = 0; py < 4; py++)
                        for (int px = 0; px < 4; px++) {
                            orig_y[by * 4 + bx][py * 4 + px] = 0xff & ggi_y            [xx * 16 + bx * 4 + px + (yy * 16 + by * 4 + py) * mb_width * 16];
                            ref_y [by * 4 + bx][py * 4 + px] = 0xff & ggo_ref_y[refidx][xx * 16 + bx * 4 + px + (yy * 16 + by * 4 + py) * mb_width * 16];
                        }

            // Clear Chroma DC (as will be sparely populated accumulations)
            for (int py = 0; py < 4; py++)
                for (int px = 0; px < 4; px++) {
                    orig_dc_cb[py * 4 + px] = 0;
                    orig_dc_cr[py * 4 + px] = 0;
                    ref_dc_cb[py * 4 + px] = 0;
                    ref_dc_cr[py * 4 + px] = 0;
                }

            // Load Chroma Cb/Cr and accumulate Chroma Dc for orig and ref[refidx]
            for (int by = 0; by < 2; by++)
                for (int bx = 0; bx < 2; bx++)
                    for (int py = 0; py < 4; py++)
                        for (int px = 0; px < 4; px++) {
                            orig_dc_cb[by * 8 + bx * 2] += (orig_cb[by * 2 + bx][py * 4 + px] = 0xff & ggi_cb[xx * 8 + bx * 4 + px + (yy * 8 + by * 4 + py) * mb_width * 8]);
                            orig_dc_cr[by * 8 + bx * 2] += (orig_cr[by * 2 + bx][py * 4 + px] = 0xff & ggi_cr[xx * 8 + bx * 4 + px + (yy * 8 + by * 4 + py) * mb_width * 8]);
                            ref_dc_cb[by * 8 + bx * 2] += (ref_cb[by * 2 + bx][py * 4 + px] = 0xff & ggo_ref_cb[refidx][xx * 8 + bx * 4 + px + (yy * 8 + by * 4 + py) * mb_width * 8]);
                            ref_dc_cr[by * 8 + bx * 2] += (ref_cr[by * 2 + bx][py * 4 + px] = 0xff & ggo_ref_cr[refidx][xx * 8 + bx * 4 + px + (yy * 8 + by * 4 + py) * mb_width * 8]);
                        }

            if (yy == 0 && xx == 0) {
                printf("\nmark\n");
            }
            // Luma UL
            num_coeff = 0;
            num_coeff += num_coeff_y[0] = gg_process_block(qp, ofs, dz, ref_y[0], orig_y[0], dc_hold[0], 0, 0, lefnc_y, abvnc_y + xx * 4, recon_y[0], &bits_y[0], &bitcount[0], &sad, &ssd);
            num_coeff += num_coeff_y[1] = gg_process_block(qp, ofs, dz, ref_y[1], orig_y[1], dc_hold[0], 0, 1, lefnc_y, abvnc_y + xx * 4, recon_y[1], &bits_y[1], &bitcount[1], &sad, &ssd);
            num_coeff += num_coeff_y[2] = gg_process_block(qp, ofs, dz, ref_y[4], orig_y[4], dc_hold[0], 0, 2, lefnc_y, abvnc_y + xx * 4, recon_y[4], &bits_y[2], &bitcount[2], &sad, &ssd);
            num_coeff += num_coeff_y[3] = gg_process_block(qp, ofs, dz, ref_y[5], orig_y[5], dc_hold[0], 0, 3, lefnc_y, abvnc_y + xx * 4, recon_y[5], &bits_y[3], &bitcount[3], &sad, &ssd);
            cbp |= (num_coeff) ? 1 : 0;
            macroblock_layer_length += (num_coeff) ? (bitcount[0] + bitcount[1] + bitcount[2] + bitcount[3]) : 0;
            // Luma UR
            num_coeff = 0;
            num_coeff += num_coeff_y[4] = gg_process_block(qp, ofs, dz, ref_y[2], orig_y[2], dc_hold[0], 0, 4, lefnc_y, abvnc_y + xx * 4, recon_y[2], &bits_y[4], &bitcount[0], &sad, &ssd);
            num_coeff += num_coeff_y[5] = gg_process_block(qp, ofs, dz, ref_y[3], orig_y[3], dc_hold[0], 0, 5, lefnc_y, abvnc_y + xx * 4, recon_y[3], &bits_y[5], &bitcount[1], &sad, &ssd);
            num_coeff += num_coeff_y[6] = gg_process_block(qp, ofs, dz, ref_y[6], orig_y[6], dc_hold[0], 0, 6, lefnc_y, abvnc_y + xx * 4, recon_y[6], &bits_y[6], &bitcount[2], &sad, &ssd);
            num_coeff += num_coeff_y[7] = gg_process_block(qp, ofs, dz, ref_y[7], orig_y[7], dc_hold[0], 0, 7, lefnc_y, abvnc_y + xx * 4, recon_y[7], &bits_y[7], &bitcount[3], &sad, &ssd);
            cbp |= (num_coeff) ? 2 : 0;
            macroblock_layer_length += (num_coeff) ? (bitcount[0] + bitcount[1] + bitcount[2] + bitcount[3]) : 0;
            // Luma LL
            num_coeff = 0;
            num_coeff += num_coeff_y[8] = gg_process_block(qp, ofs, dz, ref_y[8], orig_y[8], dc_hold[0], 0, 8, lefnc_y, abvnc_y + xx * 4, recon_y[8], &bits_y[8], &bitcount[0], &sad, &ssd);
            num_coeff += num_coeff_y[9] = gg_process_block(qp, ofs, dz, ref_y[9], orig_y[9], dc_hold[0], 0, 9, lefnc_y, abvnc_y + xx * 4, recon_y[9], &bits_y[9], &bitcount[1], &sad, &ssd);
            num_coeff += num_coeff_y[10]= gg_process_block(qp, ofs, dz, ref_y[12], orig_y[12], dc_hold[0], 0, 10, lefnc_y, abvnc_y + xx * 4, recon_y[12], &bits_y[10], &bitcount[2], &sad, &ssd);
            num_coeff += num_coeff_y[11]= gg_process_block(qp, ofs, dz, ref_y[13], orig_y[13], dc_hold[0], 0, 11, lefnc_y, abvnc_y + xx * 4, recon_y[13], &bits_y[11], &bitcount[3], &sad, &ssd);
            cbp |= (num_coeff) ? 4 : 0;
            macroblock_layer_length += (num_coeff) ? (bitcount[0] + bitcount[1] + bitcount[2] + bitcount[3]) : 0;
            // Luma LR
            num_coeff = 0;
            num_coeff += num_coeff_y[12] = gg_process_block(qp, ofs, dz, ref_y[10], orig_y[10], dc_hold[0], 0, 12, lefnc_y, abvnc_y + xx * 4, recon_y[10], &bits_y[12], &bitcount[0], &sad, &ssd);
            num_coeff += num_coeff_y[13] = gg_process_block(qp, ofs, dz, ref_y[11], orig_y[11], dc_hold[0], 0, 13, lefnc_y, abvnc_y + xx * 4, recon_y[11], &bits_y[13], &bitcount[1], &sad, &ssd);
            num_coeff += num_coeff_y[14] = gg_process_block(qp, ofs, dz, ref_y[14], orig_y[14], dc_hold[0], 0, 14, lefnc_y, abvnc_y + xx * 4, recon_y[14], &bits_y[14], &bitcount[2], &sad, &ssd);
            num_coeff += num_coeff_y[15] = gg_process_block(qp, ofs, dz, ref_y[15], orig_y[15], dc_hold[0], 0, 15, lefnc_y, abvnc_y + xx * 4, recon_y[15], &bits_y[15], &bitcount[3], &sad, &ssd);
            cbp |= (num_coeff) ? 8 : 0;
            macroblock_layer_length += (num_coeff) ? (bitcount[0] + bitcount[1] + bitcount[2] + bitcount[3]) : 0;


            // chroma DC
            num_coeff = 0;
            num_coeff += gg_process_block(qp, ofs, dz, &(ref_dc_cb[0]), &(orig_dc_cb[0]), &(dc_hold[1][0]), 4, 0, lefnc_cb, abvnc_cb + xx * 2, &(recon_dc_cb[0]), &bits_dc_cb, &bitcount[0], &sad, &ssd);
            num_coeff += gg_process_block(qp, ofs, dz, &(ref_dc_cr[0]), &(orig_dc_cr[0]), &(dc_hold[2][0]), 5, 0, lefnc_cr, abvnc_cr + xx * 2, &(recon_dc_cr[0]), &bits_dc_cr, &bitcount[1], &sad, &ssd);
            cbp |= (num_coeff) ? 0x10 : 0;
            macroblock_layer_length += (num_coeff) ? (bitcount[0] + bitcount[1]) : 0;
            // chroma AC
            num_coeff = 0;
            num_coeff += num_coeff_cb[0] = gg_process_block(qp, ofs, dz, &(ref_cb[0][0]), &(orig_cb[0][0]), &(dc_hold[1][0]), 2, 0, lefnc_cb, abvnc_cb + xx * 2, &(recon_cb[0][0]), &bits_cb[0], &bitcount[0], &sad, &ssd);
            num_coeff += num_coeff_cb[1] = gg_process_block(qp, ofs, dz, &(ref_cb[1][0]), &(orig_cb[1][0]), &(dc_hold[1][0]), 2, 1, lefnc_cb, abvnc_cb + xx * 2, &(recon_cb[1][0]), &bits_cb[1], &bitcount[1], &sad, &ssd);
            num_coeff += num_coeff_cb[2] = gg_process_block(qp, ofs, dz, &(ref_cb[2][0]), &(orig_cb[2][0]), &(dc_hold[1][0]), 2, 2, lefnc_cb, abvnc_cb + xx * 2, &(recon_cb[2][0]), &bits_cb[2], &bitcount[2], &sad, &ssd);
            num_coeff += num_coeff_cb[3] = gg_process_block(qp, ofs, dz, &(ref_cb[3][0]), &(orig_cb[3][0]), &(dc_hold[1][0]), 2, 3, lefnc_cb, abvnc_cb + xx * 2, &(recon_cb[3][0]), &bits_cb[3], &bitcount[3], &sad, &ssd);
            num_coeff += num_coeff_cr[0] = gg_process_block(qp, ofs, dz, &(ref_cr[0][0]), &(orig_cr[0][0]), &(dc_hold[2][0]), 3, 0, lefnc_cr, abvnc_cr + xx * 2, &(recon_cr[0][0]), &bits_cr[0], &bitcount[4], &sad, &ssd);
            num_coeff += num_coeff_cr[1] = gg_process_block(qp, ofs, dz, &(ref_cr[1][0]), &(orig_cr[1][0]), &(dc_hold[2][0]), 3, 1, lefnc_cr, abvnc_cr + xx * 2, &(recon_cr[1][0]), &bits_cr[1], &bitcount[5], &sad, &ssd);
            num_coeff += num_coeff_cr[2] = gg_process_block(qp, ofs, dz, &(ref_cr[2][0]), &(orig_cr[2][0]), &(dc_hold[2][0]), 3, 2, lefnc_cr, abvnc_cr + xx * 2, &(recon_cr[2][0]), &bits_cr[2], &bitcount[6], &sad, &ssd);
            num_coeff += num_coeff_cr[3] = gg_process_block(qp, ofs, dz, &(ref_cr[3][0]), &(orig_cr[3][0]), &(dc_hold[2][0]), 3, 3, lefnc_cr, abvnc_cr + xx * 2, &(recon_cr[3][0]), &bits_cr[3], &bitcount[7], &sad, &ssd);
            cbp = (num_coeff) ? 0x20 | (cbp & 0xf) : cbp;
            macroblock_layer_length += (num_coeff) ? (bitcount[0] + bitcount[1] + bitcount[2] + bitcount[3] +
                bitcount[4] + bitcount[5] + bitcount[6] + bitcount[7]) : 0;
            macroblock_layer_length += 5; // adjust length +5 for: mbtype, refidx, mvdxm mvdy, qpd
            macroblock_layer_length += ggo_put_ue_len(ggo_inter_me[cbp]); // add CBP length

            // Now and only now, we can nominally code the macroblock, skips not possible when ref1 is used
            if (refidx == 0 && cbp == 0) { // skip this MB if ref=0 and cbp=0
                mb_type = GG_MBTYPE_SKIP;
                skip_run++;
                // Write Recon
                for (int py = 0; py < 16; py++)
                    for (int px = 0; px < 16; px++)
                        ggo_recon_y[xx * 16 + px + (yy * 16 + py) * mb_width * 16] = 0xff & ggo_ref_y[refidx][xx * 16 + px + (yy * 16 + py) * mb_width * 16];
                for (int py = 0; py < 8; py++)
                    for (int px = 0; px < 8; px++) {
                        ggo_recon_cb[xx * 8 + px + (yy * 8 + py) * mb_width * 8] = 0xff & ggo_ref_cb[refidx][xx * 8 + px + (yy * 8 + py) * mb_width * 8];
                        ggo_recon_cr[xx * 8 + px + (yy * 8 + py) * mb_width * 8] = 0xff & ggo_ref_cr[refidx][xx * 8 + px + (yy * 8 + py) * mb_width * 8];
                    }
                // Force nC to zero, in case this skip decision was forced
                lefnc_y[0] = 0;          lefnc_cb[0] = 0;
                lefnc_y[1] = 0;          lefnc_cb[1] = 0;
                lefnc_y[2] = 0;          lefnc_cr[0] = 0;
                lefnc_y[3] = 0;          lefnc_cr[1] = 0;
                abvnc_y[xx * 4 + 0] = 0; abvnc_cb[xx * 2 + 0] = 0;
                abvnc_y[xx * 4 + 1] = 0; abvnc_cb[xx * 2 + 1] = 0;
                abvnc_y[xx * 4 + 2] = 0; abvnc_cr[xx * 2 + 0] = 0;
                abvnc_y[xx * 4 + 3] = 0; abvnc_cr[xx * 2 + 1] = 0;
            }
            else if (macroblock_layer_length > 3088) { // A.3.1.n, max MB length is 3200, however PCM is pel(3072)+mbtype(9)+max align(7)=3088 
//          else if ( xx % 10 == 1 && yy % 10 == 1) { // just force sparse pcm to test 
                mb_type = GG_MBTYPE_IPCM;
                ggo_put_ue(skip_run, "mb_skip_run ue(v)");
                skip_run = 0;
                ggo_put_null("macroblock_layer() {           ");
                ggo_put_ue(30, "mb_type ue(v) PCM is 30 in Pframes");
                ggo_align();
                for (int py = 0; py < 16; py++)
                    for (int px = 0; px < 16; px++)
                        ggo_pcm_putbyte(ggi_y[xx * 16 + px + (yy * 16 + py) * mb_width * 16]);
                for (int py = 0; py < 8; py++)
                    for (int px = 0; px < 8; px++)
                        ggo_pcm_putbyte(ggi_cb[xx * 8 + px + (yy * 8 + py) * mb_width * 8]);
                for (int py = 0; py < 8; py++)
                    for (int px = 0; px < 8; px++)
                        ggo_pcm_putbyte(ggi_cr[xx * 8 + px + (yy * 8 + py) * mb_width * 8]);
                ggo_put_null("}");
                // Write Recon
                for (int py = 0; py < 16; py++)
                    for (int px = 0; px < 16; px++)
                        ggo_recon_y[xx * 16 + px + (yy * 16 + py) * mb_width * 16] = ggi_y[xx * 16 + px + (yy * 16 + py) * mb_width * 16];
                for (int py = 0; py < 8; py++)
                    for (int px = 0; px < 8; px++) {
                        ggo_recon_cb[xx * 8 + px + (yy * 8 + py) * mb_width * 8] = ggi_cb[xx * 8 + px + (yy * 8 + py) * mb_width * 8];
                        ggo_recon_cr[xx * 8 + px + (yy * 8 + py) * mb_width * 8] = ggi_cr[xx * 8 + px + (yy * 8 + py) * mb_width * 8];
                    }
                // Update left, above nC's to 16 for PCM
                lefnc_y[0] = 16; lefnc_cb[0] = 16;
                lefnc_y[1] = 16; lefnc_cb[1] = 16;
                lefnc_y[2] = 16; lefnc_cr[0] = 16;
                lefnc_y[3] = 16; lefnc_cr[1] = 16;
                abvnc_y[xx * 4 + 0] = 16; abvnc_cb[xx * 2 + 0] = 16;
                abvnc_y[xx * 4 + 1] = 16; abvnc_cb[xx * 2 + 1] = 16;
                abvnc_y[xx * 4 + 2] = 16; abvnc_cr[xx * 2 + 0] = 16;
                abvnc_y[xx * 4 + 3] = 16; abvnc_cr[xx * 2 + 1] = 16;
            }
            else {
                mb_type = GG_MBTYPE_INTER;
                ggo_put_ue(skip_run, "mb_skip_run ue(v)");
                skip_run = 0;
                ggo_put_null("macroblock_layer() {           ");
                ggo_put_ue(0, "mb_type ue(v)  P L0 16x16 = 0");
                ggo_put_null("mb_pred( mb_type ) {");
                ggo_put_te(refidx, 1, "ref_idx_l0[mbPartIdx] te(v)");
                ggo_put_se(0, "mvd_l0[ 0 ][ 0 ][ 0 ] se(v)");
                ggo_put_se(0, "mvd_l0[ 0 ][ 0 ][ 1 ] se(v)");
                ggo_put_null("}");
                ggo_put_me(cbp, 0, "coded_block_pattern me(v)");
                if (cbp) {
                    ggo_put_se(0, "mb_qp_delta se(v)");
                    ggo_put_null("residual( ) {");
                    if (cbp & 1) { // emit blocks 0,1,2,3
                        ggo_put_bitbuffer(&bits_y[0], "Luma blk 0");
                        ggo_put_bitbuffer(&bits_y[1], "Luma blk 1");
                        ggo_put_bitbuffer(&bits_y[2], "Luma blk 2");
                        ggo_put_bitbuffer(&bits_y[3], "Luma blk 3");
                    }
                    if (cbp & 2) { // emit blocks 4, 5, 6, 7
                        ggo_put_bitbuffer(&bits_y[4], "Luma blk 4");
                        ggo_put_bitbuffer(&bits_y[5], "Luma blk 5");
                        ggo_put_bitbuffer(&bits_y[6], "Luma blk 6");
                        ggo_put_bitbuffer(&bits_y[7], "Luma blk 7");
                    }
                    if (cbp & 4) { // emit blocks 8, 9, 10, 11
                        ggo_put_bitbuffer(&bits_y[8], "Luma blk 8");
                        ggo_put_bitbuffer(&bits_y[9], "Luma blk 9");
                        ggo_put_bitbuffer(&bits_y[10], "Luma blk 10");
                        ggo_put_bitbuffer(&bits_y[11], "Luma blk 11");
                    }
                    if (cbp & 8) { // emit blocks 12, 13, 14, 15
                        ggo_put_bitbuffer(&bits_y[12], "Luma blk 12");
                        ggo_put_bitbuffer(&bits_y[13], "Luma blk 13");
                        ggo_put_bitbuffer(&bits_y[14], "Luma blk 14");
                        ggo_put_bitbuffer(&bits_y[15], "Luma blk 15");
                    }
                    if (cbp & 0x30) { // emit chroma DC blocks cb_dc, cr_dc
                        ggo_put_bitbuffer(&bits_dc_cb, "Chroma DC Cb");
                        ggo_put_bitbuffer(&bits_dc_cr, "Chroma DC Cr");
                    }
                    if (cbp & 0x20) { // emit chroma blocks cb0, cb1, cb2, cb3, cr0, cr1, cr2, cr3
                        ggo_put_bitbuffer(&bits_cb[0], "Chroma Cb blk 0");
                        ggo_put_bitbuffer(&bits_cb[1], "Chroma Cb blk 1");
                        ggo_put_bitbuffer(&bits_cb[2], "Chroma Cb blk 2");
                        ggo_put_bitbuffer(&bits_cb[3], "Chroma Cb blk 3");
                        ggo_put_bitbuffer(&bits_cr[0], "Chroma Cr blk 0");
                        ggo_put_bitbuffer(&bits_cr[1], "Chroma Cr blk 1");
                        ggo_put_bitbuffer(&bits_cr[2], "Chroma Cr blk 2");
                        ggo_put_bitbuffer(&bits_cr[3], "Chroma Cr blk 3");
                    }
                    ggo_put_null("}");
                }
                ggo_put_null("}");
                // Write Recon
                for (int by = 0; by < 4; by++)
                    for (int bx = 0; bx < 4; bx++)
                        for (int py = 0; py < 4; py++)
                            for (int px = 0; px < 4; px++) {
                                ggo_recon_y[xx * 16 + bx * 4 + px + (yy * 16 + by * 4 + py) * mb_width * 16] = recon_y[by * 4 + bx][py * 4 + px];

                            }
                for (int by = 0; by < 2; by++)
                    for (int bx = 0; bx < 2; bx++)
                        for (int py = 0; py < 4; py++)
                            for (int px = 0; px < 4; px++) {
                                ggo_recon_cb[xx * 8 + bx * 4 + px + (yy * 8 + by * 4 + py) * mb_width * 8] = recon_cb[by * 2 + bx][py * 4 + px];
                                ggo_recon_cr[xx * 8 + bx * 4 + px + (yy * 8 + by * 4 + py) * mb_width * 8] = recon_cr[by * 2 + bx][py * 4 + px];
                            }
            }

            // Deblock Macroblock after skip/pcm/inter decision finalized
            if (pintra_disable_deblocking_filter_idc != 1) {
                gg_deblock_mb(&dbp, xx, yy, ggo_recon_y,  ggo_recon_cb, ggo_recon_cr, num_coeff_y, num_coeff_cb, num_coeff_cr, qp, refidx, mb_type );
            }
        }
    }
    // No final skip_run as ref1 is used
    if( skip_run ) { // final skip run for frame
        ggo_put_ue(skip_run, "mb_skip_run ue(v)");
    }
    ggo_put_null("}");

    if (intra_col_width) {
        ggo_intra_col = (ggo_intra_col + intra_col_width);
        if (ggo_intra_col >= mb_width)
            ggo_intra_col = 0;
    }
    
    // stop slice
    ggo_rbsp_trailing_bits();
    ggo_put_null("}");
}

/////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////

void ggi_init(const char* filename)
{
    ggi_fp = fopen(filename, "rb");
}

void ggi_read_frame()
{
    char* p;
    p = ggi_y;
    for (int ii = 0; ii < (mb_width * mb_height * 256); ii++)
        *p++ = fgetc(ggi_fp);

    p = ggi_cb;
    for (int ii = 0; ii < (mb_width * mb_height * 64); ii++)
        *p++ = fgetc(ggi_fp);

    p = ggi_cr;
    for (int ii = 0; ii < (mb_width * mb_height * 64); ii++)
        *p++ = fgetc(ggi_fp);


    //fgets(ggi_y,  mb_height * mb_width * 256, ggi_fp);
    //fgets(ggi_cb, mb_height * mb_width * 64 , ggi_fp);
    //fgets(ggi_cr, mb_height * mb_width * 64 , ggi_fp);
}

void recon_init(const char* name)
{
    ggo_recon_fp = fopen(name, "wb");
}

void recon_close()
{
    fclose(ggo_recon_fp);
}

void recon_write_yuv()
{
    char* p;
    p = ggo_recon_y;
    for (int ii = 0; ii < (mb_width * mb_height * 256); ii++)
        fputc( *p++, ggo_recon_fp);

    p = ggo_recon_cb;
    for (int ii = 0; ii < (mb_width * mb_height * 64); ii++)
        fputc(*p++, ggo_recon_fp);

    p = ggo_recon_cr;
    for (int ii = 0; ii < (mb_width * mb_height * 64); ii++)
        fputc(*p++, ggo_recon_fp);
}

void recon_copy_to_ref(int refidx)
{
    char* recon, *ref;

    recon = ggo_recon_y;
    ref = ggo_ref_y[refidx];
    for (int ii = 0; ii < (mb_width * mb_height * 256); ii++)
        *ref++ = *recon++;

    recon = ggo_recon_cb;
    ref = ggo_ref_cb[refidx];
    for (int ii = 0; ii < (mb_width * mb_height * 64); ii++)
        *ref++ = *recon++;

    recon = ggo_recon_cr;
    ref = ggo_ref_cr[refidx];
    for (int ii = 0; ii < (mb_width * mb_height * 64); ii++)
        *ref++ = *recon++;
}

int main()
{
    test_run_before();
   
    printf("Hello from the Great Gobbler!\n");

    recon_init("test_stream.yuv");
    ggo_init("test_stream_grey.264");
    ggi_init("cheer_if.yuv");

    // Grey long term ref
    ggo_sequence_parameter_set();
    ggo_picture_parameter_set();
    ggo_long_term_grey_idc_slice();
    recon_write_yuv();
    recon_copy_to_ref(0); // actually where decoder will have it
    recon_copy_to_ref(1); // after next frame this will be avaiable long term

    // Grey Skip frame (which puts our long term ref into slot 1
    ggo_sequence_parameter_set();
    ggo_picture_parameter_set();
    ggo_pskip_slice(); 
    recon_write_yuv();
    recon_copy_to_ref(0);

    // Ref0 P frames
    // ggo_sequence_parameter_set();
    // ggo_picture_parameter_set();
    // ggi_read_frame();
    // ggo_inter_0_0_slice(29, 0, 0); // ref0 pintra frame
    // recon_write_yuv();
    // recon_copy_to_ref(0);

    for (int ii = 0; ii < 20; ii++) {
        ggo_sequence_parameter_set();
        ggo_picture_parameter_set();
        ggi_read_frame();
        ggo_inter_0_0_slice(29, 0, 5); // pintra refresh cols
        recon_write_yuv();
        recon_copy_to_ref(0);
    }

    // Ref1 P frames = 'pintra' frames
    for (int ii = 0; ii < 1; ii++) {
        ggo_sequence_parameter_set();
        ggo_picture_parameter_set();
        ggi_read_frame();
        ggo_inter_0_0_slice(29, 1, 0);
        recon_write_yuv();
        recon_copy_to_ref(0);
    }

    ggo_close();
    recon_close();

} 

 