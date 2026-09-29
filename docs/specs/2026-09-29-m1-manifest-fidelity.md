# M1 Pinned Model Manifest Fidelity

## Problem

The pinned model needs its released readout temperature and upstream legal notices alongside the model identity.
Without those inputs, an app cannot reproduce the verified global readout or include the required model notices.

## Scope

Bundle a manifest for the fixed M0 model revision with its effective global temperature and SHA-256 digests for the upstream LICENSE and NOTICE.
Bundle those two upstream files as Flutter assets, verify their bytes against the manifest, and expose their text for host app notices.
Keep the manifest digest compiled into the app and require the fixed revision in its model URL.

## Acceptance

- The pinned global temperature matches the released readout configuration and archived M0 evidence.
- Missing, invalid, or altered temperature and legal asset digests are rejected.
- A host can load the verified LICENSE and NOTICE text from the package assets.
- Linux tests and Flutter analysis pass without a model download.

## Non-goals

The model download state machine, platform storage policy, background transfer, and app-specific notice presentation remain outside this change.
