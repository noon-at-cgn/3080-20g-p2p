# vLLM tensor parallel 2 (HyperQwen): long context with P2P off and on

Two memory-modded RTX 3080 20GB on the platform in the main README, with the modules of this repository. All three
configurations use the same modules: P2P on is the driver default; P2P off is the per-card opt-out
(`RMDynBar1P2PEnable=0` in the per-device string), which leaves CUDA without peer access.

## Setup

- [HyperQwen](https://github.com/syv-ai/HyperQwen) upstream commit `ce9615c`: vLLM 0.31.0, NCCL 2.29.7, `PTH_FA=1`
  (pth_fa attention backend), MTP speculative decoding with 3 speculative tokens per step.
- Model Qwen3.8-27B-W4A16-AutoRound, tensor parallel 2, maximum length 262144.
- Configurations:
  - **base**: P2P off; `NCCL_P2P_DISABLE=1` and `--disable-custom-all-reduce`, so all-reduce goes through shared host
    memory (NCCL `via SHM`).
  - **nccl**: P2P on; `NCCL_P2P_DISABLE=0`, `NCCL_P2P_LEVEL=SYS` (NCCL `via P2P/CUMEM`), custom all-reduce off.
  - **car**: as nccl, plus vLLM's custom all-reduce.
- Prompts of 8k, 32k and 128k tokens, 1 stream and 2 concurrent streams, 256 output tokens, unique prompts (no prefix
  cache hits). Each cell ran 3 times; the tables show the median of the 3 runs.
- Every cell finished; the kernel log had no Xid, AER or DMAR line in any configuration.

## 1 stream

TTFT in seconds; prefill = prompt tokens / TTFT; decode = output tokens per second after the first token.

| Prompt | base: TTFT s / prefill / decode | nccl | car | nccl/base | car/base |
|---|---|---|---|---|---|
| 8k | 3.97 / 2062 / 133.0 | 3.60 / 2273 / 138.3 | 3.62 / 2265 / 148.7 | 0.91 / 1.10 / 1.04 | 0.91 / 1.10 / 1.12 |
| 32k | 17.0 / 1927 / 120.0 | 15.5 / 2113 / 158.0 | 15.6 / 2100 / 157.1 | 0.91 / 1.10 / 1.32 | 0.92 / 1.09 / 1.31 |
| 128k | 88.7 / 1478 / 133.2 | 83.2 / 1575 / 132.4 | 83.1 / 1577 / 144.3 | 0.94 / 1.07 / 0.99 | 0.94 / 1.07 / 1.08 |

## 2 streams, aggregate

| Prompt | base: TTFT s / prefill / decode / end-to-end | nccl | car | nccl/base | car/base |
|---|---|---|---|---|---|
| 8k | 8.06 / 2034 / 83.0 / 50.6 | 7.33 / 2235 / 88.9 / 54.9 | 7.33 / 2236 / 89.1 / 54.8 | 0.91 / 1.10 / 1.07 / 1.08 | 0.91 / 1.10 / 1.07 / 1.08 |
| 32k | 34.5 / 1899 / 43.9 / 14.0 | 31.7 / 2068 / 46.8 / 15.1 | 31.7 / 2068 / 47.0 / 15.1 | 0.92 / 1.09 / 1.07 / 1.08 | 0.92 / 1.09 / 1.07 / 1.08 |
| 128k | 179.4 / 1462 / 29.0 / 2.8 | 168.5 / 1555 / 30.8 / 3.0 | 168.6 / 1555 / 30.5 / 3.0 | 0.94 / 1.06 / 1.06 / 1.07 | 0.94 / 1.06 / 1.05 / 1.07 |

How to read the 2-stream rows:
- TTFT is the time until both streams have their first token; prefill = all prompt tokens / that time.
- Decode = all output tokens / the time during which at least one stream was generating.
- End-to-end = all output tokens / cell wall time, prefill included. With long prompts most of the wall time is
  prefill, so this number is small.
- The two streams are prefilled one after the other, and which one goes first varies from run to run, so
  per-stream rows are not shown.

## Reading

- P2P cuts TTFT by 6-9 % and raises prefill by 6-10 % at every length, with or without custom all-reduce.
- Single-stream decode with NCCL P2P plus custom all-reduce: +12 / +31 / +8 % at 8k / 32k / 128k. MTP speculative
  decoding makes decode noisy; the 32k jump appears with both P2P configurations.
- 2-stream aggregate decode: +5-7 %.
- With vLLM 0.31.0, custom all-reduce costs no prefill.
