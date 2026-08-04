# Running the DreamReason mesh on Vast.ai

The p2p-gpu toolkit is single-instance by design. Mesh mode spans instances, so
three things differ from a normal deploy.

## What changed, and why

**1. No tailnet.** The toolkit has no Tailscale support — access is SSH tunnel
plus Cloudflare, and Tailscale in a rented container needs `/dev/net/tun` and
`NET_ADMIN`, which are not guaranteed. So peers come from one of two sources:
declared by address in `config/mesh-peers.json` (`MESH_PEER_SOURCE=auto|static`),
or read from the Vast.ai account roster (`MESH_PEER_SOURCE=vastai`).

`scripts/mesh-connect.sh` writes the peer file for you from a roster of SSH
endpoints, tunnelling 3002 and 4000 over port 22. That is the option to reach
for first, because it needs nothing from the provider — see Option A below.
Vast.ai discovery needs no peer file at all, but only works if the instances
were created with 3002 and 4000 published, and it carries a security tradeoff
and a hard limitation; both are stated below.

**2. Ports are remapped.** Vast.ai publishes each internal port on a different
external one, exposed as `VAST_TCP_PORT_<internal>`. Peers therefore carry
explicit `api_port` and `litellm_port`; the old assumption that every node uses
3002 and 4000 only holds on a tailnet.

> **These ports must be requested when the instance is CREATED.** They cannot
> be opened afterwards. Ask for **3002** and **4000** on every instance, or the
> nodes cannot reach each other and every peer reports `unreachable`.

**3. The coordinator is opt-in.** It ships disabled and only builds when mesh
mode is selected, so a normal single-instance deploy does not spend minutes
building an image it will never run.

## Deploy the right code first

The installer clones a repository rather than using the checkout you run
`setup.sh` from, and it defaults to upstream `main` — which has none of this.
Point it at the branch you want:

```bash
export ODS_REPO_URL="https://github.com/Arifuzzamanjoy/DreamServer.git"
export ODS_REPO_BRANCH="feat/mesh-reasoning"
```

If ODS is already installed, phase 3 reuses `/home/dream/ODS` and never
re-clones, so the exports alone will not replace an existing checkout. Either
remove it first, or repoint it by hand:

```bash
sudo -u dream git -C /home/dream/ODS remote set-url origin "$ODS_REPO_URL"
sudo -u dream git -C /home/dream/ODS fetch origin "$ODS_REPO_BRANCH"
sudo -u dream git -C /home/dream/ODS checkout "$ODS_REPO_BRANCH"
```

## Deploy

On **each** instance, as root:

```bash
export ODS_MESH=1
export ODS_MESH_KEY="$(openssl rand -hex 24)"   # SAME value on every node
bash setup.sh --mesh
```

Generate `ODS_MESH_KEY` **once** and reuse it. A mismatch does not fail loudly —
peers come back as `state=unauthorized`, which is a distinct state precisely so
you can tell it apart from a network problem.

At the end, each node prints its own coordinates:

```json
{ "hostname": "vast-a", "host": "203.0.113.10", "api_port": 41287, "litellm_port": 41288 }
```

## Wire the peers together

Pick one of the three sources.

### Option A — SSH tunnels from a roster (works on any instance)

Use this unless your instances were created with 3002 and 4000 published. Vast
only opens ports requested at instance creation, and 22 is the one that is
always there, so tunnelling the service ports over SSH forms a mesh out of
instances that were never provisioned for one.

Put the same roster on every node — the order fixes the port mapping, so an
identical file gives every node an identical view:

```bash
cp config/mesh-nodes.example.conf config/mesh-nodes.conf
# one line per node:  <name> <user>@<host>:<ssh-port>
# on Vast the ssh-port is $VAST_TCP_PORT_22, not 22
```

Then on **each** node:

```bash
bash scripts/mesh-connect.sh init     # prints a public key
```

Install that public key in every *other* node's `~/.ssh/authorized_keys`, then:

```bash
bash scripts/mesh-connect.sh up
```

That allocates tunnel ports from each node's roster position, installs one
systemd unit per peer, and writes `config/mesh-peers.json` itself. Nothing is
hand-allocated and nothing is hand-edited.

systemd owns tunnel lifetime deliberately. A bare `ssh -N -f` dies with its
parent shell and never returns, which surfaces days later as peers that were
online at deploy time and are unreachable now, with nothing in any log to say
when. `Restart=always` makes a dropped tunnel a five-second gap instead.

Check it any time with:

```bash
bash scripts/mesh-connect.sh status
```

### Option B — Vast.ai discovery (no peer file)

Each node asks Vast.ai which instances the account is running and derives its
peer list from that. Nothing to edit when a node is preempted or replaced.

Read [the security tradeoff](#the-key-on-the-node) before enabling this. In
short: the key is account-scoped, it sits on hardware you do not own, and there
is no per-instance key that can do the job.

**Label every instance at creation** with a name starting `dreamreason-mesh`.
Discovery filters on that prefix, and an instance without it is invisible to its
siblings no matter how healthy it is.

Then, on **each** instance before `setup.sh`:

```bash
export ODS_MESH_PEER_SOURCE=vastai
export ODS_VAST_API_KEY="<account key, scoped to instance_read>"
```

Create the key with `instance_read` and nothing else. Vast's default keys have
full account access, including instance creation and deletion.

On an already-installed node, set the same thing in `.env` and restart:

```bash
MESH_PEER_SOURCE=vastai
ODS_VAST_API_KEY=<account key, scoped to instance_read>
MESH_VAST_LABEL_PREFIX=dreamreason-mesh
MESH_VAST_POLL_TTL_SECONDS=30
CONTAINER_ID=<this instance's id>
```

```bash
./ods-cli restart dashboard-api
```

`CONTAINER_ID` is injected by Vast and is what lets a node leave itself out of
its own peer list. Phase 13 copies it into `.env` automatically; set it by hand
only if that step warned.

The roster is cached for `MESH_VAST_POLL_TTL_SECONDS` (30 by default), so a
preempted node drops out of routing within about that long without anyone
touching a config file.

### Option C — declared peers

On every node, write `config/mesh-peers.json` listing the **other** nodes (a
node does not list itself):

```json
{ "peers": [
  { "hostname": "vast-b", "host": "198.51.100.22", "api_port": 39104, "litellm_port": 39105 }
] }
```

### Either way, confirm discovery sees them

```bash
curl -s -H "Authorization: Bearer $DASHBOARD_API_KEY" \
    localhost:3002/api/mesh/peers | python3 -m json.tool
```

Expect `peer_source` to match the source you configured — `"vastai"` or
`"static"` — and `state: "online-idle"` per peer. Anything else is diagnostic,
not a generic failure:

| state | meaning |
|---|---|
| `unreachable` | port not published at instance creation, or wrong external port |
| `timed-out` | reachable but slow — usually a model still loading |
| `unauthorized` | `MESH_PEER_API_KEY` differs between nodes |
| `online-busy` | peer is up but its GPU is above the idle threshold |

The endpoint itself failing is a different class of problem, and in `vastai`
mode the status says which:

| status | meaning |
|---|---|
| 503 | `ODS_VAST_API_KEY` is unset, or the Vast API is unreachable |
| 502 with `rejected ODS_VAST_API_KEY` | the key is wrong or lacks `instance_read` |
| 502 with `rate-limited` | too many nodes polling; raise `MESH_VAST_POLL_TTL_SECONDS` |
| 504 | the Vast API did not answer in time |

None of these degrade to an empty peer list. A misconfigured node reports a
failure rather than quietly reporting a mesh with no peers, because those two
look identical from the outside and have nothing in common as fixes.

A node that Vast reports as running but that never published 3002 or 4000 is
dropped from the roster with a warning in `docker logs ods-dashboard-api`
naming the instance and the port. It is not listed as an unreachable peer,
because the detail would read "connection refused" and send you looking at the
network instead of at instance creation.

Then generate the peer routes and restart, on every node:

```bash
curl -s -H "Authorization: Bearer $DASHBOARD_API_KEY" localhost:3002/api/mesh/peers \
  | python3 scripts/generate-mesh-litellm-config.py -o config/litellm/mesh.yaml
./ods-cli restart litellm dreamreason
```

## Reaching it from your laptop

The tunnel only forwards the dashboard port unless you ask for everything:

```bash
FULL_TUNNEL=1 bash connect-tunnel.sh
```

That forwards every discovered service port, including the coordinator on
9200. A plain `ssh -L 8080:localhost:8080` will not reach it — that is what
ERR_CONNECTION_REFUSED on http://localhost:9200 means. The manual equivalent:

```bash
ssh -p <ssh-port> root@<host> \
    -L 9200:localhost:9200 \
    -L 3001:localhost:3001 \
    -L 3000:localhost:3000 \
    -L 4000:localhost:4000
```

## Verify

```bash
bash scripts/ods-doctor.sh          # expect zero ODS-RUNTIME-MESH-* findings
curl -s localhost:9200/health       # coordinator
curl -s -X POST localhost:9200/v1/reason \
    -H 'Content-Type: application/json' \
    -d '{"question":"Solve for x: 3x + 7 = 22","skills":["algebra","reasoning","general"]}'
```

A good response names the peer that won and why, and the answer is that peer's
answer verbatim — the aggregator selects, it never blends.

## Using it from the UI

After regenerating `mesh.yaml`, Open WebUI's model dropdown gains a **`mesh`**
entry alongside the individual `peer-*` models. Picking `mesh` sends the turn
through fan-out and judge selection; picking a `peer-*` model talks to that one
peer directly, with no selection.

Set `MESH_SHOW_RATIONALE=true` to append the winning peer and the reason to
each reply — useful while validating, noisy afterwards.

The full audit trail is always present on the `ods_mesh` field of the response
for anything that inspects it, and `POST /v1/reason` on port 9200 returns it
directly.

## Testing on a single instance

One node has no peers, so `mesh` has nothing to fan out to and returns 502.
To exercise selection on one machine, run three llama-servers on the stack
network and register them:

```bash
cd /home/dream/ods
docker compose -f docker-compose.mesh-dev.yml up -d

python3 scripts/generate-mesh-litellm-config.py --dev-peers \
    --peers-json <(echo '{"peers":[]}') -o config/litellm/mesh.yaml
docker restart ods-litellm ods-dreamreason
```

Those peers are bare llama-servers, so they are addressed on `:8080` rather
than a peer LiteLLM on `:4000`. The gateway rule applies to real peers on other
machines; there is no second gateway here to route through.

Both models must already be in `data/models`:
`Qwen3.5-2B-Q4_K_M.gguf` and `Qwen3.5-9B-Q4_K_M.gguf`. Use
`MESH_DEV_REASONING_GGUF=Qwen3.5-2B-Q4_K_M.gguf` to run all three on the 2B if
VRAM is tight.

## Benchmark

```bash
bash scripts/mesh-bench/fetch-bbh.sh ./bbh
python3 scripts/mesh-bench/run-bbh.py \
    --task ./bbh/logical_deduction_three_objects.json --limit 250 \
    --coordinator http://localhost:9200 --litellm http://localhost:4000/v1
```

Expect latency to get worse and token use to rise several-fold; see
`scripts/mesh-bench/README.md` for why that is structural rather than a
regression.

## Security note

`expose_ports_for_vastai()` rebinds every published port from `127.0.0.1` to
`0.0.0.0`, which is what makes cross-instance peering possible — and also means
LiteLLM and dashboard-api are reachable from the public internet. Both require
auth (`LITELLM_KEY` is generated by the installer, dashboard-api enforces
`DASHBOARD_API_KEY`), so this is not an open relay, but treat those keys as
production secrets and tear instances down when the test finishes.

### The key on the node

Vast.ai discovery needs an **account-scoped** API key on every node. This is a
real risk and there is no version of the in-node poller that removes it.

The obvious mitigation does not exist. Vast injects a per-instance key as
`CONTAINER_API_KEY`, but it is restricted to starting, stopping and destroying
*its own* instance — it cannot list the account's other instances, so it cannot
do discovery. Anything that enumerates siblings is account-scoped by
construction.

What you can do:

* **Scope the key to `instance_read`.** Vast separates `instance_read` (show
  instance, show instances) from `instance_write` (create, delete). A default
  key gets both, plus billing and key management — the docs say so plainly. An
  `instance_read` key on a rented box cannot destroy your fleet. Scoped keys
  have to be created via the CLI or API, not the web console.
* **Understand what it still leaks.** An `instance_read` key enumerates the
  whole account roster — labels, public IPs, GPU models, hourly cost — to
  anyone who can read the container's environment. That container runs on
  hardware owned by a stranger who can read its memory and disk. Treat the key
  as disclosed the moment it lands on the node.
* **Rotate it when the test ends**, along with `DASHBOARD_API_KEY`,
  `MESH_PEER_API_KEY` and `LITELLM_KEY`.

Do not read "scoped to `instance_read`" as "safe". It is a smaller blast radius,
not an absent one.

### Controller-push: the variant where no key touches the mesh

The key only has to be on a node because the node is the thing doing the
polling. Move the polling off-mesh and the problem goes away. This is designed
but not implemented; it is the shape to build if this graduates past a testbed.

A controller — a laptop, a CI runner, any host you actually own — holds the
Vast key and does what each node does today:

1. poll `GET /api/v1/instances/`, filter by `actual_status` and label prefix
2. resolve external 3002/4000 from each instance's port map
3. `POST` the resulting roster to each node, authenticated with
   `MESH_PEER_API_KEY`, which every node already shares

Nodes keep `MESH_PEER_SOURCE=static` and gain a written peer file they did not
have to be told about by a human. `probe_peer` stays the trust boundary exactly
as it is now, so a compromised or stale controller can still only cause peers to
report `unreachable`; it cannot manufacture a peer that answers.

What it costs, stated honestly: the controller is a new single point of failure
and has to stay running for membership to track reality. The in-node poller has
no such dependency. That is the whole trade — a credential on every rented box
in exchange for not needing a machine you own to be up.

Two smaller wins come with it. The Vast API gets polled once per mesh instead of
once per node, which matters because the rate limit is per account and
undocumented (see the research note). And the roster is computed in one place,
so every node agrees on membership instead of converging on it.

## What this is not

Vast.ai discovery finds instances **inside a single Vast.ai account**. A node
can only discover peers it already shares a billing relationship with.

That is enough for a testbed and it is not the volunteer mesh. Open membership
needs a rendezvous point and peer identity that does not come from a cloud
vendor's billing API, and no amount of work on this source produces either. It
is scaffolding for testing fan-out and judge selection across real machines,
and it should be replaced rather than extended.

The details behind all of this — response schema, the 25-per-page cap, rate
limits, key scopes, and whether `public_ipaddr` can change — are in
[research/vastai-discovery.md](research/vastai-discovery.md) with source URLs.
