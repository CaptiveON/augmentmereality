# Streetscape geometry ownership and bounds

This note covers the Streetscape portion of `GeospatialEngine`, not the whole AR
concurrency migration. The installed ARCore iOS headers describe
`GARStreetscapeGeometry` and `GARMesh` as immutable, but neither is declared
`Sendable`. `GARMesh.vertices` and `triangles` are raw pointers. The installed
RealityFoundation Swift interface marks `MeshResource.generate(from:)` and
`generateAsync(from:)` `@MainActor`.

| Stage | Owner | Transfer and release |
| --- | --- | --- |
| `GARFrame`, geometry, mesh, raw pointers | Main actor consuming `GARSession.update` | A pending capture retains its `GARMesh` on the main actor. It copies at most 1,024 vertices and 1,024 triangles across **all** captures per GAR update, then releases the SDK object before queueing the owned snapshot. Departure, policy invalidation, stop, and memory pressure release partial captures. |
| Swift vertex/index snapshot | Serial `streetscape-mesh` queue | The snapshot is `Sendable` value data. The queue checks the locked ID/generation mailbox before its linear validation and passes the result back to the main actor. No SDK or RealityKit object enters this queue. |
| `MeshDescriptor`, `LoadRequest<MeshResource>`, entity, scene | Main actor and RealityKit's asynchronous generator | The descriptor is built after validation on the documented actor. `generateAsync` supplies the resource asynchronously. Installation uses the **latest tracked transform from a main-actor GAR update**, and requires the same admission token, ID, and scene presence. |
| Relevance mailbox | Locked value-only box | Its `@unchecked Sendable` invariant is limited to a lock-guarded set of `UUID`s and one `Sendable` token. It never owns SDK pointers, snapshots, or RealityKit resources. |

An `OutstandingWorkBudget` ticket covers capture, queued/running validation,
and RealityKit generation. Scene invalidation clears partial captures and their
tickets. Already queued or generating jobs retain their tickets and payload
reservations until their own completion, including after a new session starts.
Late results cannot install into the new generation. A unique build ticket also
prevents an old result from taking a newly admitted job's place when memory
pressure resets the pipeline without changing the session token. A silent
RealityKit publisher fails after 30 seconds and cancels upstream before its
ticket retires. The ledger counts installed meshes and outstanding reservations
together.

The current admission limits are 8 total outstanding builds, 24 installed plus
reserved meshes, 160,000 triangles, and 8 MiB of estimated vertex/index payload.
Each mesh is limited to 32,000 vertices and 60,000 triangles. These are raw
payload limits; RealityKit's private GPU storage is not measurable from this
API. Nearer tracked buildings are admitted first and may evict farther installed
ones. Invalid counts and arithmetic overflow are rejected before capture
allocation or pointer reads. A malformed ID gets a 15-second retry cooldown so
a later SDK snapshot under the same ID can recover; admission generation changes
clear the cooldown. A memory warning releases installed meshes and
partial captures and pauses repopulation for 30 seconds; old asynchronous jobs
still retire normally. These values are policy starting points and require
Release-device measurement against the startup and sustained protocols.

The 1,024/1,024 copy quota trades mesh arrival time for bounded work in one GAR
update. At a sparse maintenance cadence, large buildings can take multiple
seconds to appear. This needs field tuning; the code and simulator tests do not
establish physical thermal or frame pacing results. The work also does not
claim app-wide Swift 6 readiness. The remaining warnings and callback/Metal
ownership boundaries belong to the broader concurrency inventory.

SDK references checked against the installed Xcode/ARCore package and official
documentation on September 30, 2026:

- [ARCore `GARMesh` reference](https://developers.google.com/ar/reference/ios/interface/GARMesh)
- [ARCore `GARStreetscapeGeometry` reference](https://developers.google.com/ar/reference/ios/interface/GARStreetscapeGeometry)
- [ARCore Streetscape iOS guide](https://developers.google.com/ar/develop/ios/geospatial/streetscape-geometry)
- [Apple `MeshResource.generateAsync(from:)`](https://developer.apple.com/documentation/realitykit/meshresource/generateasync(from:))
