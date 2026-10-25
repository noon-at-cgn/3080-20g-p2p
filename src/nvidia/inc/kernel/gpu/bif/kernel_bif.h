
#include "g_kernel_bif_nvoc.h"

// 3080-20g: dynamic BAR1 P2P route armed on this GPU (GA102, or
// RMDynBar1P2PEnable=1); defined in kernel_bif.c.
NvBool dynBar1P2PIsArmed(OBJGPU *pGpu);

// 3080-20g: rate-limited refusal line of that route; defined in kernel_bif.c.
void dynBar1P2PLogRefusal(OBJGPU *pGpu, const char *pReason, NvU32 gpuInst0, NvU32 gpuInst1);

