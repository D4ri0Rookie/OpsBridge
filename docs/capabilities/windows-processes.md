# Windows processes

## Scope

Lists OS processes via `Get-Process`. Second capability in the `Windows`
area, added to demonstrate that the Pode -> middleware -> route -> service
pattern (see [architecture.md](../architecture.md)) generalizes beyond the
reference endpoint, not to build a general process-management surface -
there is no start/stop/kill operation here, only listing.

Unlike [`GET /api/v1/windows/services`](../api.md#get-apiv1windowsservices),
`Get-Process` is genuinely cross-platform (it reads `/proc` on Linux), so
this endpoint returns real data on any host the runtime runs on, not just
Windows - there is no "unsupported platform" response.

## Method & path

```
GET /api/v1/windows/processes
```

## Parameters

| Name | Required | Description |
|---|---|---|
| `name` | no | Exact process name or wildcard (e.g. `pwsh*`), 1-256 characters. Omit to list every process. |

Same validation as `windows/services`: blank or whitespace-only -> `422`
`EMPTY`; longer than 256 characters -> `422` `TOO_LONG`.

## Example request

```
GET /api/v1/windows/processes?name=pwsh
```

## Example response

```json
200 OK
{
  "data": [
    { "id": 4213, "name": "pwsh", "workingSetBytes": 87654321 }
  ]
}
```

`workingSetBytes` is the process's current working set (resident memory),
read directly from `.WorkingSet64` - present and safe to read on every
process on every platform this runtime supports. Fields deliberately not
included: `path`, `mainModule`, `startTime` - reading those can throw
`Access is denied` for a protected/system process even without attempting
to change anything, which would turn a routine listing into an
unpredictable 500 for specific processes. Keeping to always-readable fields
keeps this endpoint as deterministic as the reference implementation.

## Error responses

| Status | Code | When |
|---|---|---|
| `422` | `VALIDATION_ERROR` | `name` blank/whitespace-only or over 256 characters - see [api.md](../api.md#error-contract) for the envelope shape |
| `404` | `PROCESS_NOT_FOUND` | `name` was a specific, non-wildcard value that matched no process |

A wildcard `name` that matches nothing returns `200` with an empty `data`
array, not `404` - same rule as `windows/services`.

## Idempotency

`safe` - read-only `GET`, no side effects.

## Known limitations

- No filtering beyond `name` (e.g. by CPU, memory, user) - not added because
  nothing today needs it; see [architecture.md](../architecture.md) on not
  building a generic query engine ahead of a real requirement.
- `workingSetBytes` reflects a single instant; there is no historical or
  sampled data.
- Two processes can share the same `name` (e.g. multiple `pwsh` instances) -
  `data` lists every matching process, distinguished by `id`.

## Operational notes

Subject to the runtime's existing soft request timeout and correlation id
handling like every other endpoint - see the
[capability contract](../api.md#capability-contract) in api.md. No new
timeout, retry, or rate-limiting behavior is introduced for this capability.
