#include <stdio.h>
#include "gg_process.h"
#include "gg_deblock.h"

// Init frame deblocking structure
void gg_deblock_init(DeblockCtx* dbp, int disable_deblock_filter_idc, int filterOffsetA, int filterOffsetB, int mb_width, int mb_height ) {

	// save slice params
	dbp->disable_deblock_filter_idc = disable_deblock_filter_idc;
	dbp->filterOffsetA = filterOffsetA;
	dbp->filterOffsetB = filterOffsetB;
	dbp->mb_width = mb_width;
	dbp->mb_height = mb_height;

	// init buffers
	for (int ii = 0; ii < 1024; ii++) { // mark above row out of pic
		dbp->abv[ii].oop = 1;
	}
	for (int ii = 0; ii < 64; ii++) {
		dbp->ring[ii].oop = 1; // mark buffer as out of pic
	}
	// init pointers
	dbp->mbx = 0;
	dbp->ring_idx = 0;
}

void deblock_c4(DeblockCtx* dbp, int bidx, int vert_flag, BlkInfo* q_blk, BlkInfo* p_blk, int* bS)
{
	int qpp, qpq, qpavg;
	int indexA, indexB;
	int alpha, beta;
	int filterSamplesFlag;

	int* p0, * p1, * p2, * p3;
	int* q0, * q1, * q2, * q3;
	int p_nxt[4], q_nxt[4];
	int tc, tc0;
	int delta;

	// Flags
	int blk_x = (bidx & 1) ? 1 : 0;
	int blk_y = (bidx & 2) ? 1 : 0;

	// Check if deblocking is disabled and exit
	//if (dbp->disable_deblock_filter_idc == 1)
	//	return;

	// Check if prev is out of picture
	if (p_blk->oop)
		return;

	// Derive block QPz's to be used for filtering
	qpp = (p_blk->mb_type == GG_MBTYPE_IPCM) ? qpc_table[0] : qpc_table[p_blk->qp];
	qpq = (q_blk->mb_type == GG_MBTYPE_IPCM) ? qpc_table[0] : qpc_table[q_blk->qp];
	qpavg = (qpp + qpq + 1) >> 1;  // eqn (8-217)

	// Determine edge thresholds
	indexA = CLIP3(0, 51, qpavg + dbp->filterOffsetA);
	indexB = CLIP3(0, 51, qpavg + dbp->filterOffsetB);
	alpha = alpha_table[indexA];
	beta = beta_table[indexB];

	// loop and filter along an edge
	for (int ii = 0; ii < 4; ii++) {
		// Get pel pointers
		if (!vert_flag) { // Horizontal Filter  
			p0 = &p_blk->d[3 + ii * 4];
			p1 = &p_blk->d[2 + ii * 4];
			p2 = &p_blk->d[1 + ii * 4];
			p3 = &p_blk->d[0 + ii * 4];
			q0 = &q_blk->d[0 + ii * 4];
			q1 = &q_blk->d[1 + ii * 4];
			q2 = &q_blk->d[2 + ii * 4];
			q3 = &q_blk->d[3 + ii * 4];
		}
		else { // Vertical filter
			p0 = &p_blk->d[12 + ii];
			p1 = &p_blk->d[8 + ii];
			p2 = &p_blk->d[4 + ii];
			p3 = &p_blk->d[0 + ii];
			q0 = &q_blk->d[0 + ii];
			q1 = &q_blk->d[4 + ii];
			q2 = &q_blk->d[8 + ii];
			q3 = &q_blk->d[12 + ii];
		}
		// Default pels
		p_nxt[0] = *p0;
		q_nxt[0] = *q0;

		// Filtering Process
		filterSamplesFlag = (bS[ii >> 1] != 0 && ABS(*p0 - *q0) < alpha && ABS(*q1 - *q0) < beta && ABS(*p1 - *p0) < beta) ? 1 : 0; // eqn (8-224)
		if (filterSamplesFlag && bS[ii >> 1] == 4) { // max filter strength - only for intra mb edges
			// P, Bs==4
			if ((ABS(*p2 - *p0) < beta && ABS(*p0 - *q0) < ((alpha >> 2) + 2))) {
				p_nxt[0] = (2 * *p1 + *p0 + *q1 + 2) >> 2;
			}
			// Q, Bs==4
			if ((ABS(*q2 - *q0) < beta && ABS(*p0 - *q0) < ((alpha >> 2) + 2))) {
				q_nxt[0] = (2 * *p1 + *q0 + *p1 + 2) >> 2;
			}
		}
		else if (filterSamplesFlag && bS[ii>>1] ) { // Bs == 1, 2, or 3 
			tc0 = tc0_table[bS[ii >> 1] - 1][indexA];
			tc = tc0 + 1;
			delta = CLIP3(-tc, tc, ((((*q0 - *p0) << 2) + (*p1 - *q1) + 4) >> 3));
			p_nxt[0] = CLIP1(*p0 + delta);
			q_nxt[0] = CLIP1(*q0 - delta);
		}
		// Update pels
		*p0 = p_nxt[0];
		*q0 = q_nxt[0];
	}
}

void deblock_y4(DeblockCtx* dbp, int bidx, int vert_flag, BlkInfo* q_blk, BlkInfo* p_blk, int* bS)
{
	int qpp, qpq, qpavg;
	int indexA, indexB;
	int alpha, beta;
	int filterSamplesFlag;
	int* p0, * p1, * p2, * p3;
	int* q0, * q1, * q2, * q3;
	int p_nxt[4], q_nxt[4];
	int tc, tc0;
	int delta;

	// Flags
	int blk_x = ((bidx & 1) ? 1 : 0) + ((bidx & 4) ? 2 : 0);
	int blk_y = ((bidx & 2) ? 1 : 0) + ((bidx & 8) ? 2 : 0);

	// Check if deblocking is disabled and exit
	//if (dbp->disable_deblock_filter_idc == 1)
	//	return;

	// Check if prev is out of picture
	if (p_blk->oop)
		return;

	// Derive block QPz's to be used for filtering
	qpp = (p_blk->mb_type == GG_MBTYPE_IPCM) ? 0 : p_blk->qp;
	qpq = (q_blk->mb_type == GG_MBTYPE_IPCM) ? 0 : q_blk->qp;
	qpavg = (qpp + qpq + 1) >> 1;  // eqn (8-217)

	// Derive Bs
	if (p_blk->mb_type == GG_MBTYPE_INTRA || q_blk->mb_type == GG_MBTYPE_INTRA) {
		*bS = (blk_x == 0 && !vert_flag || blk_y == 0 && vert_flag) ? 4 : 3;
	}
	else if (p_blk->nz || q_blk->nz) {
		*bS = 2;
	}
	else if (p_blk->refidx != q_blk->refidx || ABS(p_blk->mvx - q_blk->mvx) >= 4 || ABS(p_blk->mvy - q_blk->mvy) >= 4) {
		*bS = 1;
	}
	else {
		*bS = 0;
	}

	// Determine edge thresholds
	indexA = CLIP3(0, 51, qpavg + dbp->filterOffsetA);
	indexB = CLIP3(0, 51, qpavg + dbp->filterOffsetB);
	alpha = alpha_table[indexA];
	beta = beta_table[indexB];

	// loop and filter along an edge
	for (int ii = 0; ii < 4; ii++ ) {
		// Get pel pointers
		if (!vert_flag) { // Horizontal Filter  
			p0 = &p_blk->d[3 + ii * 4];
			p1 = &p_blk->d[2 + ii * 4];
			p2 = &p_blk->d[1 + ii * 4];
			p3 = &p_blk->d[0 + ii * 4];
			q0 = &q_blk->d[0 + ii * 4];
			q1 = &q_blk->d[1 + ii * 4];
			q2 = &q_blk->d[2 + ii * 4];
			q3 = &q_blk->d[3 + ii * 4];
		}
		else { // Vertical filter
			p0 = &p_blk->d[12 + ii];
			p1 = &p_blk->d[8 + ii];
			p2 = &p_blk->d[4 + ii];
			p3 = &p_blk->d[0 + ii];
			q0 = &q_blk->d[0 + ii];
			q1 = &q_blk->d[4 + ii];
			q2 = &q_blk->d[8 + ii];
			q3 = &q_blk->d[12 + ii];
		}
		// Default pels
		p_nxt[0] = *p0;
		p_nxt[1] = *p1;
		p_nxt[2] = *p2;
		q_nxt[0] = *q0;
		q_nxt[1] = *q1;
		q_nxt[2] = *q2;

		// Filtering Process
		filterSamplesFlag = (*bS != 0 && ABS(*p0 - *q0) < alpha && ABS(*q1 - *q0) < beta && ABS(*p1 - *p0) < beta) ? 1 : 0; // eqn (8-224)
		if (filterSamplesFlag && *bS == 4) { // max filter strength - only for intra mb edges
			// P, Bs==4
			if (ABS(*p2 - *p0) < beta && ABS(*p0 - *q0) < ((alpha >> 2) + 2)) {
				p_nxt[0] = (*p2 + 2 * *p1 + 2 * *p0 + 2 * *q0 + *q1 + 4) >> 3;
				p_nxt[1] = (*p2 + *p1 + *p0 + *q0 + 2) >> 2;
				p_nxt[2] = (2 * *p3 + 3 * *p2 + *p1 + *p0 + *q0 + 4) >> 3;
			}
			// Q, Bs==4
			if (ABS(*q2 - *q0) < beta && ABS(*p0 - *q0) < ((alpha >> 2) + 2)) {
				q_nxt[0] = (*p1 + 2 * *p0 + 2 * *q0 + 2 * *q1 + *q2 + 4) >> 3;
				q_nxt[1] = (*p0 + *q0 + *q1 + *q2 + 2) >> 2;
				q_nxt[2] = (2 * *q3 + 3 * *q2 + *q1 + *q0 + *p0 + 4) >> 3;
			}
		}
		else if (filterSamplesFlag && *bS) { // Bs == 1, 2, or 3 
			tc0 = tc0_table[*bS - 1][indexA];
			tc = tc0 + ((ABS(*p2 - *p0) < beta) ? 1 : 0) + ((ABS(*q2 - *q0) < beta) ? 1 : 0);
			delta = CLIP3(-tc, tc, ((((*q0 - *p0) << 2) + (*p1 - *q1) + 4) >> 3));
			p_nxt[0] = CLIP1(*p0 + delta);
			q_nxt[0] = CLIP1(*q0 - delta);
			if (ABS(*p2 - *p0) < beta) {
				p_nxt[1] = *p1 + CLIP3(-tc0, tc0, (*p2 + ((*p0 + *q0 + 1) >> 1) - (*p1 << 1)) >> 1);
			}
			if (ABS(*q2 - *q0) < beta) {
				q_nxt[1] = *q1 + CLIP3(-tc0, tc0, (*q2 + ((*p0 + *q0 + 1) >> 1) - (*q1 << 1)) >> 1);
			}
		}
		// Update pels
		*p0 = p_nxt[0];
		*p1 = p_nxt[1];
		*p2 = p_nxt[2];
		*q0 = q_nxt[0];
		*q1 = q_nxt[1];
		*q2 = q_nxt[2];
	}
}

#define WriteBlkY(r, x, y, b) { for (int py = 0; py < 4; py++) for (int px = 0; px < 4; px++) \
				(r)[(mby * 16 + (y) * 4 + py) * dbp->mb_width * 16 + mbx * 16 + (x) * 4 + px] = 0xff & (b)->d[py * 4 + px];}
#define WriteBlkC(r, x, y, b) { for (int py = 0; py < 4; py++) for (int px = 0; px < 4; px++) \
				(r)[(mby * 8 + (y) * 4 + py) * dbp->mb_width * 8 + mbx * 8 + (x) * 4 + px] = 0xff & (b)->d[py * 4 + px];}
#define CopyBlk( dest, src ) {  *dest = *src; }

#define AlePtr( x )  (&(dbp->abv[(mbx*8+(x)+1024-8)&0x3ff]))
#define AbvPtr( x )  (&(dbp->abv[(mbx*8+(x)+1024)&0x3ff]))
#define LefPtr( x )  (&(dbp->ring[((x)+64-24+dbp->ring_idx)&0x3f]))
#define BlkPtr( x )  (&(dbp->ring[((x)+64+dbp->ring_idx)&0x3f]))

void gg_deblock_mb(DeblockCtx* dbp, int mbx, int mby, char *recon_y, char *recon_cb, char *recon_cr, int *num_coeff_y, int* num_coeff_cb, int *num_coeff_cr, int qp, int refidx, int mb_type)
{
	int bidx;
	int blkx, blky;

	// No function if deblocking disabled
	if (dbp->disable_deblock_filter_idc == 1)
		return;

	// advance ring pointer by 24 mod 64
	dbp->ring_idx = (dbp->ring_idx + 24) & 0x3F;

	//if (mbx == 6 && mby == 4)
	//	printf("Z");

	// load macroblock's block & info into ring in decode order
	for (bidx = 0; bidx < 24; bidx++) {
		blkx = ((bidx & 1) ? 1 : 0) + ((bidx < 16) ? ((bidx & 4) ? 2 : 0) : 0);
		blky = ((bidx & 2) ? 1 : 0) + ((bidx < 16) ? ((bidx & 8) ? 2 : 0) : 0);
		BlkPtr(bidx)->mb_type = mb_type;
		BlkPtr(bidx)->qp = qp;
		BlkPtr(bidx)->refidx = refidx;
		BlkPtr(bidx)->mvx = 0;
		BlkPtr(bidx)->mvy = 0;
		BlkPtr(bidx)->oop = 0;
		BlkPtr(bidx)->nz = ( bidx < 16 ) ? ((num_coeff_y[bidx]) ? 1 : 0) : ( bidx < 20 ) ? ((num_coeff_cb[bidx - 16]) ? 1 : 0) : ((num_coeff_cr[bidx - 20]) ? 1 : 0);
		for (int py = 0; py < 4; py++) {
			for (int px = 0; px < 4; px++) {
				if (bidx < 16) { // y
					BlkPtr(bidx)->d[py * 4 + px] = 0xff & recon_y[mbx * 16 + blkx * 4 + px + (mby * 16 + blky * 4 + py) * dbp->mb_width * 16];
				}
				else if (bidx < 20) { // cb
					BlkPtr(bidx)->d[py * 4 + px] = 0xff & recon_cb[mbx * 8 + blkx * 4 + px + (mby * 8 + blky * 4 + py) * dbp->mb_width * 8];
				}
				else { // cr
					BlkPtr(bidx)->d[py * 4 + px] = 0xff & recon_cr[mbx * 8 + blkx * 4 + px + (mby * 8 + blky * 4 + py) * dbp->mb_width * 8];
				}
			}
		}
	}

	int bSh[16], bSv[16]; // bS's calculated during luma in spec order, and read by chroma processing

	//////////////////////////////////////////////////////////////
	//
	//             D E B L O C K _ A _ M A C R O B L O C K
	//
	//////////////////////////////////////////////////////////////

	// Y Horiz
	if (mbx) {
		deblock_y4(dbp, 0, 0, BlkPtr(0), LefPtr(5), &bSh[0]);
		deblock_y4(dbp, 2, 0, BlkPtr(2), LefPtr(7), &bSh[1]);
		deblock_y4(dbp, 8, 0, BlkPtr(8), LefPtr(13), &bSh[2]);
		deblock_y4(dbp, 10, 0, BlkPtr(10), LefPtr(15), &bSh[3]);
	}

	deblock_y4(dbp, 1 , 0, BlkPtr(1), BlkPtr(0), &bSh[4]);
	deblock_y4(dbp, 3 , 0, BlkPtr(3), BlkPtr(2), &bSh[5]);
	deblock_y4(dbp, 9 , 0, BlkPtr(9), BlkPtr(8), &bSh[6]);
	deblock_y4(dbp, 11, 0, BlkPtr(11), BlkPtr(10), &bSh[7]);

	deblock_y4(dbp, 4 , 0, BlkPtr(4), BlkPtr(1), &bSh[8]);
	deblock_y4(dbp, 6 , 0, BlkPtr(6), BlkPtr(3), &bSh[9]);
	deblock_y4(dbp, 12, 0, BlkPtr(12), BlkPtr(9), &bSh[10]);
	deblock_y4(dbp, 14, 0, BlkPtr(14), BlkPtr(11), &bSh[11]);

	deblock_y4(dbp, 5 , 0, BlkPtr(5), BlkPtr(4), &bSh[12]);
	deblock_y4(dbp, 7 , 0, BlkPtr(7), BlkPtr(6), &bSh[13]);
	deblock_y4(dbp, 13, 0, BlkPtr(13), BlkPtr(12), &bSh[14]);
	deblock_y4(dbp, 15, 0, BlkPtr(15), BlkPtr(14), &bSh[15]);

	// Y Vert
	if (mby) {
		deblock_y4(dbp, 0, 1, BlkPtr(0), AbvPtr(0), &bSv[0]);
		deblock_y4(dbp, 1, 1, BlkPtr(1), AbvPtr(1), &bSv[1]);
		deblock_y4(dbp, 4, 1, BlkPtr(4), AbvPtr(2), &bSv[2]);
		deblock_y4(dbp, 5, 1, BlkPtr(5), AbvPtr(3), &bSv[3]);
	}

	deblock_y4(dbp, 2, 1, BlkPtr(2), BlkPtr(0), &bSv[4]);
	deblock_y4(dbp, 3, 1, BlkPtr(3), BlkPtr(1), &bSv[5]);
	deblock_y4(dbp, 6, 1, BlkPtr(6), BlkPtr(4), &bSv[6]);
	deblock_y4(dbp, 7, 1, BlkPtr(7), BlkPtr(5), &bSv[7]);

	deblock_y4(dbp, 8, 1, BlkPtr(8), BlkPtr(2), &bSv[8]);
	deblock_y4(dbp, 9, 1, BlkPtr(9), BlkPtr(3), &bSv[9]);
	deblock_y4(dbp, 12, 1, BlkPtr(12), BlkPtr(6), &bSv[10]);
	deblock_y4(dbp, 13, 1, BlkPtr(13), BlkPtr(7), &bSv[11]);

	deblock_y4(dbp, 10, 1, BlkPtr(10), BlkPtr(8), &bSv[12]);
	deblock_y4(dbp, 11, 1, BlkPtr(11), BlkPtr(9), &bSv[13]);
	deblock_y4(dbp, 14, 1, BlkPtr(14), BlkPtr(12), &bSv[14]);
	deblock_y4(dbp, 15, 1, BlkPtr(15), BlkPtr(13), &bSv[15]);

	// Cb Horix
	if (mbx) {
		deblock_c4(dbp, 0, 0, BlkPtr(16), LefPtr(17), &bSh[0]);
		deblock_c4(dbp, 2, 0, BlkPtr(18), LefPtr(19), &bSh[2]);
	}

	deblock_c4(dbp, 1, 0, BlkPtr(17), BlkPtr(16), &bSh[8]);
	deblock_c4(dbp, 3, 0, BlkPtr(19), BlkPtr(18), &bSh[10]);

	// Cb Vert
	if (mby) {
		deblock_c4(dbp, 0, 1, BlkPtr(16), AbvPtr(4), &bSv[0]);
		deblock_c4(dbp, 1, 1, BlkPtr(17), AbvPtr(5), &bSv[2]);
	}

	deblock_c4(dbp, 2, 1, BlkPtr(18), BlkPtr(16), &bSv[8]);
	deblock_c4(dbp, 3, 1, BlkPtr(19), BlkPtr(17), &bSv[10]);

	// Cr Horiz
	if (mbx) {
		deblock_c4(dbp, 0, 0, BlkPtr(20), LefPtr(21), &bSh[0]);
		deblock_c4(dbp, 2, 0, BlkPtr(22), LefPtr(23), &bSh[2]);
	}

	deblock_c4(dbp, 1, 0, BlkPtr(21), BlkPtr(20), &bSh[8]);
	deblock_c4(dbp, 3, 0, BlkPtr(23), BlkPtr(22), &bSh[10]);

	// Cr Vert
	if (mby) {
		deblock_c4(dbp, 0, 1, BlkPtr(20), AbvPtr(6), &bSv[0]);
		deblock_c4(dbp, 1, 1, BlkPtr(21), AbvPtr(7), &bSv[2]);
	}

	deblock_c4(dbp, 2, 1, BlkPtr(22), BlkPtr(20), &bSv[8]);
	deblock_c4(dbp, 3, 1, BlkPtr(23), BlkPtr(21), &bSv[10]);

	/////////////////////////////
	// Write Recon Blocks
	/////////////////////////////

	if (mby) { // not Top Pic Edge
		WriteBlkY(recon_y , 0, -1, AbvPtr(0));
		WriteBlkY(recon_y , 1, -1, AbvPtr(1));
		WriteBlkY(recon_y , 2, -1, AbvPtr(2));
		WriteBlkY(recon_y , 3, -1, AbvPtr(3));
		WriteBlkC(recon_cb, 0, -1, AbvPtr(4));
		WriteBlkC(recon_cb, 1, -1, AbvPtr(5));
		WriteBlkC(recon_cr, 0, -1, AbvPtr(6));
		WriteBlkC(recon_cr, 1, -1, AbvPtr(7));
	}

	if (mbx) { // not Left Pic Edge
		WriteBlkY(recon_y , -1, 0, LefPtr(5));
		WriteBlkY(recon_y , -1, 1, LefPtr(7));
		WriteBlkY(recon_y , -1, 2, LefPtr(13));
		WriteBlkC(recon_cb, -1, 0, LefPtr(17));
		WriteBlkC(recon_cr, -1, 0, LefPtr(21));
	}

	// Inside Pic
	WriteBlkY(recon_y , 0, 0, BlkPtr(0));
	WriteBlkY(recon_y , 0, 1, BlkPtr(2));
	WriteBlkY(recon_y , 0, 2, BlkPtr(8));
	WriteBlkC(recon_cb, 0, 0, BlkPtr(16));
	WriteBlkC(recon_cr, 0, 0, BlkPtr(20));

	WriteBlkY(recon_y, 1, 0, BlkPtr(1));
	WriteBlkY(recon_y, 1, 1, BlkPtr(3));
	WriteBlkY(recon_y, 1, 2, BlkPtr(9));

	WriteBlkY(recon_y, 2, 0, BlkPtr(4));
	WriteBlkY(recon_y, 2, 1, BlkPtr(6));
	WriteBlkY(recon_y, 2, 2, BlkPtr(12));

	if (mbx == dbp->mb_width - 1) { // Right Pic Edge
		WriteBlkY(recon_y , 3, 0, BlkPtr(5));
		WriteBlkY(recon_y , 3, 1, BlkPtr(7));
		WriteBlkY(recon_y , 3, 2, BlkPtr(13));
		WriteBlkC(recon_cb, 1, 0, BlkPtr(17));
		WriteBlkC(recon_cr, 1, 0, BlkPtr(21));
	}

	if (mby == dbp->mb_height - 1) { // Bottom Pic Edge
		WriteBlkY(recon_y , 0, 3, BlkPtr(10));
		WriteBlkY(recon_y , 1, 3, BlkPtr(11));
		WriteBlkY(recon_y , 2, 3, BlkPtr(14));
		WriteBlkC(recon_cb, 0, 1, BlkPtr(18));
		WriteBlkC(recon_cr, 0, 1, BlkPtr(22));
	}

	if (mby == dbp->mb_height - 1 && mbx) { // not Left of Bottom Edge
		WriteBlkY(recon_y , -1, 3, LefPtr(15));
		WriteBlkC(recon_cb, -1, 1, LefPtr(19));
		WriteBlkC(recon_cr, -1, 1, LefPtr(23));
	}

	if (mby == dbp->mb_height - 1 && mbx == dbp->mb_width - 1) { // Bottom Right Pic Corner
		WriteBlkY(recon_y, 3, 3, BlkPtr(15));
		WriteBlkC(recon_cb, 1, 1, BlkPtr(19));
		WriteBlkC(recon_cr, 1, 1, BlkPtr(23));
	}

	/////////////////////////////
	// Copy partials to Abv buf
	/////////////////////////////

	if (mbx) {
		CopyBlk(AlePtr(3), LefPtr(15)); // Y
		CopyBlk(AlePtr(5), LefPtr(19)); // Cb
		CopyBlk(AlePtr(7), LefPtr(23)); // Cr
	}

	CopyBlk(AbvPtr(0), BlkPtr(10)); // Y 10
	CopyBlk(AbvPtr(1), BlkPtr(11)); // Y 11
	CopyBlk(AbvPtr(2), BlkPtr(14)); // Y 14
	CopyBlk(AbvPtr(4), BlkPtr(18)); // Cb 2
	CopyBlk(AbvPtr(6), BlkPtr(22)); // Cr 2

	if (mbx == dbp->mb_width - 1) {
		CopyBlk(AbvPtr(3), BlkPtr(15)); // Y
		CopyBlk(AbvPtr(5), BlkPtr(19)); // Cb
		CopyBlk(AbvPtr(7), BlkPtr(23)); // Cr
	}
}


