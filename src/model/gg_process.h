
#include "gg_process_tables.h"

#define CLIP3(x,y,z) (((z)<(x))?(x):((z)>(y))?(y):(z))
#define CLIP1(z) CLIP3(0,255,(z))
#define SSD(x) ((x)*(x))
#define SAD(x) ((x<0)?(-(x)):(x))
#define ABS(x) (((x)<0)?(-(x)):(x))
#define MIN(x,y) ((x)<(y)?(x):(y))
#define MAX(x,y) ((x)>(y)?(x):(y))

typedef struct _bitbuffer {
    int num;
    vlc_t vlc[64];
} bitbuffer;

int gg_process_block(int qpy, int offset, int deadzone, int* ref, int* orig, int* dc_hold, int cidx, int bidx, char *lefnc, char *abvnc, int* recon, bitbuffer *bits, int* bitcount, int* sad, int* ssd);
int gg_iprocess_block(int qpy, int* ref, int* dc_hold, int cidx, int bidx, char* lefnc, char* abvnc, int* recon, bitbuffer* bits, int skip);
void test_run_before();
