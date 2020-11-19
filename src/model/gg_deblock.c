#include <stdio.h>
#include "gg_process.h"

// Low level deblock Filter.
// Input: 4x4 recon blocks, pi, qi
// Output: 4x4 filtered blocks, po, qo.
// Parameters: vert_edge (2 horizontal blocks

//void gg_deblock_filter(int* p, int* q, int* po, int* qo, int qpy, int disable_deblock_filter_idc, int cidx, int bidx, int  offset, int deadzone, int* ref, int* orig, int* dc_hold, char* lefnc, char* abvnc, int* recon, bitbuffer* bits, int* bitcount, int* sad, int* ssd)
//{
//	int p[16], q[16]; // Horizontal blocks
//
//// Transpose as need to horizontal filtering
//
//// Calculate Block Strength bS
//	// Based on mbedge, intra_p, intra_q, nc_p, nc_q, diff_pred
//}