# Reproducible brain evaluation baseline

Run from `memory-service`:

```sh
swift test --scratch-path /private/tmp/gemma-brain-swift-build --filter BrainEvaluationTests
swift test --scratch-path /private/tmp/gemma-brain-swift-build --filter 'MemoryRetrieverTests|MemoryRetrieverInjectionTests|MemoryCoreRecallTests'
```

No network model, API key, embedding service, production database, personal transcript, deployment or HomeLab connection is used. Each legacy recall fixture uses its own in-memory database and a fixed clock. Test resources are copied by SwiftPM; loading never depends on the current directory. The repository tracks Package.resolved.

## Corpus and annotations

`Tests/MemoryCoreTests/Fixtures/brain-scenarios.json` contains 200 wholly synthetic cases, with five parameterized variants of each of 40 scenario types. Every type has Spanish and English variants (120 ES, 80 EN); machine predicate/value annotations use a language-independent vocabulary. Variant IDs, projects, sessions, fictional codes and quantities describe synthetic objects only. This is a regression corpus, not 200 independent empirical observations.

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
