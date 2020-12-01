#pragma once

typedef struct
{
    unsigned int  i_bits;
    unsigned char i_size;
} vlc_t;

extern const int Qmat[6][4][4];
extern const int Dmat[6][4][4];
extern const int qpc_table[52];
extern const vlc_t x264_coeff0_token[6];
extern const vlc_t x264_coeff_token[6][16][4];
extern const vlc_t x264_total_zeros[15][16];
extern const vlc_t x264_total_zeros_2x2_dc[3][4];
extern const vlc_t x264_total_zeros_2x4_dc[7][8];
extern const vlc_t x264_run_before_init[7][16];
extern const int coeff_token_parse_table[5][62][4];
extern const int total_zeros_parse_table[18][16][3];
extern const int run_before_parse_table[7][15][3];

extern const int alpha_table[52];
extern const int beta_table[52];
extern const int tc0_table[3][52];