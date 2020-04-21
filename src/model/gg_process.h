#pragma once
#include "gg_process_tables.h"

typedef struct _bitbuffer {
    int num;
    vlc_t vlc[64];
} bitbuffer;

int gg_process_block(int qpy, int offset, int deadzone, int* ref, int* orig, int* dc_hold, int cidx, int bidx, char *lefnc, char *abvnc, int* recon, bitbuffer *bits, int* bitcount, int* sad, int* ssd);
void test_run_before();