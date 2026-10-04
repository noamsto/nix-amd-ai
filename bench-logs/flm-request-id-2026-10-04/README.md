# `flm serve`: `/api/cancel` reaches its target, default request ids are random (#210), on halo

Probe: [`cancel-guess.sh`](cancel-guess.sh), `llama3.2:1b`, one `flm serve` per
build, started only when no other `flm` process was running.

- **guess:** a streaming `/api/generate` with no `request_id` (the victim) is
  decoding while the probe POSTs `/api/cancel` for `req_0` … `req_255`.
  Contract: no guess answers `cancelled: true`, and the victim does not end
  with `done_reason: "cancel"`.
- **own-id:** a streaming `/api/generate` with `request_id: "own-<n>"`,
  cancelled by that id after its first chunk. Contract: `cancelled: true` and
  the stream ends with `done_reason: "cancel"`.

| build | guess: hits | guess: victim | own-id |
|---|---|---|---|
| `main` (dc4cd36) | 256 of 256 `cancelled: true` | `stop`, 1491 chunks: never cancelled | `cancelled: true`, stream kept decoding, no done line within 30s |
| cancel fix only, counter ids (evidence-only) | 1 of 256: `req_1` | `cancel` after 42 chunks | `cancelled: true`, `cancel` |
| this branch | 0 of 256 | `length`, 4097 chunks | `cancelled: true`, `cancel` |

On `main` every `/api/cancel` "succeeded" and none stopped anything. The
cancel request registered its own token under the `request_id` in its body,
overwriting the target's slot. It then found and cancelled itself and erased
the slot, so the target became uncancellable.

The middle row shows why the two fixes ship together. Once cancel reaches its
target, the old counter ids are guessable: `req_0` went to the probe's
`/api/version` readiness poll, so the victim was `req_1`, and guessing it
cancelled the victim.

Default ids from this branch, from an evidence-only build that printed each id
to stderr (not shipped). They are the readiness poll, the victim, four cancels
and the own-id's cancel, in arrival order:

```
GET /api/version   req_d67fc111a69749c2ad291ab444e71988
POST /api/generate req_3c1a34ba851145b105ec0374a28bc15a
POST /api/cancel   req_b36498e633449937b1556c533fd7f501
POST /api/cancel   req_255133e98effe98bce08ff6be0eb1719
POST /api/cancel   req_a9855e244446af6d1fa5b8cb9a89cb71
POST /api/cancel   req_725bba698c8ade87d793cb49ace0841f
POST /api/generate own-2817712940
POST /api/cancel   req_35876a7c162f4fb959f8e47f6b4ef6a3
```

Limits: a default id is never returned to the client, so a request without a
`request_id` can now be cancelled only by disconnecting. A caller-supplied
`request_id` is cancellable by anyone who knows it, because `/api/cancel` has no
ownership check.

## Reproduce

```
nix build .#fastflowlm --no-link --print-out-paths   # red on dc4cd36, green here
FLM=<fastflowlm out path>/bin/flm
export XRT_LIB=<xrt-combined out path>/lib
bash bench-logs/flm-request-id-2026-10-04/cancel-guess.sh $FLM <out dir> <label>
```

The evidence-only builds add one more patch through
`fastflowlm.overrideAttrs (o: { patches = o.patches ++ [ <patch> ]; })`. For the
middle row the patch restores the old counter. For the id sample it prints
`request_id` before `register_active_request`.
