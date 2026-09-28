# M0 server comparison

This comparison accepts **redacted exports**, not live credentials or private request text. Both sides must contain the same stable question ID, option order, and hashes of the exact rendered request and token IDs. The tool rejects a request or token hash mismatch rather than presenting unlike requests as runtime drift.

## Export format

`schema_version` is `1`, and `source` is `local` or `server`. `model.id`, `model.revision`, `scorer_revision`, `template_sha256`, and `readout_config_sha256` identify the model and scoring path. The readout digest covers the exact configuration artifact, including effective temperatures that are applied after scoring. Each `requests` item contains:

- `id`: a non-sensitive stable question identifier;
- `request_sha256`: SHA-256 of the exact UTF-8 request bytes sent to the scorer;
- `token_ids_sha256`: SHA-256 of the compact JSON token-ID array (UTF-8, no spaces);
- `option_names`: authoritative scorer option order; probability-object key order is ignored;
- `answer` and `probabilities`: the returned decision and normalized distribution.

For example, hash token IDs in Python with `hashlib.sha256(json.dumps(ids, separators=(",", ":")).encode()).hexdigest()`. Hash the immutable template and readout artifacts themselves for `template_sha256` and `readout_config_sha256`. Digests may be supplied in either hexadecimal case; reports canonicalize them to lowercase. Exports should be prepared inside the approved environment; never commit request text, credentials, headers, or raw token IDs derived from private inputs.

## Run

```bash
python3 spikes/m0/compare_server.py \
  spikes/m0/server_fixtures/local.example.json \
  spikes/m0/server_fixtures/server.example.json \
  --output /tmp/server-comparison.json
```

The report includes signed server-minus-local differences for every option, the maximum absolute difference and top-choice agreement for every question, and the existing strict `< 1e-3` gate. It exits `1` when a completed comparison fails that probability gate. It refuses to overwrite an existing report.

When all model, scorer, template, and readout metadata match, differences are labeled `runtime_difference`. If any version or configuration metadata differs, they are labeled `server_model_or_configuration_difference` and the differing fields are listed. This attribution is deliberately conservative: it identifies configuration drift as a confounder rather than claiming that the runtime caused the observed difference.

The checked-in example pair is synthetic and exercises the reproducible format; it is not evidence from an approved server. A real comparison still requires approved server access or supplied redacted exports.
