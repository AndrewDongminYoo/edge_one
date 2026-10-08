# Question-level hybrid routing

Issue #16 adds pure Dart `HybridRouter` and `RemoteBackend` implementations of
`SystemOneBackend`. Transport is injected; the package opens no sockets, reads no
credentials, and performs no inference. Tests use synthetic data and fake
transport only.

## Routing

Validate and snapshot the input. Application-configured forced-remote keys bypass
local inference; unknown forced keys are rejected before any backend call. Run
local inference for the remaining keys, validate its entire answer set, and apply
a model-hash-bound per-question calibration gate. Escalate forced keys and local
answers rejected by the gate in one remote request, preserving input key order.
Merge only complete, validated answer sets by key. An error affecting a forced
key rejects the evaluation; ordinary uncertain answers fall back to their complete
local response with per-key failure metadata. Local backend errors propagate.

The router does not guess native token or option limits. Applications can derive
forced keys using their own preflight adapter; native preflight integration
requires the separate engine capability work.

`x_route` is `local`, `remote`, or `auto` for a mixed answer. `x_routing` describes
origin, calibration gate, and any fallback reason per key. Usage sums local and
primary remote evaluations, excluding shadow calls. Combined usage must remain
within the wire limit of 2^53 - 1 per counter; an unrepresentable aggregate is a
typed remote response failure subject to the same local-fallback/forced rules. Mixed responses use the
requested model identifier; routing metadata records backend model identifiers.

## Calibration and caller decisions

`CalibrationProfile` from issue #17 supplies relative temperature and inclusive
threshold. Compare the supplied verified local model SHA-256 before lookup, and
check question type. Missing profiles, mismatched hashes, unknown keys, or changed
types reject every local answer for routing and attach a warning. A null threshold
also rejects every confidence, including 1. Apply temperature to probabilities,
then compute normalized maximum confidence for routing. Noul uses `[1-p,p]`.

Returned answer values and raw probabilities remain unchanged. **Routing
calibration does not change `DecisionClient.minConfidence` or its `Decided` /
`Uncertain` semantics.** Callers inspect routing metadata when they need gate or
fallback status. Calibration keys must retain the question definitions used for
fitting; the artifact cannot detect meaning changes under the same key.

## Remote policy and masking

`RemoteBackend` owns policy so direct use, escalation, and shadow calls all share
one guard. Local-only defaults to true. Explicit consent, network availability,
a caller-supplied masking hook, and a shared cost budget are required to dispatch.
Callbacks are injected; no permission prompt or platform state is inferred.

The masking hook receives the complete outbound `SystemOneRequest`, including
state, instructions, and criteria. Validate and snapshot its result. It may mask
content but must preserve model, question keys/types, Choice option names, and
Score level count so answers still pair with the original request. Masked data
never changes the local request. Missing or invalid masking refuses dispatch.

Masking may be asynchronous. After it completes, recheck synchronous policy gates,
estimate cost from the immutable masked request, and read the budget clock. Check
policy once more after those callbacks, then charge and invoke transport without
an intervening callback or await. The final network query precedes the final
consent query. Policy queries must read application state without side effects;
arbitrarily mutually mutating queries cannot be sampled atomically. Request/response validation occurs even
when used without `DecisionClient`. Error strings include no request or remote
response content. Status codes 401, 422, 429, and 529 map to named typed errors;
other non-success statuses, transport failures, and malformed responses are typed.
No retries are implicit.

## Cost accounting

Use nonnegative integer application-defined microcredits. A caller provides a
conservative cost bound for each outbound masked request. One shared budget
instance maintains a UTC calendar-day limit using an injected clock. Reservation
is synchronous in the Dart isolate and occurs before dispatch. Every dispatched
attempt is charged, including status errors or transport failures; rejected or
invalid masked requests are not charged. A later UTC date resets accounting;
a backward clock does not replenish budget. This is per-instance in-memory
accounting, not a persistent or cross-isolate billing system.

## Shadow comparisons

Shadowing is opt-in with an injected deterministic sampler and observer. After the
primary result is determined, sample only questions whose returned answer is
local. Send that subset through the same remote masking, policy, and budget path.
Await the comparison for deterministic lifecycle and observe its local/remote
answers or typed error. Sampler, remote, and observer failures cannot replace or
invalidate the primary response. Shadow calls never alter returned answers,
usage, route, or metadata. Applications should keep observers fast and handle
persistence separately.

## Verification

Linux tests cover mixed routes and key ordering, forced-only bypass and errors,
full-request masking, malformed masked shapes and responses, policy defaults and
revocation during masking, concurrent final-credit exhaustion, day rollover,
status mapping, calibrated per-type gates, conservative mismatches, and
deterministic shadow calls with unchanged primary responses. All transports stay
inside the test process.
