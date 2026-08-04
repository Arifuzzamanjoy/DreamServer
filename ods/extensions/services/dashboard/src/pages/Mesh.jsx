import { memo } from 'react'
import {
  Network, RefreshCw, AlertTriangle, Cpu, Circle, HelpCircle,
} from 'lucide-react'
import { useMeshPeers } from '../hooks/useMeshPeers'

// Every peer state maps to a different fix, so each gets its own colour and
// its own remedy. Collapsing them into "offline" is what makes a mesh
// undebuggable — a refused connection and a slow model are not the same fault.
const STATE_META = {
  'online-idle': {
    label: 'Idle', tone: 'text-emerald-400', dot: 'bg-emerald-400',
    hint: 'Available for work.',
  },
  'online-busy': {
    label: 'Busy', tone: 'text-amber-400', dot: 'bg-amber-400',
    hint: 'GPU above the idle threshold; skipped until it frees up.',
  },
  unreachable: {
    label: 'Unreachable', tone: 'text-red-400', dot: 'bg-red-400',
    hint: 'Connection refused. On Vast.ai the port was probably not requested when the instance was created.',
  },
  'timed-out': {
    label: 'Timed out', tone: 'text-orange-400', dot: 'bg-orange-400',
    hint: 'Accepted the connection then went silent — usually a model still loading.',
  },
  unauthorized: {
    label: 'Unauthorized', tone: 'text-purple-400', dot: 'bg-purple-400',
    hint: 'MESH_PEER_API_KEY differs between nodes.',
  },
  error: {
    label: 'Error', tone: 'text-red-400', dot: 'bg-red-400',
    hint: 'Peer answered with an unexpected status.',
  },
  offline: {
    label: 'Offline', tone: 'text-zinc-500', dot: 'bg-zinc-500',
    hint: 'Reported as not online; never probed.',
  },
}

const stateMeta = (state) => STATE_META[state] || {
  label: state || 'Unknown', tone: 'text-zinc-400', dot: 'bg-zinc-400',
  hint: 'Unrecognised state.',
}

const Stat = memo(function Stat({ label, value, tone = 'text-white' }) {
  return (
    <div>
      <div className="text-xs text-zinc-400">{label}</div>
      <div className={`text-2xl font-semibold ${tone}`}>{value}</div>
    </div>
  )
})

const PeerCard = memo(function PeerCard({ peer }) {
  const meta = stateMeta(peer.state)
  const util = peer.utilization_percent
  return (
    <div className="p-4 bg-zinc-800/50 border border-zinc-700 rounded-xl">
      <div className="flex items-start justify-between gap-3 mb-3">
        <div className="min-w-0">
          <div className="font-medium text-white truncate">
            {peer.hostname || 'unnamed peer'}
          </div>
          <div className="text-xs text-zinc-500 truncate font-mono">
            {peer.address || peer.dns_name || '—'}
          </div>
        </div>
        <div className={`flex items-center gap-1.5 shrink-0 text-xs ${meta.tone}`}>
          <span className={`w-2 h-2 rounded-full ${meta.dot}`} />
          {meta.label}
        </div>
      </div>

      {peer.state.startsWith('online') ? (
        <div className="space-y-2">
          {typeof util === 'number' && (
            <div>
              <div className="flex justify-between text-xs mb-1">
                <span className="text-zinc-400">GPU</span>
                <span className="font-mono text-white">{util}%</span>
              </div>
              <div className="h-1.5 bg-zinc-700 rounded-full overflow-hidden">
                <div
                  className={`h-full rounded-full ${util > (peer.threshold_percent ?? 10) ? 'bg-amber-500' : 'bg-emerald-500'}`}
                  style={{ width: `${Math.min(util, 100)}%` }}
                />
              </div>
            </div>
          )}
          {peer.loaded_model && (
            <div className="flex items-center gap-1.5 text-xs text-zinc-400">
              <Cpu size={12} className="shrink-0" />
              <span className="truncate font-mono">{peer.loaded_model}</span>
            </div>
          )}
          {peer.skills?.length > 0 && (
            <div className="flex flex-wrap gap-1 pt-1">
              {peer.skills.map((skill) => (
                <span
                  key={skill}
                  className="px-1.5 py-0.5 text-[10px] rounded bg-indigo-500/15 text-indigo-300 font-mono"
                >
                  {skill}
                </span>
              ))}
            </div>
          )}
        </div>
      ) : (
        <div className="text-xs text-zinc-400">
          <p>{meta.hint}</p>
          {peer.detail && (
            <p className="mt-1 font-mono text-[11px] text-zinc-500 break-all">
              {peer.detail}
            </p>
          )}
        </div>
      )}
    </div>
  )
})

export default function Mesh() {
  const { mesh, loading, error, refresh } = useMeshPeers()

  if (loading) {
    return (
      <div className="p-8 animate-pulse">
        <div className="h-8 bg-zinc-800 rounded w-1/4 mb-6" />
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          {[...Array(3)].map((_, i) => <div key={i} className="h-40 bg-zinc-800 rounded-xl" />)}
        </div>
      </div>
    )
  }

  const peers = mesh?.peers || []

  return (
    <div className="p-8">
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-3">
          <Network size={22} className="text-indigo-400" />
          <div>
            <h1 className="text-2xl font-semibold text-white">Mesh</h1>
            <p className="text-sm text-zinc-400">
              Peers discovered via{' '}
              <span className="font-mono">{mesh?.peer_source || 'unknown'}</span>
            </p>
          </div>
        </div>
        <button
          onClick={refresh}
          className="flex items-center gap-2 px-3 py-1.5 text-sm bg-zinc-800 hover:bg-zinc-700 border border-zinc-700 rounded-lg text-zinc-300"
        >
          <RefreshCw size={14} /> Refresh
        </button>
      </div>

      {error && (
        <div className="flex items-start gap-3 p-4 mb-6 bg-red-500/10 border border-red-500/20 rounded-xl text-sm">
          <AlertTriangle size={18} className="text-red-400 shrink-0 mt-0.5" />
          <div>
            <p className="text-white">Peer discovery failed</p>
            <p className="text-zinc-400 mt-1">{error}</p>
          </div>
        </div>
      )}

      {!error && (
        <div className="grid grid-cols-3 gap-6 p-5 mb-6 bg-zinc-800/50 border border-zinc-700 rounded-xl">
          <Stat label="Peers" value={mesh?.peer_count ?? 0} />
          <Stat
            label="Idle now"
            value={mesh?.idle_count ?? 0}
            tone={mesh?.idle_count ? 'text-emerald-400' : 'text-zinc-500'}
          />
          <Stat
            label="Reachable"
            value={`${peers.filter((p) => p.state?.startsWith('online')).length}/${peers.length}`}
          />
        </div>
      )}

      {peers.length === 0 && !error ? (
        <div className="flex items-start gap-3 p-6 bg-zinc-800/50 border border-zinc-700 rounded-xl text-sm">
          <HelpCircle size={18} className="text-zinc-400 shrink-0 mt-0.5" />
          <div className="text-zinc-400">
            <p className="text-white mb-1">No peers yet</p>
            <p>
              On a tailnet, peers appear once other ODS nodes join. Without one,
              declare them in <span className="font-mono">config/mesh-peers.json</span>{' '}
              and restart dashboard-api.
            </p>
          </div>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
          {peers.map((peer) => (
            <PeerCard key={`${peer.hostname}-${peer.address}`} peer={peer} />
          ))}
        </div>
      )}

      {peers.length > 0 && (
        <p className="flex items-center gap-1.5 mt-6 text-xs text-zinc-500">
          <Circle size={8} className="fill-current" />
          Only idle peers receive work. Regenerate{' '}
          <span className="font-mono">config/litellm/mesh.yaml</span> after peers change.
        </p>
      )}
    </div>
  )
}
