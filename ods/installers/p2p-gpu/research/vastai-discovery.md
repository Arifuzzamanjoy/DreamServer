# Vast.ai as a peer source for the DreamReason mesh

Findings behind `MESH_PEER_SOURCE=vastai`. Everything here was checked against
the live documentation in August 2026; source URLs are on each claim. Where the
docs contradict themselves, both readings are recorded rather than resolved by
guess.

## Verdict

The approach holds. Nothing found contradicts using
`GET /api/v1/instances/` as the mesh roster. Four things change the shape of the
implementation and are described below: the port field is a Docker-style map and
not a list of ints, the page size is capped at 25, the rate limit is real but
undocumented, and the per-instance key cannot enumerate siblings — so the key on
the node has to be an account key.

## 1. The endpoint and its response

`GET https://console.vast.ai/api/v1/instances/`, authenticated with
`Authorization: Bearer $VAST_API_KEY`.
Source: https://docs.vast.ai/api-reference/instances/show-instances
and https://docs.vast.ai/api-reference/authentication

Response envelope:

```json
{
  "success": true,
  "instances_found": 5,
  "total_instances": 42,
  "label_counts": {"ML Training Job": 3, "": 2},
  "next_token": "eyJ2YWx1ZXMiOiB7ImlkIjogMTIzfX0=",
  "instances": [ ... ]
}
```

The fields discovery needs, from the documented example instance:

| field | example | used for |
|---|---|---|
| `id` | `312` | self-exclusion |
| `label` | `"ML Training Job 2025"` | mesh membership filter |
| `actual_status` | `"running"` | liveness filter |
| `public_ipaddr` | `"192.0.2.45"` | peer host |
| `ports` | see below | external port resolution |

### The port mapping field

This is the part that was easiest to get wrong. On the v1 list endpoint `ports`
is a **Docker-style map**, keyed by `"<internal>/<proto>"`, whose value is a
**list** of binding objects, and whose `HostPort` is a **string**:

```json
"ports": {
  "8888/tcp": [{"HostIp": "0.0.0.0", "HostPort": "8888"}],
  "22/tcp":   [{"HostIp": "0.0.0.0", "HostPort": "20000"}]
}
```

Source: https://docs.vast.ai/api-reference/instances/show-instances

Two things follow. First, resolving the external port for internal 3002 means
looking up the key `"3002/tcp"`, taking element 0, reading `HostPort`, and
casting to int. Second, the `8888/tcp` entry in Vast's own example maps to 8888
— an identity mapping — while `22/tcp` maps to 20000. So remapping is not
guaranteed to change the number, and code must read the mapping rather than
assume the external port differs from the internal one.

**Documented contradiction.** The v0 single-instance endpoint documents `ports`
as an array of integers:

```
ports:
  type: array
  items: {type: integer}
  example: [8080, 8081]
```

Source: https://docs.vast.ai/api-reference/instances/show-instance

These two cannot both be right for the same field. The implementation follows
the v1 list endpoint, because that is the endpoint it calls. The consequence is
that if Vast ever serves the v0 shape on v1, port resolution returns nothing and
every peer is skipped with a logged warning rather than being handed a wrong
port — which is the correct direction to fail in.

## 2. Pagination: the page size is capped at 25

`limit` defaults to 25 and its documented **maximum is also 25**. Paging is
keyset-based: the response carries `next_token`, which is passed back as
`after_token`.
Source: https://docs.vast.ai/api-reference/instances/show-instances

This matters more than it looks. An account with more than 25 instances that
does not paginate sees only the first page, and the missing nodes are
indistinguishable from nodes that were never rented. The implementation
paginates and caps the walk, raising if the cap is hit, rather than truncating
silently.

## 3. Rate limits

Real, and not numerically documented. A 429 carries the body
`API requests too frequent: endpoint threshold=...` with the threshold
interpolated per endpoint; the docs state the API
"does not currently set standard rate-limit headers (for example `Retry-After`),
so clients should apply their own backoff strategy."
Source: https://docs.vast.ai/api-reference/rate-limits-and-errors

The official CLI backs off on 429 starting at 0.15s and multiplying by 1.5 per
attempt.
Source: https://github.com/vast-ai/vast-python/blob/master/vast.py

Arithmetic for this design: N nodes each polling every 30s is N/30 requests per
second against one account. At 5 nodes that is 0.17 req/s; at 50 nodes, 1.7
req/s, which is around the only threshold value the docs ever print
(`threshold=1.0`). So the in-node poller is fine for a testbed and is not fine
for a large mesh — a second reason, on top of the key-distribution problem in
§5, that the controller-push variant is the better shape at size.

This implementation does **not** retry on 429. It surfaces the 429 as a failed
call. Retrying inside a request handler that is itself polled would multiply
load against an endpoint that is already refusing it, and the house rule is that
a failed API call surfaces as a failed API call.

## 4. Can `CONTAINER_API_KEY` enumerate siblings?

**No.** This is the finding that decides the security story.

`CONTAINER_API_KEY` is a per-instance key injected into the container. It is a
restricted key that can start, stop, or destroy *that* instance — it is not an
account key and cannot list the account's other instances.
Source: https://docs.vast.ai/guides/instances/docker-environment

So there is no least-privilege key already sitting on the box that can do
discovery. Discovery from inside a node requires an **account-level** key placed
there deliberately.

What does exist is scoped keys. Permissions are categorised, and
`instance_read` — which grants "Show Instance" and "Show Instances" — is
separate from `instance_write`, which grants "Create Instance" and "Delete
Instance".
Source: https://docs.vast.ai/api-reference/permissions

Keys can further carry constraints on parameter values using `eq`, `lte` and
`gte`, e.g. `"constraints": {"id": {"eq": 1227}}`. Constrained keys must be
created via the CLI or API, not the web console.
Source: https://docs.vast.ai/api-reference/permissions-and-authorization

Default keys have full account access. The docs are explicit:
"Default keys have full access to your account, including billing, instance
creation, and key management."
Source: https://docs.vast.ai/guides/reference/api-keys

This does not make the in-node key safe. It makes it *less bad*: an
`instance_read`-only key on a rented box cannot destroy the fleet, but it still
enumerates the account's entire roster — labels, IPs, GPUs, hourly costs — to
anyone who reads the container's environment, and the container runs on hardware
owned by a stranger. §6 of MESH.md states this plainly rather than burying it.

## 5. Does `public_ipaddr` change during an instance's life?

Yes, and the API is the fresher source — which is an argument for this approach
rather than against it.

Vast's own container documentation says `PUBLIC_IPADDR` is set at instance
startup and is "not automatically updated if the instance's IP address changes",
and directs you to read the current address back from the API with
`vastai show instance $CONTAINER_ID --api-key $CONTAINER_API_KEY`.
Source: https://docs.vast.ai/guides/instances/docker-environment

Consequences for the mesh:

* A hand-written `config/mesh-peers.json` records an address that can go stale
  with no signal. The API roster does not, up to the poll TTL.
* Instances also carry a `static_ip` boolean, so a stable address is a property
  of the rental rather than a guarantee of the platform.
* A changed IP still degrades correctly here: the roster returns the new address
  on the next poll, and in the window before that, `probe_peer` reports the old
  one as `unreachable`. It never reports a peer as eligible on an address that
  no longer answers.

## 6. What none of this fixes

The roster is one Vast account. A node can only discover siblings it already
shares a billing relationship with. That is enough for a testbed and it is not
the volunteer mesh — no amount of polish on this source turns it into
open-membership discovery, which needs a rendezvous point and peer identity that
does not come from a cloud vendor's billing API. Recorded here so the next
person does not mistake this for the discovery story.

## Sources

* https://docs.vast.ai/api-reference/instances/show-instances
* https://docs.vast.ai/api-reference/instances/show-instance
* https://docs.vast.ai/api-reference/authentication
* https://docs.vast.ai/api-reference/rate-limits-and-errors
* https://docs.vast.ai/api-reference/permissions
* https://docs.vast.ai/api-reference/permissions-and-authorization
* https://docs.vast.ai/guides/reference/api-keys
* https://docs.vast.ai/guides/instances/docker-environment
* https://github.com/vast-ai/vast-python/blob/master/vast.py
