# 3080-20g-p2p: GPU peer-to-peer for memory-modded RTX 3080 20GB cards

NVIDIA's open GPU kernel modules 615.71.09 with a patch series that lets two memory-modded RTX 3080 20GB cards copy
directly into each other's memory over PCIe (peer-to-peer, P2P). The stock driver reports no peer access for these
cards, so CUDA, NCCL and vLLM stage every GPU-to-GPU copy through host memory; with these modules the copies go card to
card. It builds on the P2P patches of tinygrad, aikitoria, Duanyll and dingiv (Credits).

## Disclaimer

**Use at your own risk.** This project is provided as is, without warranty of any kind, under NVIDIA's dual MIT/GPLv2
licence (see `COPYING`). I am not responsible or liable for any damage, data loss, hardware
failure, instability, downtime or voided warranty that results from using it. This is an experimental kernel driver
patch: it can hang the machine or corrupt memory.

## Tested on

- Two memory-modded RTX 3080 20GB, `10de:2206`, subsystem `10de:146d`, vBIOS `94.02.27.00.14`
- X99 board with one Xeon E5-2696 v4; each card on its own CPU root port, no PCIe switch
- `intel_iommu=on iommu=pt`, ACS left on
- Linux kernel 7.0.14 (Proxmox), NVIDIA driver userspace 615.71.09

Other GA102 cards (RTX 3080, 3080 Ti, 3090, GA102 A-series) take the same code path but are untested.

## Requirements

- The 32 GiB BAR1 from [3080-20gb-rebar](https://github.com/noon-at-cgn/3080-20gb-rebar), with `RMForceStaticBar1=0`
  set for each card (its `zz-nvidia-static-bar1.conf`). The NVIDIA driver must load from the root file system.
- NVIDIA userspace (libcuda, nvidia-smi) of exactly 615.71.09, and a stock 615.71.09 kernel module for the fallback.
- Kernel headers for the running kernel, `make` and the compiler the kernel was built with.
- IOMMU off, or in passthrough mode (`iommu=pt`).
- Secure Boot off, or the modules signed with a key the machine trusts.

## Results

P2P on against P2P off (no peer access, copies staged through host memory) on the machine above.

| Measurement | P2P on | P2P off |
|---|---|---|
| `p2pBandwidthLatencyTest` unidirectional | 10.27 GB/s | 5.78 GB/s |
| `p2pBandwidthLatencyTest` bidirectional | 19.33 GB/s | 8.66 GB/s |
| P2P write latency | 0.99 µs | 13.6 µs |
| NCCL `all_reduce` bus bandwidth, 1 GiB | 9.33 GB/s | 7.33 GB/s |
| NCCL `all_gather` / `reduce_scatter`, 1 GiB | 8.84 / 8.56 GB/s (about 1.45x) | 6.06 / 5.96 GB/s |
| NCCL `all_reduce` latency, 8 B to 32 KiB | 15-17 µs (1-2 µs slower) | 13-15 µs |

- Correctness: 29/29 byte-exact cases (64 KiB to 1 GiB, `cudaMalloc` and `cuMem`, offsets, both directions, realloc
  stress); a 51-minute soak with vLLM serving (3365 byte-exact runs) and 20 `kill -9` during peer copies: no failures,
  no kernel errors.
- P2P reads are about 10x slower than writes here (10.3 vs 0.99 µs), which matters for software that reads over P2P.

vLLM tensor parallel 2 (HyperQwen upstream, vLLM 0.31), 1 stream, prefill / decode tok/s. Two streams: aggregate
decode +5-7 %. TTFT, 2-stream rows and setup: [results/hyperqwen-long-context.md](results/hyperqwen-long-context.md).

| Prompt | base (P2P off) | nccl (NCCL P2P) | car (NCCL P2P + custom all-reduce) |
|---|---|---|---|
| 8k | 2062 / 133.0 | 2273 / 138.3 (+10 % / +4 %) | 2265 / 148.7 (+10 % / +12 %) |
| 32k | 1927 / 120.0 | 2113 / 158.0 (+10 % / +32 %) | 2100 / 157.1 (+9 % / +31 %) |
| 128k | 1478 / 133.2 | 1575 / 132.4 (+7 % / -1 %) | 1577 / 144.3 (+7 % / +8 %) |

## How it works

The tinygrad-style patches use a *static* BAR1: the whole of VRAM is mapped into BAR1 up front, and peers write
through that mapping. On these cards static BAR1 counts host-visible memory twice and leaves only about half of the
20 GB host-visible (see 3080-20gb-rebar). This series uses *dynamic* BAR1 instead: each allocation a peer accesses
gets its own window in the owner's 32 GiB BAR1 when it is mapped, and the window is removed when it is unmapped.
Nothing maps all of VRAM, so with `RMForceStaticBar1=0` the full 20 GB stays host-visible.

P2P is on by default for pairs of GA102 GPUs (detected by chip family). Other chips use the route only with
`RMDynBar1P2PEnable=1`; pairs with no such GPU, and static-BAR1 pairs that stock NVIDIA supports, behave as stock.
A pair is refused when either card is not GA102 and not enabled by the key, has `RMDynBar1P2PEnable` set to anything
but 1 (the off switch), has static BAR1 active (no `RMForceStaticBar1=0`), has BAR1 smaller than VRAM, or has a
non-zero `nv_dynbar1_calib`/`nv_dynbar1_delta`, or when `RMForceP2PType`/`RMPcieP2PType` excludes BAR1 P2P. A refused
pair gets no peer access (`cudaDeviceCanAccessPeer` 0, copies staged through the host) and rate-limited `DynBar1P2P:`
error lines in the kernel log naming the card and the reason. Like every consumer P2P patch, on GA102 it skips
NVIDIA's chipset, topology and host checks. Tested only on X99 / Xeon E5 v4, two CPU root ports, no switch, `iommu=pt`.

On top of dingiv's dynamic BAR1 branch, this repository adds:

- Managed (UVM) and HMM memory never use a BAR1 peer; their peer copies take the host path, backed by a zeroed sink
  and proven by the read-only counters `uvm_bar1_gate_pairs` and `uvm_bar1_gate_trips` (must stay 0).
- The debug knobs `nv_dynbar1_calib`/`nv_dynbar1_delta` are read-only (non-zero refuses every window), and peer
  windows that are not 2 MiB aligned in BAR1 are refused.
- The second RM mapping route (`NVOS46_FLAGS_P2P`) is refused for a peer without static BAR1, counted in
  `nv_dynbar1_rm_p2p_refused` with a rate-limited log line.
- Teardown and lock fixes: peer windows are drained before the UVM device is freed, under the API lock; a duplicated
  handle's window is freed on every path; a failed lock acquisition never unlocks; the OOM path releases its locks.
- Defaults: no mailbox fallback without a mailbox; the hugepage pin fast path is off (`nv_hugetlb_pin_fast_path`);
  `NVreg_EnableResizableBar` defaults to 0 as in stock; P2P on by default with the refusals above.
- GPUs are probed in PCI bus order, as in the proprietary build, so GPU numbering and the console card stay put.

## Build and install

```sh
git clone https://github.com/noon-at-cgn/3080-20g-p2p && cd 3080-20g-p2p
make modules -j"$(nproc)"
(cd kernel-open && sha256sum nvidia*.ko > SHA256SUMS)    # the pins the scripts check
```

The scripts are in `contrib/3080-20g/`. In `contrib/3080-20g/config.sh`, set `OUT` (the full path of `kernel-open`)
and `GPUS`: the card addresses from `lspci -Dnn -d 10de::0300`, separated by spaces inside one pair of quotes, never
commas, e.g. `GPUS="0000:01:00.0 0000:02:00.0"`. The driver's per-device line uses semicolons instead
(`pci=<address>;RMForceStaticBar1=0;` per card); 3080-20gb-rebar's `install.sh` writes it. Each script takes
`--dry-run` (print the plan, change nothing) or `--yes`, and refuses any `.ko` that does not match `SHA256SUMS`.
Every program using the GPUs must be stopped first (or set `DRAIN_CMD` and `RESTORE_CMD`).

**Load by hand** (nothing installed; a reboot loads what modprobe resolves):

```sh
sudo contrib/3080-20g/p2p-load.sh --yes       # from stock or this build: insmods the build with the options below
sudo contrib/3080-20g/p2p-check.sh            # read-only; exit status = number of FAIL lines
sudo contrib/3080-20g/p2p-rollback.sh --yes   # stock without a reboot (by path if a boot install exists; it stays)
sudo contrib/3080-20g/p2p-rollback.sh --yes --to-installed   # reload the boot install instead
```

Module options used (the per-card string is the one 3080-20gb-rebar writes):

```
nvidia      NVreg_RegistryDwordsPerDevice="pci=0000:01:00.0;RMForceStaticBar1=0;pci=0000:02:00.0;RMForceStaticBar1=0;" NVreg_EnableResizableBar=0
nvidia_uvm  uvm_disable_hmm=1
```

To turn P2P off, add `RMDynBar1P2PEnable=0;` after each card's `RMForceStaticBar1=0;` in that same line (`P2P_ENABLE=0`
in `config.sh`; for the boot install, edit the line in modprobe.d); never set the global `NVreg_RegistryDwords`. The
driver then repeats a rate-limited `... (P2P off)` line, as expected. All tests ran with `uvm_disable_hmm=1`.
Reinstalling 3080-20gb-rebar rewrites `zz-nvidia-static-bar1.conf` without the opt-out: re-add it afterwards.

**Boot install** (verified on one boot on the tested platform):

```sh
sudo contrib/3080-20g/p2p-install.sh --yes    # for the running kernel only
sudo reboot
sudo contrib/3080-20g/p2p-check.sh
```

The installer copies the modules to `/lib/modules/<kernel>/updates/p2p/`, writes `/etc/depmod.d/p2p.conf` (one
`override` per module, this kernel only) and `/etc/modprobe.d/zz-nvidia-p2p.conf`, runs `depmod`, and backs up to
`/var/backups/p2p-modules/`. Stock modules stay in place; other kernels boot stock. Refuses if the initramfs holds nvidia.

**Fallback to stock, one command:** `sudo contrib/3080-20g/p2p-fallback.sh --yes`, then reboot (`--live` also swaps
the running driver). If the P2P kernel does not come up, boot another kernel and run it with `KVER=<P2P kernel>`.

## NCCL and vLLM settings

- For GPUs on separate CPU root ports set `NCCL_P2P_LEVEL=PHB` (or `SYS`); the log then shows `via P2P`, not `via SHM`.
- vLLM's custom all-reduce needs P2P. On vLLM 0.31 it added 8-12 % single-stream decode at 8k and 128k with no prefill
  cost; measure on your vLLM version.
- `VLLM_SKIP_P2P_CHECK` defaults to 1: vLLM trusts `cudaDeviceCanAccessPeer`, so custom all-reduce follows the driver.

## Known behaviour

- Freeing a buffer while a peer copy into it is pending kills that process's CUDA context (Xid 31), as stock does.
- Two `unixCallVideoBIOS ... vesa call failed` lines per `nvidia_drm` unload are benign (stock open modules too).
- nvidia-smi *BAR1 Used* grows when peer access maps a peer's allocations; when BAR1 is full, new peer mappings fail.

## Not tested

- Other cards, boards, CPUs, PCIe switches, mixed pairs, more than two GPUs, driver versions, kernels; Windows.
- GPU or root-port reset while peer windows are open; soaks longer than those above; more than one boot.

## Credits

- [NVIDIA open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules): the driver (`README.NVIDIA.md`).
- [tinygrad](https://github.com/tinygrad/open-gpu-kernel-modules): the original consumer P2P patch over static BAR1,
  2024 ([README](https://github.com/tinygrad/open-gpu-kernel-modules/blob/550.54.15-p2p/README.md)).
- [aikitoria](https://github.com/aikitoria/open-gpu-kernel-modules): ports to newer drivers, NVLink and mixed-generation
  BAR1 P2P, faster hugepage registration ([615.71.09-p2p README](https://github.com/aikitoria/open-gpu-kernel-modules/blob/615.71.09-p2p/README.md)).
- [Duanyll](https://github.com/Duanyll/open-gpu-kernel-modules): dynamic BAR1 P2P ("Method 3", per-allocation windows
  for BAR1 smaller than VRAM) on 615.71.09 with DKMS packaging ([README](https://github.com/Duanyll/open-gpu-kernel-modules/blob/615.71.09-p2p-48g/README.md)).
- [dingiv](https://github.com/dingiv/open-gpu-kernel-modules): the RTX 3080 20GB fixes (2 MiB window placement), mixed
  static/dynamic pairs, `nv_dynbar1_reserve_mb`, and the test documentation in `docs/20g-3080-p2p/` of this tree.

## Licence

NVIDIA's dual MIT/GPLv2 licence, unchanged; see `COPYING`.
