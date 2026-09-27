# M0 Desktop Feasibility Spike

## Status and Scope

Approved by the operator on 2026-09-27: validate the blueprint's desktop inference assumptions before implementing mobile bindings.
Use the existing workspace and complete one native build at a time.
This stage ends with a reproducible desktop report; iOS latency remains a separate M0 requirement.
Do not interpret desktop timings as mobile results.
Commits, pushes, publication, and device writes require separate authority.

## Discovery Evidence

The repository contains the blueprint and Trunk configuration, with no implementation packages yet.
CMake was not found on PATH during discovery; check for an existing installation before installing it.

The proposed A/B/C final-position readout does not match the selected model.
The shipped runtime scores each option at its verdict slot using the difference between the yes and no logits, then applies the release's temperature and softmax.
It still uses standard llama.cpp logits; a custom hidden-state head is unnecessary for this spike.
See the pinned [runtime, lines 16–35 and 569–598](https://huggingface.co/chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF/blob/edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c/jev_style_decision_gguf.py) and [readout configuration](https://huggingface.co/chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF/blob/edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c/readout_config.json).

Upstream exact mode shares complete microbatch blocks, using a default size of 1,024 tokens.
Below that boundary it shares no state tokens.
Batched mode shares the full prefix but upstream reports probability differences up to 0.002; our blueprint's strict gate remains below 0.001.
These are upstream observations, not measurements from this repository.
See the pinned [model documentation](https://huggingface.co/chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF/blob/edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c/README.md).

The [release configuration](https://huggingface.co/chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF/blob/edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c/release_config.json) identifies llama.cpp commit `441df11f65ea0b6d0c72965aaf70c8241070ddcb` as its tested native baseline.
Use model revision `edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c` and Q4_K_M for this experiment.

Personal-account Oracle retrieval for project `edge_one`, topics `llama.cpp` and `prefix sharing`, returned \[no precedent found\].
There is no applicable retrieved precedent to change this direction.

## Intended Files

- `BLUEPRINT.md`: correct the selected model's readout and mark prefix sharing as conditional.
- `README.md`: document project status and spike commands.
- `.gitignore`: exclude local models, downloaded upstream code, environments, and build output.
- `spikes/m0/`: pin metadata, setup instructions, inference comparison harness, synthetic request fixtures, and harness tests.
- `docs/notes/`: record measured results, limitations, and the next milestone decision.

Keep upstream runtime code in an ignored local directory and reference its revision instead of vendoring or rewriting the scorer.
Use Python for the experimental harness because the reference runtime is Python; this does not add Python to the planned production runtime.
Select and lock only the dependencies needed by the reference runtime after inspecting its imports.
Defer Melos, pnpm, code generation, and package scaffolding until feasibility is established.

## Execution and Acceptance

1. Establish pinned inputs and checksums → verify downloaded model and runtime files against the pinned manifest before loading or importing them.
2. Test the harness first → run `python3 -m unittest discover -s spikes/m0/tests`; require failures for missing results, nonfinite probabilities, changed option ordering, and an empty fixture set.
3. Build the reference scorer → use the pinned upstream build instructions, limit parallelism, and verify its ready response against the expected model and build settings.
4. Compare individual inference, exact sharing, and batched sharing → record every question's distribution, maximum absolute difference, top-choice agreement, shared token count, and timings.
5. Exercise short prefixes and prefixes on both sides of the actual microbatch boundary, with multiple questions and structured state → assert that the long fixtures really activate sharing.
6. Repeat cold and warm runs separately → record model SHA-256, revisions, hardware, context size, microbatch size, thread count, and sample count with raw results.
7. Apply the gate → require every evaluated probability difference to be strictly below `1e-3`; report failing modes rather than relaxing the gate or substituting top-choice agreement.
8. Review the scoped diff and run Trunk → publish no performance claim without the corresponding measured report.

Exact mode without shared tokens may pass parity but does not demonstrate a sharing speedup.
If batched mode fails, retain individual inference as the baseline and document whether exact mode helps only longer states.
Do not claim M0 complete until the later iOS measurement also exists.

## Desktop Stage Result

Implemented and measured on 2026-09-27; see the [measurement note](../notes/2026-09-27-m0-desktop.md) and [raw report](../notes/2026-09-27-m0-desktop.json).
The report retains native responses as evidence of the sharing path and embeds the canonical fixture specification.
The unit suite tests native fallback, missing observations, corrupt inputs, incomplete results, and the strict probability gate.
iOS measurement remains outstanding; no device writes, commits, or external publication occurred in this stage.
