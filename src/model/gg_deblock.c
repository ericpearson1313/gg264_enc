#include <stdio.h>
#include "gg_process.h"

// Low level in-place deblock Filter.
// Purpose: Deblock a single 4x4 block with 1 horizontal and 1 vertical filter, on left block
// Assumption: single slice (to reduce slice params), refidx is unique for frame id.
// Input: 4x4 recon blocks: cur, lef, abvle
//       Slice Params: disable_deblocking_filter_idc, alpha_c0_offset_div2, beta_offset_div2,
//       cur block position: bidx, cidx, abv_oop, lef_oop,
//       Per Block Params: {cur/lef/abvle} x {nz, qpy, mv_x, mv_y ,refidx, ipcm }
// Output: 4x4 filtered blocks: cur, lef, ale
// abvle has completed final filtering
// cur is done for current mb row and should be cached for next row. For last row of picture it is complete.

void gg_deblock4x4(int* cur_blk, int* lef_blk, int* ale_blk ,
	                int disable_deblock_filter_idc, int filterOffsetA, int filterOffsetB,
	                int cidx, int bidx, int abv_oop, int lef_oop,
	                int cur_nz, int cur_qp, int cur_mvx, int cur_mvy, int cur_ref, int cur_ipcm, int cur_intra,
					int lef_nz, int lef_qp, int lef_mvx, int lef_mvy, int lef_ref, int lef_ipcm, int lef_intra,
					int ale_nz, int ale_qp, int ale_mvx, int ale_mvy, int ale_ref, int ale_ipcm, int ale_intra
	)
{
	int qpp, qpq, qpavg;
	int indexA, indexB;
	int alpha, beta;
	int filterSamplesFlag;
	int bS;
	int* p0, * p1, * p2, * p3;
	int* q0, * q1, * q2, * q3;
	int p_nxt[4], q_nxt[4];
	int tc, tc0;
	int delta;
	int filter_lef, filter_abv;

	// Flags
	int dc_flag = (cidx == 4 || cidx == 5 || cidx == 6) ? 1 : 0;
	int ac_flag = (cidx == 1 || cidx == 2 || cidx == 3) ? 1 : 0;
	int ch_flag = (cidx == 2 || cidx == 3 || cidx == 4 || cidx == 5) ? 1 : 0;
	int blk_x = ((bidx & 1) ? 1 : 0) + ((bidx & 4) ? 2 : 0);
	int blk_y = ((bidx & 2) ? 1 : 0) + ((bidx & 8) ? 2 : 0);

	// Check if deblocking is disabled and exit
	if (disable_deblock_filter_idc == 1)
		return;

	// Determine if out of pic, and H(lef), V(abv) filter ordering.
	if (lef_oop && blk_x == 0) {
		int filter_lef = -1;
		int filter_abv = -1;
	}
	else if (abv_oop && blk_y == 0) {
		filter_abv = -1;
		filter_lef = 0;
	}
	else if (blk_x == 0) {
		filter_abv = 0;
		filter_lef = 1;
	}
	else {
		filter_abv = 1;
		filter_lef = 0;
	}


	for (int filter_idx = 0; filter_idx < 2; filter_idx++ ) {
		if (filter_idx == filter_lef) { // Horizontal Filter   lef | cur, vertical edge
			// Derive block QPz's to be used for filtering
			qpp = (!ch_flag &&  lef_ipcm) ? 0 :
				  (!ch_flag && !lef_ipcm) ? lef_qp :
				  ( ch_flag &&  lef_ipcm) ? qpc_table[0] : qpc_table[lef_qp];
			qpq = (!ch_flag &&  cur_ipcm) ? 0 :
				  (!ch_flag && !cur_ipcm) ? cur_qp :
				  ( ch_flag &&  cur_ipcm) ? qpc_table[0] : qpc_table[cur_qp];
			// Derive Bs
			if (cur_intra || lef_intra) {
				bS = (blk_x == 0 || blk_y == 0) ? 4 : 3;
			}
			else if (cur_nz || lef_nz) {
				bS = 2;
			}
			else if (cur_ref != lef_ref || ABS(cur_mvx - lef_mvx) >= 4 || ABS(cur_mvy - lef_mvy) >= 4) {
				bS = 1;
			}
			else {
				bS = 0;
			}
		}
		else if (filter_idx == filter_abv) {  // Vertical filter abvle | lef, horizontal edges
			// Derive block QPz's to be used for filtering
			qpp = (!ch_flag &&  ale_ipcm) ? 0 :
				  (!ch_flag && !ale_ipcm) ? ale_qp :
				  ( ch_flag &&  ale_ipcm) ? qpc_table[0] : qpc_table[ale_qp];
			qpq = (!ch_flag &&  lef_ipcm) ? 0 :
				  (!ch_flag && !lef_ipcm) ? lef_qp :
				  ( ch_flag &&  lef_ipcm) ? qpc_table[0] : qpc_table[lef_qp];
			// Derive Bs
			if (ale_intra || lef_intra) {
				bS = (blk_x == 0 || blk_y == 0) ? 4 : 3;
			}
			else if (ale_nz || lef_nz) {
				bS = 2;
			}
			else if (ale_ref != lef_ref || ABS(ale_mvx - lef_mvx) >= 4 || ABS(ale_mvy - lef_mvy) >= 4) {
				bS = 1;
			}
			else {
				bS = 0;
			}
		}

		if (filter_idx == filter_lef || filter_idx == filter_abv) {
			// Determine edge thresholds
			qpavg = (qpp + qpq + 1) >> 1;  // eqn (8-217)
			indexA = CLIP3(0, 51, qpavg + filterOffsetA);
			indexB = CLIP3(0, 51, qpavg + filterOffsetB);
			alpha = alpha_table[indexA];
			beta  = beta_table[indexB];
		    
			// loop and filter along an edge
			for( int ii = 0; ii < 4; ii+=4 ) {
				// Get pel pointers
				if (filter_idx == filter_lef) { // Horizontal Filter   p=lef | q=cur
					p0 = &lef_blk[3 + ii * 4];
					p1 = &lef_blk[2 + ii * 4];
					p2 = &lef_blk[1 + ii * 4];
					p3 = &lef_blk[0 + ii * 4];
					q0 = &cur_blk[0 + ii * 4];
					q1 = &cur_blk[1 + ii * 4];
					q2 = &cur_blk[2 + ii * 4];
					q3 = &cur_blk[3 + ii * 4];
				}
				else /*filter_idx == filter_abv*/ { // Vertical filter p=ale | q=lef 
					p0 = &ale_blk[12 + ii];
					p1 = &ale_blk[ 8 + ii];
					p2 = &ale_blk[ 4 + ii];
					p3 = &ale_blk[ 0 + ii];
					q0 = &lef_blk[ 0 + ii];
					q1 = &lef_blk[ 4 + ii];
					q2 = &lef_blk[ 8 + ii];
					q3 = &lef_blk[12 + ii];
				}
				// Default pels
				p_nxt[0] = *p0;
				p_nxt[1] = *p1;
				p_nxt[2] = *p2;
				q_nxt[0] = *q0;
				q_nxt[1] = *q1;
				q_nxt[2] = *q2;

				// Filtering Process
				filterSamplesFlag = (bS != 0 && ABS(*p0 - *q0) < alpha && ABS(*q1 - *q0) < beta) ? 1 : 0; // eqn (8-224)
				if( filterSamplesFlag && bS == 4 ) { // max filter strength - only for intra mb edges
					// P, Bs==4
					if ((ABS(*p2 - *p0) < beta && ABS(*p0 - *q0) < ((alpha >> 2) + 2))) {
						if (ch_flag) {
							p_nxt[0] = (2 * *p1 + *p0 + *q1 + 2) >> 2;
						}
						else {
							p_nxt[0] = (*p2 + 2 * *p1 + 2 * *p0 + 2 * *q0 + *q1 + 4) >> 3;
							p_nxt[1] = (*p2 + *p1 + *p0 + *q0 + 2) >> 2;
							p_nxt[2] = (2 * *p3 + 3 * *p2 + *p1 + *p0 + *q0 + 4) >> 3;
						}
					}
					// Q, Bs==4
					if ((ABS(*q2 - *q0) < beta && ABS(*p0 - *q0) < ((alpha >> 2) + 2))) {
						if (ch_flag) {
							q_nxt[0] = (2 * *p1 + *q0 + *p1 + 2) >> 2;
						}
						else {
							q_nxt[0] = (*p1 + 2 * *p0 + 2 * *q0 + 2 * *q1 + *q2 + 4) >> 3;
							q_nxt[1] = (*p0 + *q0 + *q1 + *q2 + 2) >> 2;
							q_nxt[2] = (2 * *q3 + 3 * *q2 + *q1 + *q0 + *p0 + 4) >> 3;
						}
					}
				} else if ( filterSamplesFlag ) { // Bs == 1, 2, or 3 
					tc0 = tc0_table[bS - 1][indexA];
					tc = (ch_flag) ? tc0 + 1 : tc0 + ((ABS(*p2 - *p0) < beta) ? 1 : 0) + ((ABS(*q2 - *q0) < beta) ? 1 : 0);
					delta = CLIP3(-tc , tc , ((((*q0 - *p0) << 2) + (*p1 - *q1) + 4) >> 3));
					p_nxt[0] = CLIP1(*p0 + delta);
					q_nxt[0] = CLIP1(*q0 - delta);
					if ( !ch_flag ) {
						p_nxt[1] = *p1 + CLIP3(-tc0, tc0, (*p2 + ((((*p0 + *q0 + 1) >> 1) - (*p1 << 1)) >> 1)));
						q_nxt[1] = *q1 + CLIP3(-tc0, tc0, (*q2 + ((((*p0 + *q0 + 1) >> 1) - (*q1 << 1)) >> 1)));
					}
				}
				// Update pels
				if (filterSamplesFlag) {
					*p0 = p_nxt[0];
					*p1 = p_nxt[1];
					*p2 = p_nxt[2];
					*q0 = q_nxt[0];
					*q1 = q_nxt[1];
					*q2 = q_nxt[2];
				}
			}
		}
	}
}