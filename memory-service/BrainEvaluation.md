# Reproducible brain evaluation baseline

Run from `memory-service`:

```sh
swift test --scratch-path /private/tmp/gemma-brain-swift-build --filter BrainEvaluationTests
swift test --scratch-path /private/tmp/gemma-brain-swift-build --filter 'MemoryRetrieverTests|MemoryRetrieverInjectionTests|MemoryCoreRecallTests'
```

No network model, API key, embedding service, production database, personal transcript, deployment or HomeLab connection is used. Each legacy recall fixture uses its own in-memory database and a fixed clock. Test resources are copied by SwiftPM; loading never depends on the current directory. The repository tracks Package.resolved.

## Corpus and annotations

`Tests/MemoryServiceTests/Fixtures/brain-scenarios.json` contains 200 wholly synthetic cases, with five parameterized variants of each of 40 scenario types. Every type has Spanish and English variants (120 ES, 80 EN). Predicate and value annotations use a language-independent vocabulary. Variant IDs, projects, sessions, fictional codes and quantities describe synthetic objects only. The variants form a regression corpus with shared templates.

`brain-scenarios-manifest.json` identifies the unchanged corpus as `brain-scenarios-v1` and pins its SHA-256. The runner validates the digest and assigns entire templates to tuning (140 cases) or held-out (60 cases), with both partitions represented in every category. The checked-in held-out split is identifiable and reproducible. Its annotations are visible in the repository, so the split is not a blind benchmark.

| Category | Cases | Scenario types |
| --- | ---: | --- |
| factsCorrections | 40 | Simple count/preference recall, corrected numbers, third parties, quotations, hypotheticals, negation, pronouns |
| temporal | 30 | Rescheduling, cancellation, verified completion, promises, relative dates, historical intervals |
| forgettingProvenance | 30 | Withdrawn evidence, stale summaries/clients, why/source attribution, exact quotations, selective forgetting |
| conversationAffect | 40 | Tentative affect, abstention, expiry, no diagnosis, requested format, referent units, agent/user/relationship separation |
| procedure | 30 | Verified success, failed attempts, authorization, step ordering, superseding outcomes, untested proposals |
| failurePortability | 30 | Offline writes, absent embeddings, model changes, rollback, idempotent retry, reply failure after learning |

Each case supplies source messages with IDs, roles and active/withdrawn state; a query; exact expected evidence IDs; structured expected assertions; and forbidden assertions. Assertions independently identify subject, predicate, canonical value, optional numeric value, claim state, source role and cited source IDs. A choice and the definition of its referent can require separate assertions from different roles. Tool/system messages in failure/procedure fixtures represent synthetic observations, not proof that the current service implements those behaviors.

## Scoring contract

Decode the cases and adapter predictions using JSONDecoder or construct the public DTOs, then call:

```swift
let report = try BrainEvaluation.score(cases: cases, predictions: predictions)
```

A supported prediction is correct only when its entire evidence set and entire structured assertion set equal the expected sets, with all citations active and attributed to the proper source role. Order is irrelevant; values, subjects, numbers and states are exact. Extra assertions fail. Forbidden claim identity ignores citations and source role, so changing a citation cannot make a forbidden claim acceptable. Unknown or withdrawn predicted citations make that case incorrect. There is no prose similarity, token overlap, embedding threshold or LLM judge.

The scorer validates the entire run before returning a report. Duplicate case/prediction IDs, unknown prediction case IDs, malformed DTO content, contradictory/vacuous expected facts, invalid expected source references/roles, and unsupported predictions that contain output or omit a substantive reason throw BrainEvaluationValidationError. A hallucinated prediction citation is instead a scored failure, so it remains visible as system behavior. An empty supported output is an evaluated failure; absent prediction IDs are missing. A valid empty run has no accuracy, not perfect accuracy.

Counts are reported globally and per category, with one ordered result and failure/unsupported reason list for each case:

- `total = evaluated + unsupported + missing`.
- `evaluated` counts provided supported outputs, both correct and incorrect.
- `unsupported` requires an explicit nonblank reason and contributes zero correct cases.
- `missing` counts absent predictions and contributes zero correct cases.
- `exactAssertionAccuracy = correct / (evaluated + missing)`. Nil only when that denominator is zero.
- `coverage = evaluated / total`; `overallExactAssertionAccuracy = correct / total`. Nil only for an empty corpus.

Never publish conditional accuracy without coverage and the missing/unsupported counts. Codable report counts/results preserve the underlying evidence; metric properties are computed from counts. Correctness measures agreement with these annotations, not a general guarantee of semantic truth or conversational quality. A model adapter must independently derive output from messages/query and must never copy expected annotations into predictions. Passing evaluator tests establishes software behavior; it does not establish model accuracy.

## Legacy retrieval baseline

`testLegacyRetrievalBaselineReportsOnlySupportedRecall` actually invokes MemoryStore and MemoryRetriever with embeddings disabled. Ten single-message count/preference fixtures are pre-extracted into explicit fact nodes using source text (not the query) for their labels/body. The adapter returns only sourceRef evidence IDs. It cannot produce structured facts or perform extraction, correction, temporal reasoning, forgetting, emotion inference, procedural learning, failure recovery or model portability. It therefore declares all other 190 cases unsupported; it does not infer capability from keyword hits.

Expected baseline, which the test verifies and prints from observed report counts:

| Category | Evaluated | Unsupported | Missing | Exact assertion correct |
| --- | ---: | ---: | ---: | ---: |
| factsCorrections | 10 | 30 | 0 | 0 |
| temporal | 0 | 30 | 0 | 0 |
| forgettingProvenance | 0 | 30 | 0 | 0 |
| conversationAffect | 0 | 40 | 0 | 0 |
| procedure | 0 | 30 | 0 | 0 |
| failurePortability | 0 | 30 | 0 | 0 |
| Total | 10 | 190 | 0 | 0 |

The separate evidence-selection sanity check is 10/10 on that deliberately narrow pre-extracted subset. Coverage is 5%; exact assertion accuracy and overall exact assertion accuracy are both 0%. These zeros reflect absent structured assertions, not an estimate of the underlying language model's semantic ability. No model has been evaluated in this baseline. The other behavior families remain unimplemented/unmeasured here, not correct.

The pre-existing repository software baseline is commit ea42d5f, whose full-suite result was recorded before this task in `/private/tmp/gemma-brain-baseline-tests.log`. Task-specific RED/GREEN commands and observed outputs belong to `.superpowers/sdd/2026-11-05-cerebro-gemma-implementation/task-1-implementer-report.md`; a passing build/test suite must always be reported separately from measured retrieval or semantic/model accuracy.

## Offline longitudinal runner

Run from `memory-service` with SwiftPM dependencies already available:

```sh
BRAIN_EVALUATION_OUTPUT=/private/tmp/brain-longitudinal-report.json \
BRAIN_EVALUATION_BACKEND_REVISION="$(git describe --always --dirty)" \
BRAIN_EVALUATION_SWIFT_VERSION="$(swift --version | head -n 1)" \
swift test --scratch-path /private/tmp/gemma-brain-swift-build --jobs 1 \
  --filter 'BrainEvaluationTests|BrainLongitudinalEvaluationTests|BrainLongitudinalScenarioTests'
```

The corpus runner uses Hummingbird's in-process router with test bearer authorization, isolated on-disk SQLite databases and deterministic `FakeEmbedder` vectors. Its input contains fixture messages and a query. The scorer accesses annotations after the adapter returns. The report includes corpus digest, execution configuration, software versions, per-case partition and outcomes, per-category metrics and reasons for unmeasured checks. Each supplemental scenario emits a `TASK17_LONGITUDINAL` JSON line with check results and any measured timing.

The runner admits user history through `/v1/brain/turns/begin` and appends historical assistant text through `/v1/transcript/append`. It reopens the same database and checks persisted history and the first admitted operation's replay where a user turn exists. Sources marked withdrawn are inserted before the runner calls `/v1/brain/forget`. It measures subsequent delivery via the `/v1/brain/context` response. The 50 cases containing synthetic tool or system statements require separately scripted operational tests. Those statements trigger no actions and are reported as unsupported.

Source precision and recall are micro-averaged against annotated evidence IDs over cases with route observations. The context route can send useful conversation history beyond the evidence needed for the annotated answer. Additional history counts against this narrow precision metric. Unmapped source IDs count against precision. Withdrawn exposure checks delivery markers, source references, parent and evidence IDs, truncation notices and text in context, as well as source IDs, labels and bodies in retrieval. Retrieval compares direct FTS, hybrid `MemoryRetriever`, and vector-only nearest neighbor over the same raw fixture texts indexed as synthetic nodes, with the same erasures. It uses top K=4 and reports per-lane source metrics separately from semantic assertions. Latency samples time the in-process route or retrieval call, with nearest-rank median and p95 in milliseconds.

Exact assertion scoring is limited to five explicit original-quote queries. The adapter requests the sole available user original by observed speaker, then reads the actual rendered quote, source attribution and delivery marker from the route response. This exercises assisted verbatim transport. Other cases have no supported semantic answer adapter. Real model adherence, semantic embedding quality, human naturalness and preference review, and device/provider latency remain unmeasured.

### Observed offline results

The scorer accepted all 200 cases. The runner observed five exact quote deliveries, 195 unsupported assertions and zero missing predictions. Assertion coverage and overall exact accuracy were both 2.5%. The five quote cases were held out, with 5/60 overall exact accuracy and 55 unsupported. All 140 tuning assertions were unsupported. Each of the 150 replayable histories persisted across database reopen, including stable operation receipts where a user turn existed. All 25 requested source erasures were confirmed and none of those sources reached the resulting context or retrieval samples.

| Lane | Observed cases | Matching / delivered / expected sources | Precision | Recall | Median / p95 milliseconds |
| --- | ---: | --- | ---: | ---: | ---: |
| Context route | 150 | 165 / 175 / 165 | 94.3% | 100% | 1.73 / 1.96 |
| Direct FTS | 150 | 103 / 105 / 165 | 98.1% | 62.4% | 0.56 / 0.71 |
| Hybrid | 150 | 165 / 175 / 165 | 94.3% | 100% | 1.03 / 1.37 |
| Vector-only | 150 | 165 / 175 / 165 | 94.3% | 100% | 0.19 / 0.32 |

Each replayable fixture contains at most two historical messages, below the retrieval limit of four. Hybrid and vector-only returned all surviving sources in this setup. Their recall measures source availability on the fixture and does not establish semantic ranking quality. The measured latencies describe one local in-process run using SQLite 3.54.0.

The five supplemental scenarios passed 33 checks over project resumption, startup orientation and cue delivery, taste and comparative preference, compaction and restored exclusions, procedure validity, and transport of the independent-judgment policy. The project fixture measured 2.90 ms from cue to candidate and 9.78 ms from admission to the first request received by the recording provider. That request contained the selected context. These timings exclude model inference. The independent-judgment fixture covers false premises, contradiction, correct statements, subjective tastes and uncertainty, and leaves actual model behavior to a separate evaluation.
