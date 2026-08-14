# Code Review: Cross-Engine Transfer Feature

**Branch:** `feat/transfer-cross-engine-ir`
**Scope:** 4 commits, ~7,600 insertions across 69 files
**Verdict:** Do not merge. Two critical bugs, both silent or fatal at runtime.

Reviewed areas: PluginKit ABI, the chunked reader/writer pipeline, bulk load fallback,
checkpoint/resume, connection pool leases, value conversion, and the type mapper.

This document merges two independent passes over the same branch. Every finding below was
re-checked against the source before being written here. Two findings from the original passes
did not survive that check and are recorded at the bottom under "Withdrawn" rather than deleted.

---

## Critical 1: Deadlock, writer never releases backpressure permits

`TransferBackpressureGate` (`TablePro/Core/Services/Transfer/TransferPipeline.swift`) is a
counting gate with capacity `pipelineDepth = 4`. It has both `release()` and `releaseAll()`.

- Reader (`DataTransferService+Copy.swift:161` and `:261`): `guard await gate.acquire()`
  before every chunk.
- Writer (`DataTransferService+Writer.swift:29`): the only gate call is
  `defer { Task { await gate.releaseAll() } }`, which runs when the whole table finishes.

`release()` is never called anywhere in the app. Its only callers are
`TableProTests/Services/TransferBackpressureGateTests`, so the unit tests pass while the
production path is broken. Trace for a table with 5 chunks:

1. Reader acquires 4 permits (chunks 0-3), yields them, then blocks in `acquire()` for chunk 4.
2. Writer consumes chunks 0-3, then blocks in `for try await event in stream` waiting for chunk 4.
3. Reader is blocked waiting for a permit the writer never releases; writer is blocked waiting
   for a chunk the reader cannot yield. Deadlock.

Any table with more than `pipelineDepth x chunkSize = 4 x 10,000 = 40,000` rows hangs forever.
`acquire()` uses `withCheckedContinuation` with no cancellation handler, and the query timeout
was deliberately set to 0 for the run, so nothing breaks the hang.

**Fix:** call `await gate.release()` after each chunk is consumed in `writeChunks`, and keep
the `defer { releaseAll() }` for teardown. The `release()` method is currently dead code.

**Test gap.** Confirmed with the author: the missing `release()` was an oversight, not a known
deferral. `TransferBackpressureGateTests` exercises the gate in isolation and calls `release()`
itself, so it proves the gate works and proves nothing about the wiring. Nothing in the suite
drives a reader and a writer through `writeChunks` together, so the deadlock is invisible to
CI, and it needs a table over 40,000 rows to appear by hand. The fix should land with an
integration test that runs the real pipeline past `pipelineDepth x chunkSize` rows, otherwise
the same class of bug returns unnoticed. The same test would have caught Critical 2.

---

## Critical 2: Silent data loss, engines without a bulk writer write zero rows

`DataTransferService+Writer.swift:108` calls the resolver with `bulkWriterAvailable: true`
hardcoded, so the resolver never returns `.preparedBatch` for the "no bulk writer" case. Then
in `writeChunkRows` (`:268`):

```swift
if state.useBulk {
    if state.bulkWriter == nil {
        state.bulkWriter = try await target.bulkLoadWriter(...)   // nil for most drivers
    }
    guard let writer = state.bulkWriter else { return 0 }         // silently drops the chunk
```

The chunk commits 0 rows, the checkpoint advances, and the table is marked complete.

Bulk writer implementations:

- **PostgreSQL:** real `bulkLoadWriter` (`PostgreSQLPluginDriver+BulkLoad.swift:10`), works.
- **MySQL:** `bulkLoadWriter` returns `nil` (`MySQLPluginDriver.swift:942`). With
  `local_infile=1` the resolver returns `.bulk`, so all rows are silently dropped. With
  `local_infile=0` it happens to fall back to prepared batches and works.
- **SQLite, MSSQL, ClickHouse, Redis, every registry plugin:** no override, so they inherit the
  PluginKit default returning `nil` (`PluginDatabaseDriver.swift:668`). The resolver returns
  `.bulk` (non-MySQL, so `localInfileRequired` is false, and `continueOnError` defaults to
  false), so all rows are silently dropped.

The run reports success with 0 rows transferred; only `verifyCounts` shows a source/target
mismatch in the report. The docs state "falls back to prepared batches otherwise", and that
fallback does not exist.

**Fix:** probe bulk availability for real (create the writer in `setupWriter` and store it, or
add a capability), and if `bulkLoadWriter` returns nil, fall back to the prepared sink instead
of returning 0.

---

## High 3: Lane drivers escape the pool lease and the serialization queue

`DataTransferService.swift:224`. The `TransferDriverProvider` closure returns
`(laneSource, laneTarget)` *out of* the nested `pool.withDriver` bodies:

```swift
return try await pool.withDriver(scope: target.scope, workload: .bulk, lane: lane) { laneTargetDriver in
    try await pool.withDriver(scope: source.scope, workload: .bulk, lane: lane) { laneSourceDriver in
        ...
        return try await Self.withTimeoutRestore(source: laneSource, target: laneTarget, timeout: configuredTimeout) {
            (laneSource, laneTarget)     // escapes both leases
        }
    }
}
```

`MetadataConnectionPool.withDriver` (`:85`) drops the lease in its `defer { releaseEntry(entry) }`
and runs the body under `entry.runSerially`. Both end the moment the tuple is returned, so every
lane copy afterwards runs on a driver with no lease and no serialization: the pool can close or
evict the connection mid-copy, and two tasks handed the same lane interleave statements on one
connection.

The same line defeats `withTimeoutRestore`. Its body only returns the pair, so the configured
query timeout is restored immediately, before any copying, re-arming the timeout the run just
lifted with `applyQueryTimeout(0)`.

---

## High 4: Lane numbering collides between parallel tables and partitions

Two schemes share one namespace:

- Parallel tables (`DataTransferService+Phases.swift:170`): `lane % lanes`, so `0 ..< lanes`.
- Partitions of one table (`:340`): `index + 1`, so `1...N`, with the comment "Partition lanes
  start at 1: lane 0 is the run's own pair."

With `parallelTables > 1` and in-table parallelism on, a table copy on lane 1 and a partition on
lane 1 request the same pool key and get the same `DatabaseDriver`. Each then runs its own
`beginTransaction`/`commit` on that shared connection.

Separately, `lane % lanes` repeats: with 3 lanes and 7 tables, three tables land on lane 0, and
lane 0 returns the run's own `sourceContext`/`targetContext` directly (`DataTransferService.swift:225`,
`guard lane > 0`), so several table copies share one pair concurrently.

---

## High 5: `rowsTransferred` reported at 2x on the PostgreSQL default path

`DataTransferService+Writer.swift:239`. In the bulk plus `useSingleTransaction` path, which is
the default for a PostgreSQL target:

- `writeBufferedChunk` -> `writeChunkRows` returns a per-chunk count, accumulated into `written`.
- `finishBufferedTable` then returns `writer.finish()`, and `PostgresBulkLoadWriter.finish()`
  (`:47`) returns `rowCount`, its own running total of every row it took.
- `writeChunks` adds the two.

A 1M row table reports 2M rows transferred. The per-chunk commit path is correct: it assigns
(`written = try await writer.finish()`) instead of adding.

---

## High 6: Text primary keys with numeric-looking values skip or duplicate rows

`TransferChunkPlanner.literal` (`:117`) and `keyText` decide quoting by the value's shape, not
the column's type:

```swift
guard PluginNumericLiteral.isValid(value) else { return escapeStringLiteral(value) }
return value   // "123" from a VARCHAR column is emitted unquoted -> numeric compare
```

`ORDER BY varchar_col` is lexicographic, but the emitted predicate compares against a bare
numeric literal. The result differs per engine and is wrong in all three:

- **MySQL:** coerces the column to a number. Values {"2","10"} with chunkSize 1: chunk 1 reads
  "10", chunk 2 predicate `col > 10` matches neither, so "2" is silently skipped.
- **PostgreSQL:** no implicit cast, so `varchar_col > 123` is a type error and the chunk query
  fails outright.
- **SQLite:** integers sort before text in its type ordering, so `col > 10` matches every text
  row and chunks re-read rows already copied.

Any varchar key holding numeric-looking data (zip codes, phone numbers, string IDs) is affected.

**Fix:** carry the column type into the planner and quote text keys regardless of content.

---

## High 7: Snapshot `ROLLBACK` is fired from an unawaited detached Task

`DataTransferService+Phases.swift:146`, `:183`, and `:345` all release the snapshot transaction
the same way:

```swift
defer {
    Task { @MainActor in try? await source.execute("ROLLBACK") }
}
```

Nothing awaits the Task. Two failure modes follow. The `ROLLBACK` can land after the driver has
gone back to `MetadataConnectionPool` and been handed to another consumer, rolling back an
unrelated transaction. Or, going the other way, the `REPEATABLE READ` transaction is still open
while `verifyCounts` and later pool users run on that connection.

---

## High 8: The cross-vendor IR and type mapper are unreachable

`DataTransferService.validate:161` throws `differentDatabaseTypes` unless
`source.databaseType == target.databaseType`, and `DataTransferWizardModel.endpointProblem:212`
blocks the same pairing in the UI. So `TransferStructureBuilder` is always called with
`mapper.isSameDialect ? nil : mapper` (`+Preflight.swift:84`), which resolves to nil in
production. `TransferTypeMapper`, `NativeTypeParser*`, and `CrossVendorDDLTests` (~2,000 lines)
are dead code in the app flow. Either relax the guard or treat this branch as incomplete
groundwork; as shipped, cross-engine transfers do not happen, on a branch named
`feat/transfer-cross-engine-ir`.

---

## Medium 9: `processedRows` double-counted (progress over 100%)

Prepared and salvage paths count each row twice.

- `flush` does `state.processedRows += batch.count`.
- `writeChunks:71` then does `self.state.processedRows += written - before` for the same rows.
- `salvageChunk:337` increments `processedRows` itself and returns the count the caller adds again.

The bulk path counts once. Result: the progress bar reads roughly 2x for
MySQL-with-local-infile-off, `continueOnError`, and salvage runs. Cosmetic, but the accounting
should be single-sourced. Note this is the progress bar; High 5 is the separate 2x in the final
report figure.

---

## Medium 10: Checkpoint mode is hardcoded, making the store's guard dead

`DataTransferService+Writer.swift:205` and `:250` both pass `mode: .emptyThenTransfer` as a
literal. `TransferCheckpointStore.record:88` guards `guard mode == .emptyThenTransfer else { return }`,
documented as "mode `copy` never writes a checkpoint", so that guard can never fire. A `.copy`
run writes checkpoint files it can never resume from, and they are cleaned up only on a fully
clean finish.

---

## Medium 11: Chunk queries use `LIMIT` on engines that have no `LIMIT`

`TransferChunkPlanner.chunkQuery:52` unconditionally appends `LIMIT \(chunkSize)`.
`Comparison.tupleOr` is documented as covering SQL Server, and `TransferVendor` includes
`.mssql`, but SQL Server needs `TOP` or `OFFSET ... FETCH`, and Oracle needs `FETCH FIRST`.
Every chunk query against such a source is a syntax error, so the whole data phase fails.

Latent, not currently triggerable. Neither engine is installed on the development machine, and
both are registry-only plugins, so no local test run can reach this path. It stops being latent
the moment any user installs the MSSQL or Oracle plugin and picks that engine on both ends of a
transfer, which the same-type guard (High 8) permits. Rated Medium for that reason rather than
dismissed: the defect ships, it just does not show up in local testing.

---

## Medium 12: MySQL `primaryKeyRangeBoundaries` ignores its `schema` parameter

`MySQLPluginDriver+Chunking.swift:24`. The signature takes `schema: String?` and never reads it;
the MIN/MAX query is `FROM \(quoteIdentifier(table))` only. When the transfer endpoint's database
differs from the connection's current database, boundaries come from the wrong table, or the
query fails.

---

## Medium 13: MySQL range boundaries parse MIN/MAX as `Double`

Same file, `:28`. `Double(minText)` and `Double(maxText)` lose precision above 2^53 for `bigint`
keys, and `boundaryText:50` falls back to `String(value)`, which produces scientific notation
that then feeds a numeric literal. Boundary drift can mis-split ranges.

---

## Medium 14: Retry after an ambiguous commit can duplicate rows

`TransferErrorClassifier.withRetry:53` re-runs its whole body on a retryable error, and in
`writeCommittedChunk:161` that body is the entire begin/write/commit. If the commit succeeded
but its acknowledgement was lost (`CR_SERVER_GONE`, `CR_SERVER_LOST`, SQLSTATE `08*`), the retry
inserts the chunk again. Contradicts the doc claim "nothing is written twice". A table with a
primary key turns this into a constraint error; a table without one silently duplicates.

---

## Low 15: The report renders a mismatch as an equation

`TransferReportView.swift:88` builds `"\(sourceCount.formatted()) = \(targetCount.formatted())"`
unconditionally and only varies the colour and the help text, so a failed verification reads
"1,000 = 900" in orange. Use a different separator when `sourceCount != targetCount`.

---

## Low 16: `TransferIdentifierMap` folds case on targets that preserve it

`TransferIdentifierPolicy.swift:108` computes the collision key as
`policy.fold(shortened).lowercased()`. The unconditional `.lowercased()` overrides `fold`, which
returns the identifier unchanged for `.preserve`. Every vendor policy is currently `.preserve`
(`:29-36`), so `fold` never does anything and collision detection is case-insensitive everywhere.
`Foo` and `foo` produce a false `.identifierCollision` warning on PostgreSQL. Warning-only, and
limited to generated index and constraint names.

---

## Withdrawn

Two findings from the original review passes did not hold up and are recorded here so they are
not re-reported.

**"Empty tables never checkpoint in `commitPerChunk` mode."** False, on both the premise and the
conclusion. The reader does yield a chunk for an empty table: `+Copy.swift:153` computes
`isLast = rows.count < planner.chunkSize`, which is `0 < 10_000`, then yields it at `:162`.
`writeCommittedChunk:202` records the checkpoint because its condition
`chunk.cursor != nil || chunk.isLast` matches on `isLast`, with `isComplete: true`. Empty tables
checkpoint correctly and do not re-run on resume.

**"Bulk salvage leaves foreign key checks off on the pooled connection."** The reasoning was that
`salvageChunk:309` flips `state.useBulk = false`, so `restoreWriter:352` takes the sink branch
even though the bulk branch disabled FK checks through `target.setForeignKeyChecks`. That
combination is unreachable: `TransferLoadStrategyResolver` returns `.preparedBatch` whenever
`continueOnError` is true, and `writeCommittedChunk:184` only reaches salvage when
`continueOnError` is true, so `useBulk` is never true at that point. The bulk branch inside
`salvageChunk` is dead code, not a live bug. Worth deleting, but it corrupts nothing.

---

## ABI check: clean

The PluginKit changes are correctly additive:

- All six new `PluginDatabaseDriver` requirements (`bulkLoadWriter`, `serverLimits`,
  `constraintDisableCapability`, `primaryKeyRangeBoundaries`, `exportSnapshotToken`,
  `adoptSnapshotToken`) have default implementations.
- `PluginColumnDefinition` gained fields with the old init preserved under
  `@_disfavoredOverload` and a new full init.

No removed requirements, no `@frozen` layout change. No version bump needed per the documented
rules.

---

## Bottom line

Critical 1 (deadlock) and Critical 2 (silent data loss) must be fixed before this merges.
Each independently makes the headline feature unusable for common cases, and Critical 2
destroys data silently while reporting success.

High 3 and High 4 sit underneath them: fixing the deadlock makes large tables run, which is
exactly when the lane and pool bugs start firing. They should be fixed in the same pass, not
after.

High 8 means the branch does not deliver what its name says. That is a scope decision, not a
defect, but it should be settled before merge.

The suite is green with Critical 1 and Critical 2 both live, so passing tests are not evidence
here. Fix the two criticals behind an end-to-end pipeline test, not unit tests over the pieces.

## Resolved questions

Answered by the author, kept for the record.

1. **Are MSSQL and Oracle reachable as a transfer source today?** No. Neither is installed on
   the development machine, and both are registry-only plugins. Medium 11 is therefore latent
   rather than active, and is rated on the assumption that a user can install those plugins.
2. **Is `TransferStructureBuilder` hardcoding `unsigned: false` intended?** Yes. It matches the
   old default and is not a regression. The consequence stands as a known limitation: a MySQL
   to MySQL unsigned column does not round-trip, so an `unsigned` column arrives at the target
   signed and silently narrows its range at the top end.
3. **Was `TransferBackpressureGate.release()` deliberately deferred?** No, it was missed. See
   the test gap note under Critical 1.

## Open questions

None outstanding.
