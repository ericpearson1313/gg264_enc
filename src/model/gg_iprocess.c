#include <stdio.h>
#include "gg_process.h"


// extract bit from a bitbuffer, starting at pos (base 0), for len bits
// and return in a MSB aligned 32 bit word
unsigned int get_bitword(bitbuffer* bits, int pos, int len)
{
	int vlc_idx; 
	int vlc_bit;
	int cur_bitcount; 
	unsigned int bitword = 0;

	// find vlc_idx containing start position pos
	for (vlc_idx = 0, cur_bitcount = 0; vlc_idx < bits->num; cur_bitcount += bits->vlc[vlc_idx++].i_size) {
		if ((pos - cur_bitcount >= 0) && (pos - cur_bitcount < bits->vlc[vlc_idx].i_size))
			break;
	}
	if (vlc_idx == bits->num) { // pos > end of vlc_buffer, pad with zeros
		return(0);
	}
	vlc_bit = pos - cur_bitcount;
	// pack bitword, big endian
	for (int ii = 0; ii < len; ii++) {
		bitword |= (((bits->vlc[vlc_idx].i_bits)>>(bits->vlc[vlc_idx].i_size-vlc_bit-1)) & 1) << (31 - ii);
		vlc_bit++;
		if (vlc_bit == bits->vlc[vlc_idx].i_size) {
			vlc_bit = 0;
			if (++vlc_idx == bits->num)
				break;
		}
	}
	return(bitword);
}

// Returns the index (base 1) of the first non-zero bit in a msb aligned, big endian, bit packed word
// If a '1' has not been found in the first max-1 bits, then return max
int get_lead_zeros(unsigned int bitword, int max)
{
	int first_one = max;
	for (int ii = 0; ii < max - 1; ii++) {
		if (bitword >>( 31-ii ) &1 ) {
			first_one = ii + 1;
			break;
		}
	}
	return(first_one);
}

// Pprocess and decode a single transform block
// Input: qp, ref[16], bidx, cidx {0-luma, 1-acluma, 2-cb, 3-cr, 4-dccb, 5-dccr, 6-dcy}, skip flag
// Output: recon[16], bits, *bitcount
// State Update: char lefnc[4], abvnc[4], int dc_hold[16];
// Steps: cavlc decode, Q', T1', pred, recon
int gg_iprocess_block(int qpy, int* ref, int* dc_hold, int cidx, int bidx, char* lefnc, char* abvnc, int* recon, bitbuffer* bits, int skip)
{
	//if (cidx == 0 && bidx == 9) {
	//	printf("debug\n");
	//}
	int cur_bitpos = 0;

	// Flags
	int dc_flag = (cidx == 4 || cidx == 5 || cidx == 6) ? 1 : 0;
	int ac_flag = (cidx == 1 || cidx == 2 || cidx == 3) ? 1 : 0;
	int ch_flag = (cidx == 2 || cidx == 3 || cidx == 4 || cidx == 5) ? 1 : 0;

	//////////////////////////////////////////////
	// Parse 
	//////////////////////////////////////////////


	//////////////////////////////////////////
	// Syntax Element: Coeff_token
	//////////////////////////////////////////

	// Determine cavlc table to use
	int abv_idx = 0;
	int lef_idx = 0;
	int coeff_table_idx;
	if (ch_flag && dc_flag) {
		coeff_table_idx = 4;
	}
	else if (dc_flag) {
		int nc = lefnc[0] + abvnc[0];
		coeff_table_idx = (nc < 2) ? 0 : (nc < 4) ? 1 : (nc < 8) ? 2 : 3;
	}
	else {
		abv_idx = (bidx & 1) + ((bidx & 4) >> 1);
		lef_idx = ((bidx & 2) >> 1) + ((bidx & 8) >> 2);
		int nc;
		if (lefnc[lef_idx] != -1 && abvnc[abv_idx] != -1) {
			nc = (lefnc[lef_idx] + abvnc[abv_idx] + 1) >> 1;
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
	}

	const int coeff_token_max_lead_zeros[5] = { 15, 13, 10, 1, 8 };
	const int coeff_token_length_table[5][15] = {
			{ 1, 2, 3, 6, 7, 8, 9, 10, 11, 13, 14, 15, 16, 16, 15 },
			{ 2, 4, 6, 6, 7, 8, 9, 11, 12, 13, 14, 14, 13 },
			{ 4, 5, 6, 7, 8, 9, 10, 10, 10, 10 },
			{ 6 },
			{ 1, 2, 3, 6, 6, 7, 8, 7 }
	};

	int coeff_token_length;
	int num_coeff = 0;
	int trailing_ones = 0;
	if (skip) {
		num_coeff = 0;
		coeff_token_length = 0;
	}
	else {
		// Determine syntax element length
		unsigned int coeff_token_bitword = get_bitword(bits, cur_bitpos, 16);
		int coeff_token_lead_zeros = get_lead_zeros(coeff_token_bitword, coeff_token_max_lead_zeros[coeff_table_idx]);
		coeff_token_length = coeff_token_length_table[coeff_table_idx][coeff_token_lead_zeros - 1];

		// Correct the 6 special cases
		if ((coeff_table_idx == 0 && coeff_token_lead_zeros == 4 && (coeff_token_bitword & (1 << 27))) ||
			(coeff_table_idx == 0 && coeff_token_lead_zeros == 5 && (coeff_token_bitword & (1 << 26))) ||
			(coeff_table_idx == 1 && coeff_token_lead_zeros == 2 && (coeff_token_bitword & (1 << 29))) ||
			(coeff_table_idx == 1 && coeff_token_lead_zeros == 3 && (coeff_token_bitword & (1 << 28))) ||
			(coeff_table_idx == 1 && coeff_token_lead_zeros == 11 && (coeff_token_bitword & (1 << 18))) ||
			(coeff_table_idx == 2 && coeff_token_lead_zeros == 7 && (coeff_token_bitword & (1 << 24)) && (coeff_token_bitword & (1 << 23)))) {
			coeff_token_length--;
		}

		// Decode syntax_element to get { num_coeff, trailing_ones }
		coeff_token_bitword >>= (32 - coeff_token_length); // right hand justify for comparison
		for (int ii = 0; ii < ((coeff_table_idx == 4) ? 14 : 62); ii++) { // TODO: can optimize this much further
			if (coeff_token_bitword == coeff_token_parse_table[coeff_table_idx][ii][0] && coeff_token_length == coeff_token_parse_table[coeff_table_idx][ii][1]) {
				num_coeff = coeff_token_parse_table[coeff_table_idx][ii][3];
				trailing_ones = coeff_token_parse_table[coeff_table_idx][ii][2];
				break;
			}
		}
	}
	// Update left, above nc
	if (!dc_flag) {
		lefnc[lef_idx] = num_coeff;
		abvnc[abv_idx] = num_coeff;
	}
	cur_bitpos += coeff_token_length;

	////////////////////////////////////////////////////////////////////////////////////
	// Coefficient Syntax Elements: trailing_ones_sign_flag, level_prefix, level_suffix
	////////////////////////////////////////////////////////////////////////////////////

	int scan[16];
	int max_coeff = (ch_flag && dc_flag) ? 4 : (ac_flag) ? 15 : 16;
	int suffix_length = (num_coeff > 10 && trailing_ones < 3) ? 1 : 0;
	int coeff_length;

	for (int scan_idx = 0; scan_idx < max_coeff; scan_idx++) {
		if (scan_idx >= num_coeff) {
			scan[scan_idx] = 0;
			coeff_length = 0;
		}
		else { // actually parse
			unsigned int level_bitword = get_bitword(bits, cur_bitpos, 28);
			if (scan_idx < trailing_ones) {
				coeff_length = 1;
				scan[scan_idx] = (level_bitword & (1 << 31)) ? -1 : 1;
			}
			else {
				int level_code;
				int coeff_token_lead_zeros = get_lead_zeros(level_bitword, 16 );
				coeff_length = (coeff_token_lead_zeros == 16) ? 28 :
					(suffix_length == 0 && coeff_token_lead_zeros == 15) ? 19 :
					coeff_token_lead_zeros + suffix_length;

				// Parse level code
				switch (suffix_length) {
				case 0:
					level_code = (coeff_token_lead_zeros < 15) ? (coeff_token_lead_zeros - 1) :
						(coeff_token_lead_zeros == 15) ? (14 + ((level_bitword >> 13) & 0xF)) :
						(30 + ((level_bitword >> 4) & 0xFFF));
					break;
				case 1:
					level_code = (coeff_token_lead_zeros < 16) ? (((coeff_token_lead_zeros - 1) << 1) + ((level_bitword >> (31 - coeff_token_lead_zeros)) & 0x1)) :
						(30 + ((level_bitword >> 4) & 0xFFF));
					break;
				case 2:
					level_code = (coeff_token_lead_zeros < 16) ? (((coeff_token_lead_zeros - 1) << 2) + ((level_bitword >> (30 - coeff_token_lead_zeros)) & 0x3)) :
						(60 + ((level_bitword >> 4) & 0xFFF));
					break;
				case 3:
					level_code = (coeff_token_lead_zeros < 16) ? (((coeff_token_lead_zeros - 1) << 3) + ((level_bitword >> (29 - coeff_token_lead_zeros)) & 0x7)) :
						(120 + ((level_bitword >> 4) & 0xFFF));
					break;
				case 4:
					level_code = (coeff_token_lead_zeros < 16) ? (((coeff_token_lead_zeros - 1) << 4) + ((level_bitword >> (28 - coeff_token_lead_zeros)) & 0xF)) :
						(240 + ((level_bitword >> 4) & 0xFFF));
					break;
				case 5:
					level_code = (coeff_token_lead_zeros < 16) ? (((coeff_token_lead_zeros - 1) << 5) + ((level_bitword >> (27 - coeff_token_lead_zeros)) & 0x1F)) :
						(480 + ((level_bitword >> 4) & 0xFFF));
					break;
				case 6:
					level_code = (coeff_token_lead_zeros < 16) ? (((coeff_token_lead_zeros - 1) << 6) + ((level_bitword >> (26 - coeff_token_lead_zeros)) & 0x3F)) :
						(960 + ((level_bitword >> 4) & 0xFFF));
					break;
				}

				// calc scan coeff value
				if (scan_idx == trailing_ones && trailing_ones < 3)
					level_code += 2;
				scan[scan_idx] = (level_code & 1) ? ((-level_code - 1) >> 1) : ((level_code + 2) >> 1);

				// update suffix length based on lead zeros
				if (suffix_length == 0)
					suffix_length = 1;
				if (suffix_length < 6 && ABS(scan[scan_idx]) > (3<<(suffix_length-1)))
					suffix_length++;
			}
		}
		cur_bitpos += coeff_length;
	} // scan idx




	//////////////////////////////////////////
	// Syntax Element: total_zeros
	//////////////////////////////////////////

	const int total_zeros_max_lead_zeros[18] = { /* 2x2 */ 4,3,2, /* 4x4 */ 9,7,7,6,6,7,7,7,7,6,5,5,4,3,2 };
	const int total_zeros_length_table[18][9] = {
		// 2x2
		{ 1,2,3,3 },
		{ 1,2,2 },
		{ 1,1 },
		// 4x4
		{ 1,3,4,5,6,7,8,9,9 },
		{ 3,4,4,5,6,6,6 },
		{ 3,4,4,5,5,6,6 },
		{ 3,4,4,5,5,5 },
		{ 3,4,4,4,5,5 },
		{ 3,3,3,4,5,6,6 },
		{ 3,3,3,4,5,6,6 },
		{ 2,3,3,4,5,6,6 },
		{ 2,2,3,4,5,6,6 },
		{ 2,2,3,4,5,5 },
		{ 1,3,3,4,4 },
		{ 1,2,3,4,4 },
		{ 1,2,3,3 },
		{ 1,2,2 },
		{ 1, 1 }
	};

	int total_zeros = 0;
	if (num_coeff > 0 && num_coeff < ((ch_flag && dc_flag) ? 4 : 16)) {

		// Determine syntax element length
		int total_zeros_table_idx = num_coeff + ((ch_flag && dc_flag) ? 0 : 3) - 1;
		unsigned int total_zeros_bitword = get_bitword(bits, cur_bitpos, 9);
		int total_zeros_lead_zeros = get_lead_zeros(total_zeros_bitword, total_zeros_max_lead_zeros[total_zeros_table_idx]);
		int total_zeros_length = total_zeros_length_table[total_zeros_table_idx][total_zeros_lead_zeros - 1];
		// Correct the 5 special cases
		if ((total_zeros_table_idx == 5-1 && total_zeros_lead_zeros == 2 && (total_zeros_bitword & (1 << 29))) ||
			(total_zeros_table_idx == 6-1 && total_zeros_lead_zeros == 2 && (total_zeros_bitword & (1 << 29))) ||
			(total_zeros_table_idx == 7-1 && total_zeros_lead_zeros == 2 && (total_zeros_bitword & (1 << 29))) ||
			(total_zeros_table_idx == 8-1 && total_zeros_lead_zeros == 2 && (total_zeros_bitword & (1 << 29))) ||
			(total_zeros_table_idx == 10-1 && total_zeros_lead_zeros == 1 && (total_zeros_bitword & (1 << 30)))) {
			total_zeros_length--;
		}

		// Decode total_zeros syntax_element }
		total_zeros_bitword >>= (32 - total_zeros_length); // right hand justify for comparison
		for (int ii = 0; ii < (((ch_flag && dc_flag) ? 4 : 16) - num_coeff + 1); ii++) { // TODO: can optimize this much further
			if (total_zeros_bitword == total_zeros_parse_table[total_zeros_table_idx][ii][0] && total_zeros_length == total_zeros_parse_table[total_zeros_table_idx][ii][1]) {
				total_zeros = total_zeros_parse_table[total_zeros_table_idx][ii][2];
				break;
			}
		}

		cur_bitpos += total_zeros_length;
	}

	//////////////////////////////////////////
	// Syntax Element: run_before
	//////////////////////////////////////////

	const int run_before_max_lead_zeros[7] = { 2,3,3,4,4,4,11 };
	const int run_before_length_table[7][11] = {
		{ 1,1 },
		{ 1,2,2 },
		{ 2,2,2 },
		{ 2,2,3,3 },
		{ 2,3,3,3 },
		{ 3,3,3,3 },
		{ 3,3,3,4,5,6,7,8,9,10,11 }
	};

	// Itterate to max 14 run_before syntax elements
	int zeros_left = total_zeros;
	int run_before[16] = { 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 };
	for (int run_idx = 0; run_idx < num_coeff-1; run_idx++) {
		if (zeros_left) {
			// Determine length
			int run_before_table_idx = MIN(7, zeros_left)-1;
			unsigned int run_before_bitword = get_bitword(bits, cur_bitpos, 11);
			int run_before_lead_zeros = get_lead_zeros(run_before_bitword, run_before_max_lead_zeros[run_before_table_idx]);
			int run_before_length = run_before_length_table[run_before_table_idx][run_before_lead_zeros - 1];
			// Correct the 5 special cases
			if (run_before_table_idx == 6-1 && run_before_lead_zeros == 1 && (run_before_bitword & (1 << 30))) {
				run_before_length--;
			}
			// Decode run_before
			run_before_bitword >>= (32 - run_before_length); // right hand justify for comparison
			for (int ii = 0; ii < ((run_before_table_idx<6)?(run_before_table_idx+2):15); ii++) { // TODO: can optimize this much further
				if (run_before_bitword == run_before_parse_table[run_before_table_idx][ii][0] && run_before_length == run_before_parse_table[run_before_table_idx][ii][1]) {
					run_before[run_idx] = run_before_parse_table[run_before_table_idx][ii][2];
					break;
				}
			}
			// update bit pos
			cur_bitpos += run_before_length;
			zeros_left -= run_before[run_idx];
		} // zeros_left remaining
		else {
			run_before[run_idx] = 0;
		}
	} // run_idx 0..13
	// remaining zeros lead the first coeff
	if (num_coeff) {
		run_before[num_coeff - 1] = zeros_left;
	}


	////////////////////////////////////////
	// Populate coeff[16]
	////////////////////////////////////////

	const int zigzag4x4[16] = { 0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15 };
	const int zigzag2x2[4] =  { 0,1,4,5 };


	// init coeff array. only non zero coeffs populated
	int coeff[16] = { 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 };

	// copy scan[] parse order coeffs into the 2D coeff block (2x2 or 4x4) structure using
	// run_before[] and total_zeros to determine zero's
	// use inverse zig zagg for 1D to 2D conversion, and 
	// shifting and inserting zero dc coeff for AC blocks 

	int coeff_idx = -1;
	if (num_coeff) {
		if (ch_flag && dc_flag) { // ChDc
			for (int ii = num_coeff - 1; ii >= 0; ii--) {
				coeff_idx += run_before[ii] + 1;
				coeff[zigzag2x2[coeff_idx]] = scan[ii];
			}
		}
		else if (ac_flag) { // Ac block (skip DC)
			for (int ii = num_coeff - 1; ii >= 0; ii--) {
				coeff_idx += run_before[ii] + 1;
				coeff[zigzag4x4[coeff_idx + 1]] = scan[ii];
			}
		}
		else {
			for (int ii = num_coeff - 1; ii >= 0; ii--) {
				coeff_idx += run_before[ii] + 1;
				coeff[zigzag4x4[coeff_idx]] = scan[ii];
			}
		}
	}

	//printf("Parse coeff = ");
	//for (int ii = 0; ii < max_coeff; ii++)
	//	printf("%3d ", coeff[(ch_flag&&dc_flag)?zigzag2x2[ii]:zigzag4x4[ii]]);
	//printf("BLK %d,%d nc %d[%d] = ", cidx, bidx, num_coeff, trailing_ones);
	//printf("\n");

	//////////////////////////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////////////////////////
	//                         >>>>>>>>> coeff[16] <<<<<<<<<<<<<<
	//           Now we have coefficients to: 1) reconstruct
	//////////////////////////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////////////////////////


	/////////////////////////////////////////
	// Inverse Quant (coeff->f)
	/////////////////////////////////////////

	int f[16]; // inverse quant
	int qp;
	int dequant;
	int coeff_dc;

	// Select qpy or derive qpc
	qp = (ch_flag) ? qpc_table[qpy] : qpy;

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
				coeff_dc = dc_hold[((bidx & 1) << 0) + ((bidx & 2) << 1)]; // sample 0,1,4,5
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

	int g[4], h[16], k[4], m[16];
	int res[16]; // residual

	for (int row = 0; row < 4; row++) {// row 1d transforms
		g[0] = f[row * 4 + 0] + f[row * 4 + 2];
		g[1] = f[row * 4 + 0] - f[row * 4 + 2];
		g[2] = (f[row * 4 + 1] >> ((dc_flag) ? 0 : 1)) - f[row * 4 + 3];
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
	// Luma / Chroma / dc transform
		for (int ii = 0; ii < 16; ii++) {
			res[ii] = (m[ii] + 32) >> 6;
		}
	

	/////////////////////////////////////////
	// Reconstruction & distortion calc
	////////////////////////////////////////

	if (dc_flag == 0) {
		for (int ii = 0; ii < 16; ii++) {
			recon[ii] = CLIP1(res[ii] + ref[ii]);
		}
	}

	// Return bits parsed
	return(cur_bitpos);
}