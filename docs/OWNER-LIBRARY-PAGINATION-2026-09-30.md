# Owner-library query contract (#26)

`FirebaseDropStore.loadOwnerPage(after:limit:)` reads only `drops` documents
whose `ownerUid` equals the signed-in UID. It orders by document ID, starts
after the previous ID, and limits each query to 64 documents. The ID is
immutable across a location or content edit, so an edit does not move a row to
another page. A new ID inserted before the cursor is picked up by the next
full sweep. The library advances one server-served page per refresh and shows
the unique loaded-row count, page count, read-document count, last page latency,
and completion state through `ownerSyncProgress`. The Drops library offers
continuation while a sweep is incomplete.

This is account library synchronization. Nearby AR filtering runs against the
loaded local library. There is no public geographic list query; shared links
still read an exact document ID. `GeoHash.queryBounds` is not called in
production because there is no separately authorized geographic discovery
API. A nearby API would need its own rules, geohash bounds, exact distance
filter, cursor per bound, and duplicate handling before it could be exposed.

The query returns at most 64 snapshots per page. For a stable owner library of
10 rows, one page returns 10 documents. For 235 rows, four pages return
64 + 64 + 64 + 43 documents. An exact multiple of 64 needs one final empty
query to establish completion. Firestore's minimum charge for an empty query
is one document read. An interrupted page retries from the same cursor and
may repeat those documents; a cache-served page contributes display values but
does not advance the server cursor or earn a clean-sync claim. A page carrying
pending local Firestore writes also leaves the cursor fixed: latency
compensation can add or remove a document at the page boundary. The library
also leaves the cursor fixed while a save or delete bound to the queried owner
is pending, because a pending deleted document may vanish without useful
per-document pending metadata. A pending mutation bound to an earlier account
does not hold a new account's sweep. Every clean server
page logs its returned document count and elapsed time; `ownerSyncProgress`
exposes cumulative counts and the latest latency so small and large emulator
and device runs can record actual cost. The host-only paged-store test covers
235 rows with three repeated boundary rows and verifies the bounded read count;
its timing is not a Firestore latency measurement.

On the 2026-09-30 native iOS simulator run against the local Firestore emulator,
the production Swift SDK query returned 10 documents in one page (236 ms) and
130 documents in pages of 64, 64, and 2 (20 ms, 16 ms, and 8 ms). These are
local-emulator wall-clock measurements, not production latency promises. A
held local delete made the first page contain 63 documents and report
`reachedEnd=true` with no pending-write metadata, even though the deleted row
was absent from the server-served query. The owner-bound pending-delete guard
therefore prevents a false end-of-sweep claim in an observed SDK case.

Rows already displayed stay displayed during an incomplete page, an offline
cache read, or a failed retry. Rows with pending local writes keep their local
value; edits fetched on earlier pages remain visible across later page reads
even when a stale local copy still exists. Only server-served rows without
pending Firestore writes can earn
the per-row acknowledged fact. Query omission is never deletion evidence.
Tombstones retire only after an independent server-confirmed exact-document
absence check. A received link copy stays in local storage and is not made an
owner row. A UID switch resets the cursor and removes prior-account cloud-only
rows while preserving rows held in the local store with their ownership data.

The deployed rules still allow `list` only for `resource.data.ownerUid ==
request.auth.uid`; this query supplies that equality constraint. A foreign
user cannot enumerate the collection by omitting or changing the filter.
The query uses `ownerUid == uid` plus ascending document ID (`__name__`).
Firestore's automatic ascending `ownerUid` index includes `__name__` as its
final sort key, so no new composite index is expected; confirm on the native
SDK emulator and inspect any production missing-index error before release.
No rules or index deployment is part of this change.

Firestore references: [query cursors](https://firebase.google.com/docs/firestore/query-data/query-cursors),
[index ordering](https://firebase.google.com/docs/firestore/query-data/index-overview),
[billing for queries](https://firebase.google.com/docs/firestore/pricing), and
[Swift query API](https://firebase.google.com/docs/reference/swift/firebasefirestore/api/reference/Classes/Query.html).
