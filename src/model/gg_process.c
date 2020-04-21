#include <stdio.h>
#include "gg_process.h"

#define CLIP3(x,y,z) (((z)<(x))?(x):((z)>(y))?(y):(z))
#define CLIP1(z) CLIP3(0,255,(z))
#define SSD(x) ((x)*(x))
#define SAD(x) ((x<0)?(-(x)):(x))
#define ABS(x) ((x<0)?(-(x)):(x))
#define MIN(x,y) ((x)<(y)?(x):(y))
#define MAX(x,y) ((x)>(y)?(x):(y))

const int Qmat[6][4][4] = { { { 13107, 8066, 13107, 8066 }, { 8066, 5243, 8066, 5243 }, { 13107, 8066, 13107, 8066 }, { 8066, 5243, 8066, 5243} },
						    { { 11916, 7490, 11916, 7490 }, { 7490, 4660, 7490, 4660 }, { 11916, 7490, 11916, 7490 }, { 7490, 4660, 7490, 4660} },
						    { { 10082, 6554, 10082, 6554 }, { 6554, 4194, 6554, 4194 }, { 10082, 6554, 10082, 6554 }, { 6554, 4194, 6554, 4194} },
						    { { 9362 , 5825, 9362 , 5825 }, { 5825, 3647, 5825, 3647 }, { 9362 , 5825, 9362 , 5825 }, { 5825, 3647, 5825, 3647} },
						    { { 8192 , 5243, 8192 , 5243 }, { 5243, 3355, 5243, 3355 }, { 8192 , 5243, 8192 , 5243 }, { 5243, 3355, 5243, 3355} },
						    { { 7282 , 4559, 7282 , 4559 }, { 4559, 2893, 4559, 2893 }, { 7282 , 4559, 7282 , 4559 }, { 4559, 2893, 4559, 2893} } };

const int Dmat[6][4][4] = { { { 10, 13, 10, 13 }, { 13, 16, 13, 16 }, { 10, 13, 10, 13 }, { 13, 16, 13, 16} },
						    { { 11, 14, 11, 14 }, { 14, 18, 14, 18 }, { 11, 14, 11, 14 }, { 14, 18, 14, 18} },
						    { { 13, 16, 13, 16 }, { 16, 20, 16, 20 }, { 13, 16, 13, 16 }, { 16, 20, 16, 20} },
						    { { 14, 18, 14, 18 }, { 18, 23, 18, 23 }, { 14, 18, 14, 18 }, { 18, 23, 18, 23} },
						    { { 16, 20, 16, 20 }, { 20, 25, 20, 25 }, { 16, 20, 16, 20 }, { 20, 25, 20, 25} },
						    { { 18, 23, 18, 23 }, { 23, 29, 23, 29 }, { 18, 23, 18, 23 }, { 23, 29, 23, 29} } };

const int qpc_table[52] = { 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,
							29, 30, 31, 32, 32, 33, 34, 34,35,35,36,36,37,37,37,38,38,38,39,39,39,39 };

// Process a single transform block
// Input: qp, offset(0.8), deadzone(16.8) ref[16], orig[16], bidx, cidx {0-luma, 1-acluma, 2-cb, 3-cr, 4-dccb, 5-dccr, 6-dcy}
// Output: recon[16], bits, *bitcount, *sad, *ssd
// Steps: pred, T, Q, Q', T', recon, stats, cavlc encode
int gg_process_block(int qpy, int offset, int deadzone, int *ref, int *orig, int* dc_hold, int cidx, int bidx, char* lefnc, char* abvnc, int* recon, bitbuffer* bits, int* bitcount, int* sad, int* ssd)
{
	int a[16], b[4], c[16], d[4], e[16]; // forward transform
	int coeff[16]; // forward quant
	int res[16]; // residual
	int f[16]; // inverse quant
	int g[4], h[16], k[4], m[16];
	int qp;
	int num_coeff;
	int abscoeff;
	int negcoeff;
	int qc, qcdz;
	int quant;
	int qshift;

	// Flags
	int dc_flag = (cidx == 4 || cidx == 5 || cidx == 6) ? 1 : 0;
	int ac_flag = (cidx == 1 || cidx == 2 || cidx == 3) ? 1 : 0;
	int ch_flag = (cidx == 2 || cidx == 3 || cidx == 4 || cidx == 5) ? 1 : 0;

	/////////////////////////////////////////
	// Subtract Prediction
	/////////////////////////////////////////

	for (int ii = 0; ii < 16; ii++)
		a[ii] = orig[ii] - ref[ii];

	/////////////////////////////////////////
	// Forward Transform (a->e)
	/////////////////////////////////////////

	for (int row = 0; row < 4; row++) {// row 1d transforms
		b[0] = a[row * 4 + 0] + a[row * 4 + 3];
		b[1] = a[row * 4 + 1] + a[row * 4 + 2];
		b[2] = a[row * 4 + 1] - a[row * 4 + 2];
		b[3] = a[row * 4 + 0] - a[row * 4 + 3];
		c[row * 4 + 0] = b[0] + b[1];
		c[row * 4 + 1] = b[2] + (b[3] << ((dc_flag) ? 0 : 1) );
		c[row * 4 + 2] = b[0] - b[1];
		c[row * 4 + 3] = b[3] - (b[2] << ((dc_flag) ? 0 : 1));
	}
	for (int col = 0; col < 4; col++) {// col 1d transforms
		d[0] = c[col + 4 * 0] + c[col + 4 * 3];
		d[1] = c[col + 4 * 1] + c[col + 4 * 2];
		d[2] = c[col + 4 * 1] - c[col + 4 * 2];
		d[3] = c[col + 4 * 0] - c[col + 4 * 3];
		e[col + 4 * 0] = d[0] + d[1];
		e[col + 4 * 1] = d[2] + (d[3] << ((dc_flag) ? 0 : 1));
		e[col + 4 * 2] = d[0] - d[1];
		e[col + 4 * 3] = d[3] - (d[2] << ((dc_flag) ? 0 : 1));
	}

	/////////////////////////////////////////
	// Foward Quantize (e->coeff), offset, deadzone
	/////////////////////////////////////////

	// Select qpy or derive qpc
	qp = (ch_flag) ? qpc_table[qpy] : qpy;

	// Forward quant 16 coeffs
	for (int ii = 0; ii < 16; ii++) {
		abscoeff = (e[ii] < 0) ? -e[ii] : e[ii]; // remove the sign, so we round down towards zero using >>
		negcoeff = (e[ii] < 0) ? 1 : 0; // we will restore the sign after quantization
		quant = (dc_flag) ? Qmat[qp % 6][0][0] : Qmat[qp % 6][ii >> 2][ii & 3];
		qshift = (qp / 6) + ((dc_flag & !ch_flag) ? 9 : (dc_flag && ch_flag) ? 8 : 7);
		qc = ((abscoeff * quant) >> qshift ) + offset; // 8 fractional bits still remain, larger dc shift
		qcdz = (qc < deadzone) ? 0 : (qc >> 8);
		coeff[ii] = (negcoeff) ? -qcdz : qcdz;
	}

	//////////////////////////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////////////////////////
	//                         >>>>>>>>> coeff[16] <<<<<<<<<<<<<<
	//           Now we have coefficients to: 1) entropy encode 2) reconstruct
	//////////////////////////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////////////////////////


	/////////////////////////////////////////
	// Inverse Quant (coeff->f)
	/////////////////////////////////////////

	int dequant;
	int coeff_dc;
	if (dc_flag) { // Just copy DC coeff, will be quanted later along with AC
		if (ch_flag) { // sub-sample coeffs for ch dc
			for (int ii = 0; ii < 16; f[ii++] = 0);
			f[0] = coeff[0];
			f[2] = coeff[1];
			f[8] = coeff[4];
			f[10] = coeff[5];
		}
		else { // copy all coeff unquantized
			for (int ii = 0; ii < 16; ii++) {
				f[ii] = coeff[ii];
			}
		}
	}
	else { // Inverse quant 4x4, with special scaling for DC coeff when appropriate
		for (int ii = 0; ii < 16; ii++) { 
			if (ii == 0 && ac_flag && ch_flag) { // Handle Chroma dc coeff
				dequant = 16 * Dmat[qp % 6][0][0];
				coeff_dc = dc_hold[((bidx&1)<<0)+((bidx&2)<<1)]; // sample 0,1,4,5
				f[0] = ((coeff_dc * dequant) << (qp / 6)) >> 5;
			}
			else if (ii == 0 && ac_flag) { // Intra 16 dc coeff
				dequant = 16 * Dmat[qp % 6][0][0];
				coeff_dc = dc_hold[((bidx & 1) << 0) + ((bidx & 2) << 1) + ((bidx & 4) >> 1) + ((bidx & 8) << 0)];
				if (qp >= 36) {
					f[0] = (coeff_dc * dequant) << (qp / 6 - 6);
				}
				else { // qp < 36
					f[0] = (coeff_dc * dequant + (1 << (5 - qp / 6))) >> (6 - qp / 6);
				}
			}
			else { // normal 4x4 quant
				dequant = 16 * Dmat[qp % 6][ii >> 2][ii & 3];
				if (qp >= 24) {
					f[ii] = (coeff[ii] * dequant) << (qp / 6 - 4);
				}
				else { // qp < 24
					f[ii] = (coeff[ii] * dequant + (1 << (3 - qp / 6))) >> (4 - qp / 6);
				}
			}
		}
	}

	/////////////////////////////////////////
	// Inverse Transform (f->res)
	/////////////////////////////////////////

	for (int row = 0; row < 4; row++) {// row 1d transforms
		g[0] = f[row * 4 + 0] + f[row * 4 + 2];
		g[1] = f[row * 4 + 0] - f[row * 4 + 2];
		g[2] = (f[row * 4 + 1] >> ((dc_flag)?0:1)) - f[row * 4 + 3];
		g[3] = f[row * 4 + 1] + (f[row * 4 + 3] >> ((dc_flag) ? 0 : 1));
		h[row * 4 + 0] = g[0] + g[3]; // 0+2+1+3
		h[row * 4 + 1] = g[1] + g[2]; // 0-2+1-3
		h[row * 4 + 2] = g[1] - g[2]; // 0-2-1+3
		h[row * 4 + 3] = g[0] - g[3]; // 0+2-1-3
	}
	// assert g[4], h[16] in 16bit signed

	for (int col = 0; col < 4; col++) {// col 1d transforms
		k[0] = h[col + 4 * 0] + h[col + 4 * 2];
		k[1] = h[col + 4 * 0] - h[col + 4 * 2];
		k[2] = (h[col + 4 * 1] >> ((dc_flag) ? 0 : 1)) - h[col + 4 * 3];
		k[3] = h[col + 4 * 1] + (h[col + 4 * 3] >> ((dc_flag) ? 0 : 1));
		m[col + 4 * 0] = k[0] + k[3];
		m[col + 4 * 1] = k[1] + k[2];
		m[col + 4 * 2] = k[1] - k[2];
		m[col + 4 * 3] = k[0] - k[3];
	}
	// assert k[16], m[4] in 16 bits

	if (dc_flag) { // save results to DC hold
		for (int ii = 0; ii < 16; ii++) {
			dc_hold[ii] = m[ii]; // save away inverse transformed DC for following AC
		}
	}
	else { // Luma / Chroma 4x4 transform
		for (int ii = 0; ii < 16; ii++) {
			res[ii] = (m[ii] + 32) >> 6;
		}
	}

	/////////////////////////////////////////
	// Reconstruction & distortion calc
	////////////////////////////////////////

	*sad = 0;
	*ssd = 0;
	if (dc_flag == 0) {
		for (int ii = 0; ii < 16; ii++) {
			recon[ii] = CLIP1(res[ii] + ref[ii]);
			*ssd += SSD(recon[ii] - orig[ii]);
			*sad += SAD(recon[ii] - orig[ii]);
		}
	}

	//////////////////////////////////////////
	//////////////////////////////////////////
	// VLC CaVLC Encoding
	//////////////////////////////////////////
	//////////////////////////////////////////

	//////////////////////////////////////////
	// Zigzag scan convert block coeffs
	//////////////////////////////////////////

	int scan[16]; // dc->hf ordered coefficient list
	int zigzag4x4[16] = { 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
	int zigzag2x2[4] = { 0, 1, 4, 5 };
	int max_coeff;

	num_coeff = 0;
	if (ch_flag && dc_flag) {
		max_coeff = 4;
		for (int ii = 0; ii < max_coeff; ii++)
			num_coeff += (scan[ii] = coeff[zigzag2x2[ii]]) ? 1 : 0;
	}
	else if (ac_flag) {
		max_coeff = 15;
		for (int ii = 0; ii < max_coeff; ii++)
			num_coeff += (scan[ii] = coeff[zigzag4x4[ii+1]]) ? 1 : 0;
	}
	else {
		max_coeff = 16;
		for (int ii = 0; ii < max_coeff; ii++)
			num_coeff += (scan[ii] = coeff[zigzag4x4[ii]]) ? 1 : 0;
	}

	//////////////////////////////////////////
	// Syntax Element: Trailing_ones_sign_flag
	//////////////////////////////////////////

	int trailing_ones;
	vlc_t vlc_trailing_ones;

	vlc_trailing_ones.i_bits = 0;
	vlc_trailing_ones.i_size = 0;

	trailing_ones = 0;
	if( num_coeff ) {
		int ii = max_coeff;
		do {
			ii--;
			if (scan[ii] == 1) {
				vlc_trailing_ones.i_bits = vlc_trailing_ones.i_bits << 1;
				vlc_trailing_ones.i_size++;
				trailing_ones++;
			}
			else if (scan[ii] == -1) {
				vlc_trailing_ones.i_bits = (vlc_trailing_ones.i_bits << 1) | 1;
				vlc_trailing_ones.i_size++;
				trailing_ones++;
			}
		} while (trailing_ones < 3 && ii > 0 && scan[ii] <= 1 && scan[ii] >= -1);
	}

	//////////////////////////////////////////
	// Syntax Element: Coeff_token
	//////////////////////////////////////////

	int coeff_table_idx;
	vlc_t vlc_coeff_token;

	if (ch_flag && dc_flag) {
		coeff_table_idx = 4;
	} else if ( dc_flag ) {
		int nc = lefnc[0] + abvnc[0];
		coeff_table_idx = (nc < 2) ? 0 : (nc < 4) ? 1 : (nc < 8) ? 2 : 3;
	}
	else {
		int abv_idx = (bidx & 1) + ((bidx & 4) >> 1);
		int lef_idx = ((bidx & 2) >> 1) + ((bidx & 8) >> 2);
		int nc;
		if (lefnc[lef_idx] != -1 && abvnc[abv_idx] != -1) {
			nc = (lefnc[lef_idx] + abvnc[abv_idx] +1)>>1;
		}
		else if (lefnc[lef_idx] != -1) {
			nc = lefnc[lef_idx];
		}
		else if (abvnc[abv_idx] != -1) {
			nc = abvnc[abv_idx];
		}
		else {
			nc = 0;
		}
		coeff_table_idx = (nc < 2) ? 0 : (nc < 4) ? 1 : (nc < 8) ? 2 : 3;
		// Update 
		lefnc[lef_idx] = num_coeff;
		abvnc[abv_idx] = num_coeff;
	}

	vlc_coeff_token = ( num_coeff == 0 ) ? x264_coeff0_token[coeff_table_idx] : x264_coeff_token[coeff_table_idx][num_coeff-1][trailing_ones];

	//////////////////////////////////////////
	// Syntax Element: Total zeros
	//////////////////////////////////////////

	vlc_t vlc_total_zeros;
	int total_zeros;

	if (num_coeff == max_coeff || num_coeff == 0 ) {
		vlc_total_zeros.i_bits = 0;
		vlc_total_zeros.i_size = 0;
		total_zeros = 0;
	}
	else if( dc_flag && ch_flag ) { // 2x2 uses table 9-9
		int last_sig;
		for (last_sig = max_coeff; scan[last_sig-1] == 0; last_sig--);
		total_zeros = last_sig - num_coeff;
		vlc_total_zeros = x264_total_zeros_2x2_dc[num_coeff - 1][total_zeros];
	}
	else { // use table 9-7, 9-8
		int last_sig;
		for (last_sig = max_coeff; scan[last_sig - 1] == 0; last_sig--);
		total_zeros = last_sig - num_coeff;
		vlc_total_zeros = x264_total_zeros[num_coeff - 1][total_zeros];
	}

	//////////////////////////////////////////
	// Syntax Element: Run_before[]
	//////////////////////////////////////////

	vlc_t vlc_run_before[14];

	for (int ii = 0; ii < 14; ii++) {
		vlc_run_before[ii].i_size = 0;
		vlc_run_before[ii].i_bits = 0;
	}

	int zeros = total_zeros;
	int run = 0;
	int last_sig;
	if (num_coeff > 1 && total_zeros) {
		for (last_sig = max_coeff - 1; scan[last_sig] == 0; last_sig--); // find last sign coeff
		for (int coeff_idx = last_sig-1, sig_count = 0; (sig_count < num_coeff-1) && zeros; coeff_idx--) {
			if (scan[coeff_idx]) {
				vlc_run_before[sig_count] = x264_run_before_init[MIN(zeros-1, 6)][run];
				sig_count++;
				zeros -= run;
				run = 0;
			}
			else {
				run++;
			}
		}
	}

	///////////////////////////////////////////////
	// Syntax Element: level_prefix, level_suffix
	///////////////////////////////////////////////
	
	vlc_t vlc_level[16]; // Prefix + suffix
	int suffix_length;

	for (int ii = 0; ii < 16; ii++) {
		vlc_level[ii].i_size = 0;
		vlc_level[ii].i_bits = 0;
	}

	// select starting suffix.
	suffix_length = ( num_coeff > 10 && trailing_ones < 3) ? 1 : 0;

	// Code significant coeffs
	if (num_coeff && num_coeff > trailing_ones) { // encode the coeffs
		int level_code;
		for (int sig_count = 0, coeff_idx = (max_coeff - 1); sig_count < num_coeff; coeff_idx--) {
			if (scan[coeff_idx]) {
				sig_count++;
				if (sig_count > trailing_ones) { // Encode coeff scan[coeff_idx]
					vlc_level[coeff_idx].i_size = 0;
					vlc_level[coeff_idx].i_bits = 0;
					// calculate level code
					level_code = (scan[coeff_idx] > 0) ? ((scan[coeff_idx] - 1) * 2) : ((-scan[coeff_idx] - 1) * 2 + 1);
					level_code -= (trailing_ones < 3 && sig_count == (trailing_ones + 1)) ? 2 : 0;
					// encode as prefix/suffix
					if (suffix_length == 0) { // handle special case of 14
						if (level_code < 14) { // unary + 0
							vlc_level[coeff_idx].i_size = level_code+1;
							vlc_level[coeff_idx].i_bits = 1;
						}
						else if (level_code < 30) { // prefix 14, 1, 34
							vlc_level[coeff_idx].i_size = 19;
							vlc_level[coeff_idx].i_bits = 16 + level_code - 14;
						}
						else { // prefix 15, 1, 12
							vlc_level[coeff_idx].i_size = 28;
							vlc_level[coeff_idx].i_bits = 4096 + level_code - 30;
						}
					}
					else  { // suffix length 1 ... 6
						if (level_code < (30 << (suffix_length - 1))) {
							vlc_level[coeff_idx].i_size = (level_code>>suffix_length) + 1 + suffix_length;
							vlc_level[coeff_idx].i_bits = (1<<suffix_length) + (level_code & ((1<<suffix_length)-1)); // mask suffix length bits.
						}
						else { // Prefix 15, 1, 12
							vlc_level[coeff_idx].i_size = 28;
							vlc_level[coeff_idx].i_bits = 4096 + level_code - (30<<(suffix_length-1));
						}
					}
					// update suffix_length state
					if (suffix_length == 0)
						suffix_length = 1;
					if (ABS(scan[coeff_idx]) > (3 << (suffix_length - 1)) && suffix_length < 6)
						suffix_length++;
				}
			}
		}
	}

	/////////////////////////////////////////////////
	// Update bitstream buffer and *bitcount
	/////////////////////////////////////////////////

	int vlc_idx = 0;
	// Coeff Token
	bits->vlc[vlc_idx++] = vlc_coeff_token;
	// Trailing Ones
	if (vlc_trailing_ones.i_size )
		bits->vlc[vlc_idx++] = vlc_trailing_ones;
	// Coeff level prefix+suffix
	for (int ii = 15; ii >= 0; ii--) // count down
		if (vlc_level[ii].i_size)
			bits->vlc[vlc_idx++] = vlc_level[ii];
	// Total zeros
	if( vlc_total_zeros.i_size )
		bits->vlc[vlc_idx++] = vlc_total_zeros;
	// Run Before
	for( int ii = 0; ii < 14; ii++) // count up
		if (vlc_run_before[ii].i_size)
			bits->vlc[vlc_idx++] = vlc_run_before[ii];

	// Update number of bit runs
	bits->num = vlc_idx;
	// Sum up bitcount
	*bitcount = 0;
	for (int ii = 0; ii < vlc_idx; ii++)
		*bitcount += bits->vlc[ii].i_size;

	for (int ii = 0; ii < vlc_idx; ii++)
		if (bits->vlc[ii].i_size > 32)
			printf("help\n");

	//for (int ii = 0; ii < max_coeff; ii++)
	//	printf("%3d ", scan[ii]);
	//printf("BLK %d,%d nc %d[%d] = ", cidx, bidx, num_coeff, trailing_ones);
	//for (int ii = 0; ii < vlc_idx; ii++) {
	//	printf(" ");
	//	for (int jj = bits->vlc[ii].i_size - 1; jj >= 0; jj--) {
	//		printf("%1d", ((bits->vlc[ii].i_bits >> jj) & 1));
	//	}
	//}
	//printf("\n");

	//////////////////////////////////////////
	// Done, return num_coeff for block
	//////////////////////////////////////////

	return(num_coeff);
}

void test_run_before()
{
	vlc_t vlc_run_before[15]; // 0th is total_zero's and then 14 run befores
	int test;
	int total_zeros;
	int num_coeff;
	int zeros;
	int run;
	int last_sig;
	int scan[16];
	int bitcount;
	int max_bits;
	int max_bits_n[15][15];

	max_bits = 0;
	for (int ii = 0; ii < 15; ii++)
		for (int jj = 0; jj < 15; jj++)
			max_bits_n[ii][jj] = 0;

	for (test = 1; test < 65534; test++) {
		// Setup scan
		for (int ii = 0; ii < 16; ii++) 
			scan[ii] = (test & (1 << ii)) ? 1 : 0;
		// clear VLCs //
		for (int ii = 0; ii < 15; ii++) {
			vlc_run_before[ii].i_size = 0;
			vlc_run_before[ii].i_bits = 0;
		}
		// Calc num_coeff
		num_coeff = 0;
		for (int ii = 0; ii < 16; ii++)
			num_coeff += (scan[ii]) ? 1 : 0;
		// Calc total_zero's, last_sig
		for (last_sig = 16; scan[last_sig - 1] == 0; last_sig--);
		total_zeros = last_sig - num_coeff;
		// COde Total Zeros's
		if (num_coeff == 16 || num_coeff == 0) {
			vlc_run_before[0].i_bits = 0;
			vlc_run_before[0].i_size = 0;
		}
		else { // use table 9-7, 9-8
			vlc_run_before[0] = x264_total_zeros[num_coeff - 1][total_zeros];
		}
		// Determine run before
		zeros = total_zeros;
		run = 0;
		if (num_coeff > 1 && total_zeros) {
			for (int coeff_idx = last_sig - 2, sig_count = 0; (sig_count < num_coeff - 1) && zeros; coeff_idx--) {
				if (scan[coeff_idx]) {
					vlc_run_before[sig_count+1] = x264_run_before_init[MIN(zeros - 1, 6)][run];
					sig_count++;
					zeros -= run;
					run = 0;
				}
				else {
					run++;
				}
			}
		}
		// Count bits
		bitcount = 0;
		for (int ii = 0; ii < 15; bitcount += vlc_run_before[ii++].i_size);
		if (bitcount > max_bits) {
			// Print VLC
			printf("%04x = %3d nc %2d tz %2d  : ", test, bitcount, num_coeff, total_zeros );
			for (int ii = 0; ii < 15; ii++)
				if (vlc_run_before[ii].i_size) {
					for (int bb = vlc_run_before[ii].i_size - 1; bb >= 0; bb--)
						printf("%d", (vlc_run_before[ii].i_bits >> bb) & 1);
					printf(" ");
				}
			printf("\n");
		}
		max_bits = MAX(bitcount, max_bits);

		// Accumulated max_bits_n 

		for ( int acc_len = 0; acc_len < 15; acc_len++) {
			for (int acc_off = 0; acc_off < (15 - acc_len); acc_off++) {
				int sum = 0;
				for (int idx = 0; idx < acc_len+1; idx++) {
					sum += vlc_run_before[idx + acc_off].i_size;
				}
				max_bits_n[acc_len][acc_off] = MAX(sum, max_bits_n[acc_len][acc_off]);
			}
		}
	} // test
	printf("Max length run before = %d\n", max_bits);

	// Print summary
	for (int ii = 0; ii < 15; ii++) {
		printf("sum window = %2d : ", ii + 1);
		for (int jj = 0; jj < (15 - ii); jj++)
			printf("%2d ", max_bits_n[ii][jj]);
		printf("\n");
	}

}