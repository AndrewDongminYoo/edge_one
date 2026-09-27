# edge_one

An on-device decision runtime planned for Flutter and React Native, with optional remote escalation.
The production API and architecture are described in [BLUEPRINT.md](BLUEPRINT.md).
The repository currently implements a desktop feasibility experiment; production packages and mobile bindings are not available yet.

## M0 Desktop Spike

The spike uses the selected model's original GGUF runtime and native scorer at pinned revisions.
It compares individual prefill with exact and batched prefix sharing for Choice, Noul, and Score questions.
Python is experimental tooling; the planned production core remains C++17.

Requires Python 3.12, [uv](https://docs.astral.sh/uv/), a C++17 compiler, and a native build toolchain.
On macOS, install the Xcode command-line tools and Metal toolchain before building.
CMake, NumPy, and tokenizers are installed in a local environment from the hashed lockfile.
NumPy and tokenizers are required by the upstream runtime; CMake builds the native scorer without a global installation.

Run from the repository root:

```bash
python3 -m unittest discover -s spikes/m0/tests -v
python3 spikes/m0/check_report.py docs/notes/2026-09-27-m0-desktop.json
uv venv --python 3.12 .cache/m0/.venv
uv pip sync --python .cache/m0/.venv/bin/python --require-hashes spikes/m0/requirements.lock
.cache/m0/.venv/bin/python spikes/m0/setup.py fetch
.cache/m0/.venv/bin/python spikes/m0/setup.py build --jobs 2
.cache/m0/.venv/bin/python spikes/m0/run.py --output .cache/m0/desktop.json --repetitions 5 --threads 4
```

Fetch downloads the Q4_K_M model (529,296,864 bytes), runtime, tokenizer, and native source.
It verifies the pinned manifest and file hashes before use.
Weights, upstream code, builds, logs, and the environment remain under ignored `.cache/m0/`.
Run one native build or inference job at a time.
An existing output report is never overwritten; choose a new filename for another run.

Each fixture runs in a fresh scorer process per mode, followed by repeated warm calls.
Memory is reset before every call, so warm measurements do not reuse a previous request's prefix.
First-request timings are separate from model startup, and OS caches are not controlled.
Exit code 1 indicates a completed probability comparison failed the strict `< 1e-3` gate; inspect the report instead of loosening the threshold.
Other errors may also exit nonzero and leave a `.partial` report.

## Results and Limits

See the [desktop report](docs/notes/2026-09-27-m0-desktop.md) and [raw results](docs/notes/2026-09-27-m0-desktop.json).
The small synthetic fixture set checks numerical parity and prefix-sharing behavior, not classification accuracy or mobile performance.
M0 still requires a separate iOS warm-latency measurement.
Remote calls, model publishing, and device writes are outside this spike.

## Development

Keep specs in `docs/specs/`, plans in `docs/plans/`, and measurements in `docs/notes/`.
The approved [M0 plan](docs/plans/2026-09-27-m0-desktop-spike.md) records the readout correction and acceptance criteria.

```bash
trunk check --no-fix
uv pip compile spikes/m0/requirements.in --python-version 3.12 --generate-hashes -o spikes/m0/requirements.lock
```

The first command checks changed files with the repository's configured linters.
Run the second only when changing experimental dependencies and include both input and lockfile in the same change.
Preserve the upstream model's LICENSE and NOTICE with downloaded artifacts.

GitHub Actions runs the unit tests and validates the archived measurements against current fixture and model pins.
The report checker recomputes probability gates, native sharing observations, and timing summaries from the stored records.
CI does not rerun native inference or verify performance on its runner.
