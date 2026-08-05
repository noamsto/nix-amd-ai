# Bench logs

Raw `llama-bench` output kept for provenance behind decisions made elsewhere.
All runs on Strix Point (gfx1150, Radeon 890M, 64 GiB DDR5-5600).

| Run | What it tested | Outcome |
| --- | --- | --- |
| `rocwmma-2026-05-19` | llama.cpp with the rocWMMA flash-attn build flag vs a plain ROCm baseline | **Net regression** — `pp4096` 368.50 → 213.84 t/s (−42%) at head_dim 256. Flag left off. |
| `mtp-2026-05-24` | `--mtp-ab` decode A/B on a 27B model | Provisional — not run on an idle GPU under the performance power profile, so the deltas are not authoritative. |
| `mtp-2026-05-31` | same A/B via the Go benchmark TUI | Provisional, same caveat. |

The rocWMMA result is why `llama-cpp-rocm` ships plain; see
`docs/therock-eval-results.md`, which argues rocWMMA should be **on** for
gfx1151 even though it loses here on gfx1150.
