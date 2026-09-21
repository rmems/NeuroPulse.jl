# Synthetic Spikenaut frozen-replay fixture

These exact bytes were produced from `rmems/Spikenaut-SNN` commit
`72e624eb54fa9f688d8d2e9d0fe86ebf467d6ba3` using:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tools/replay_frozen.py --out-dir <temporary-directory>
```

Producer: [tools/replay_frozen.py](https://github.com/rmems/Spikenaut-SNN/blob/72e624eb54fa9f688d8d2e9d0fe86ebf467d6ba3/tools/replay_frozen.py).
Original synthetic input: [tools/fixtures/replay_frozen/telemetry.jsonl](https://github.com/rmems/Spikenaut-SNN/blob/72e624eb54fa9f688d8d2e9d0fe86ebf467d6ba3/tools/fixtures/replay_frozen/telemetry.jsonl).
The source telemetry, trace, and manifest are copied without modification.
This is synthetic method data, **not measured hardware and not holdout evidence**.

The controller generated the pair twice from the pinned producer and confirmed
byte identity. The producer's default shipped model bank uses k=4; the resulting
fixture has 10 steps, 2 sessions, 16 neurons and 32 spikes. Source manifest
`source.commit` is the pinned revision; `source.dirty` is JSON null and remains
null here (it is not rewritten as a claim of a clean producer checkout).

SHA-256 digests:

- telemetry.jsonl: `80954bab12f8f972c3234263633f778476e75c32e1929fcdaacd3f5cf4cb3492`
- trace.jsonl: `9f7b7144165350514a3351e607178e33b44542437cf4171a8b2bbc678a028bb4`

Spikenaut-SNN and these original fixtures are by Raul Montoya Cardenas and
contributors, under the MIT OR Apache-2.0 terms declared by the pinned
[README](https://github.com/rmems/Spikenaut-SNN/blob/72e624eb54fa9f688d8d2e9d0fe86ebf467d6ba3/README.md#license)
and Cargo.toml. The repository owner authorized inclusion of this synthetic fixture.
No producer implementation is copied into this adapter. Upstream feature map,
checkpoint, input digest, encoding/missing policy, source revision and decision
contract remain recorded verbatim in manifest.json.
