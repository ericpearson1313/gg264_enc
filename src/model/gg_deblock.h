#pragma once

typedef struct _BlkInfo {
	int d[16]; // pixel data
	int mb_type;
	int qp;
	int nz;
	int oop;
	int mvx;
	int mvy;
	int refidx;
} BlkInfo;

typedef struct _DeblockCtx {

	// Slice Params
	int disable_deblock_filter_idc;
	int filterOffsetA;
	int filterOffsetB;
	int mb_width;
	int mb_height;

	// above/below row buffers of 4x4 blocks
	BlkInfo abv[1024]; // pack y[4],cb[2],cr[2]
	int mbx; // pointer into above arrays

    // ring buffer of 4x4 blocks
	BlkInfo ring[64];
	int ring_idx; // pointer into ring array

} DeblockCtx;

void gg_deblock_init(DeblockCtx* dbp, int disable_deblock_filter_idc, int filterOffsetA, int filterOffsetB, int mb_width, int mb_height);
void gg_deblock_mb(DeblockCtx* dbp, int mbx, int mby, char* recon_y, char* recon_cb, char* recon_cr, int* num_coeff_y, int* num_coeff_cb, int* num_coeff_cr, int qp, int refidx, int mb_type);