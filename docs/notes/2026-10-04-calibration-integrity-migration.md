# Calibration fixture integrity migration

The additional hosted-review correction was approved after the investigation at
`d082cdfbfb3e5ab475b4b07d1078e7cf6476a832`. All 120 visible legacy synthetic
requests had placeholder hashes derived from an index string rather than the
RecordingBackend typed request encoding. Enforcing raw integrity therefore
requires replacing those invalid hashes and reviewing the resulting baseline.

Exactly the 120 `request_sha256` fields changed in `labeled.jsonl`. Requests,
responses, labels, physical model identity and the six-field recording format
are unchanged. Seed 0, fitting algorithms, target error 0.05, the 1/5/10 percent
report targets and all regression tolerances remain unchanged. This approved
migration supersedes the earlier byte-identical legacy fixture constraint.

## File hashes

Files are under `packages/edge-one-calibrate/test/fixtures/`.

`labeled.jsonl`:

- Before: `af629f5359e78b92554ffef7d41b255e1d2973cecc614fb44c8e1f4b3c0806f9`
- After: `8a7122e7947d0f414a557c3d0b48d0809b694b25d6c00b0abff37e933c9abe77`

`baseline-report.json`:

- Before: `407bd4aed0e3936336e5c78c2f52e02440674b0bd65ea9fed9d8ea2a1dda9cc7`
- After: `80220932cdc8ffe6f4b3420ccc1c46015b5871e7c2ee319b199b1d28352129bd`

`thresholds.json`:

- Before: `5a28bc613a9114d9557bb69279bde15fc69c252bd65b323fc27a90b9f4f44f73`
- After: `b2b9883ca8ac9e7ce707c9d322a86cf0aeae2b2774e17e5c9454d4a1d5193f22`

## Split and metric changes

The v1 dataset digest changes from
`7e143419e217bbb34a217acabcb0fbfaa918ae010acbaa93767b869e42644263` to
`6677351533a6d6a6878d1f91d5a5f3ef6b19f40a8a93408965aa63f707040ea3`.
Both partitions still contain 60 requests; 31 of the former 60 fitting requests
remain in fitting when matched by original request content. Corrected raw hashes
change the seeded ranking, so the historical and migrated reports are
intentionally incompatible. Historical report parsing retains v1 semantics.

Each question has the following validation changes at all three target errors:

| Metric          | Before                     | After                      |
| --------------- | -------------------------- | -------------------------- |
| Accuracy        | 50/60 (0.8333333333333334) | 47/60 (0.7833333333333333) |
| Accepted        | 43/60                      | 42/60                      |
| Coverage        | 0.7166666666666667         | 0.7                        |
| Accepted errors | 0                          | 0                          |

The model-bound v1 artifact retains its schema and physical model hash, with
new fitted values due to the changed fitting membership:

| Question | Before temperature | After temperature  | Before threshold  | After threshold    |
| -------- | ------------------ | ------------------ | ----------------- | ------------------ |
| flag     | 0.5517981149045462 | 0.485838174690041  | 0.917307078898747 | 0.9452477839521018 |
| level    | 0.5517981149045462 | 0.4858381746900412 | 0.917307078898747 | 0.9452477839521016 |
| topic    | 0.5517981149045462 | 0.4858381746900412 | 0.917307078898747 | 0.9452477839521016 |

These synthetic metrics verify software behavior and do not measure model quality.

## Compatibility and verification

Correct-hash unredacted v1 records keep the same identity and split rules.
Incorrect hashes now fail before fitting. Custom redaction must be declared;
visible fixtures must not be relabeled as redacted to bypass integrity checks.

The three comparison-v2 fixtures remain byte-identical: their hashes already
covered the typed original requests. The producer additionally validates stable
ordered original question definitions before emitting a sidecar. Explicit trust
in hidden originals attests that third-party producers also performed this
validation; digest pairs alone cannot prove hidden definitions. No sidecar
format or digest scheme changes.

Regenerate synthetic inputs with `dart run tool/update_fixture.dart` from the
calibration package, then fit and check with the documented CLI commands.
Baseline regeneration remains a separately reviewed action, never an automatic
part of CI or tests. Test request mutators now refresh genuine raw hashes when
exercising later question or partition invariants. The aggregate-subset test
derives its impossible error count from the report instead of assuming the old
validation partition had exactly ten errors.
