---
name: Compatibility report
about: Report whether GPU-to-GPU P2P works on your cards and platform
title: "[compat] <cards> <board/CPU> <kernel>"
labels: compatibility
---

<!-- Remove serial numbers, GPU UUIDs, hostnames and IP addresses before posting. -->

## Cards

- Model, board vendor and VRAM of each card:
- IDs (`lspci -Dnn -d 10de::0300`):
- Memory-modded or stock:
- vBIOS version (`nvidia-smi -q | grep -i vbios`):
- 3080-20gb-rebar installed, BAR1 32 GiB on every card (`nvidia-smi -q -d MEMORY`)? yes / no

## Platform

- Motherboard and CPU:
- How the cards connect (CPU root ports, chipset, PCIe switch):
- PCIe generation and width per card (`nvidia-smi -q` or `lspci -vv` LnkSta):
- IOMMU mode (kernel command line, e.g. `intel_iommu=on iommu=pt`):
- ACS state, if known:
- Kernel and distribution:
- Bare metal, VM passthrough, or LXC / containers:

## Driver

- Userspace driver version (must be 615.71.09):
- How the modules were built and installed (load by hand with `p2p-load.sh`, or boot install with `p2p-install.sh`):
- Secure Boot on or off (module signing?):

## Results

```
paste the full output of: sudo contrib/3080-20g/p2p-check.sh
```

```
paste the output of: nvidia-smi topo -p2p r   and   nvidia-smi topo -p2p w
```

Optional:
- `p2pBandwidthLatencyTest` or nvbandwidth numbers:
- NCCL test numbers (nccl-tests, with `NCCL_P2P_LEVEL`):
- Workload results with P2P on and off, same settings (engine, model, tensor parallel size, prompt length):

## Errors

- Xid, AER or DMAR lines in `dmesg`:
- `DynBar1P2P:` lines in `dmesg`:

## Notes
