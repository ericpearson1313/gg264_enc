#pragma once
/*****************************************************************************
 * VLC
 Copyright (C) 2003-2019 x264 project
 *****************************************************************************/
typedef struct
{
    unsigned int  i_bits;
    unsigned char i_size;
} vlc_t;

extern const vlc_t x264_coeff0_token[6];
extern const vlc_t x264_coeff_token[6][16][4];
extern const vlc_t x264_total_zeros[15][16];
extern const vlc_t x264_total_zeros_2x2_dc[3][4];
extern const vlc_t x264_total_zeros_2x4_dc[7][8];
extern const vlc_t x264_run_before_init[7][16];
