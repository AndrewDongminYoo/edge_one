# M1 Pinned Model Manifest Plan

## Implementation

1. Copy the existing pinned manifest parser and asset loader from the model-store branch, then add the released global temperature and upstream LICENSE/NOTICE digests.
2. Bundle the exact legal files from the pinned upstream revision, normalize their checkout bytes, and verify them when loading through an asset bundle.
3. Add focused manifest and asset tests that fail on altered temperature, digest, and legal content.
4. Verify package asset lookup from a small consuming Flutter fixture, document the host app notice handoff, and run Dart tests, Flutter analysis, formatting, and Trunk before opening the prerequisite PR.

## Completion

The prerequisite PR contains only manifest, legal asset, and gate changes; the model-store branch retains download behavior and adds its own progress-callback fix.
