import React, { useState, useMemo } from 'react';
import ServicePanel from './ServicePanel';

export default function SessionSidebar({ sessionId, sessions, onNewSession, onClear, onSwitchSession, onForkSession }) {
  const [search, setSearch] = useState('');

  const filteredSessions = useMemo(() => {
    if (!search.trim()) return sessions;
    const q = search.toLowerCase();
    return sessions.filter(
      (s) => s.title?.toLowerCase().includes(q) || s.id.toLowerCase().includes(q)
    );
  }, [sessions, search]);

  const formatTime = (ts) => {
    if (!ts) return '';
    const d = new Date(ts);
    const now = new Date();
    const diff = now - d;
    if (diff < 60000) return 'just now';
    if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
    if (diff < 86400000) return `${Math.floor(diff / 3600000)}h ago`;
    return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  };

  return (
    <div className="w-56 border-r flex flex-col"
      style={{
        background: 'radial-gradient(circle at top left, rgba(157,0,255,0.15), transparent 28%), linear-gradient(180deg, #1a1722 0%, #17131f 58%, #110f17 100%)',
        borderColor: 'rgba(157,0,255,0.16)',
      }}
    >
      <div className="p-3 border-b" style={{ borderColor: 'rgba(157,0,255,0.12)' }}>
        <button
          onClick={onNewSession}
          className="liquid-metal-button w-full px-3 py-2 rounded-lg text-white text-sm font-medium transition-colors"
        >
          + New Session
        </button>
      </div>

      {/* Session search */}
      <div className="px-3 pt-3 pb-1">
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search sessions..."
          className="w-full px-2.5 py-1.5 rounded-lg bg-gray-800 border border-gray-700 text-xs text-gray-300
                     placeholder-gray-500 focus:outline-none focus:border-dream-500 focus:ring-1 focus:ring-dream-500"
        />
      </div>

      <div className="flex-1 overflow-y-auto p-3 space-y-1 liquid-metal-sequence-grid liquid-metal-sequence-grid--sessions">
        {/* Current session */}
        {sessionId && (
          <div className="rounded-lg bg-dream-900/40 border border-dream-700/50 p-2.5 mb-2">
            <p className="text-xs text-dream-400 font-medium mb-0.5">Current</p>
            <p className="text-xs font-mono text-gray-300 truncate">{sessionId.slice(0, 12)}...</p>
          </div>
        )}
        {/* Session history */}
        {filteredSessions.length > 0 && (
          <p className="text-xs text-gray-600 uppercase tracking-wider px-1 pt-2 pb-1">History</p>
        )}
        {filteredSessions.map((session) => (
          <div
            key={session.id}
            className="liquid-metal-frame liquid-metal-frame--soft w-full rounded-lg p-2.5 transition-colors group relative"
          >
            <button
              onClick={() => onSwitchSession(session.id)}
              className="w-full text-left"
            >
              <div className="flex items-center gap-1">
                {session.forkedFrom && (
                  <span className="text-dream-400 text-xs" title={`Forked from ${session.forkedFrom.slice(0, 8)}`}>
                    <svg className="w-3 h-3 inline-block" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                      <path d="M6 3v6m0 0a3 3 0 1 0 6 0 3 3 0 0 0-6 0zm12-6v6m0 0a3 3 0 1 0-6 0 3 3 0 0 0 6 0zM6 15v3a3 3 0 0 0 3 3h6a3 3 0 0 0 3-3v-3" />
                    </svg>
                  </span>
                )}
                <p className="text-xs text-gray-300 truncate group-hover:text-white flex-1">
                  {session.title}
                </p>
              </div>
              <div className="flex items-center justify-between mt-0.5">
                <p className="text-xs text-gray-600 font-mono">
                  {session.id.slice(0, 8)}...
                </p>
                <div className="flex items-center gap-2 text-xs text-gray-600">
                  {session.messageCount != null && (
                    <span>{session.messageCount} msgs</span>
                  )}
                  {session.timestamp && (
                    <span>{formatTime(session.timestamp)}</span>
                  )}
                </div>
              </div>
            </button>
            {/* Fork button */}
            {onForkSession && (
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  onForkSession(session.id);
                }}
                title="Fork this session"
                className="absolute top-2 right-2 opacity-0 group-hover:opacity-100 transition-opacity
                           p-1 rounded bg-gray-700 hover:bg-gray-600 text-gray-400 hover:text-dream-400"
              >
                <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <circle cx="12" cy="18" r="3" />
                  <circle cx="6" cy="6" r="3" />
                  <circle cx="18" cy="6" r="3" />
                  <path d="M18 9v1a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V9" />
                  <path d="M12 12v3" />
                </svg>
              </button>
            )}
          </div>
        ))}
      </div>
      {/* DreamServer service health */}
      <ServicePanel />
      <div className="p-3 border-t border-gray-800">
        <button
          onClick={onClear}
          className="w-full px-3 py-1.5 rounded-lg bg-gray-800 hover:bg-gray-700 text-gray-400 text-xs transition-colors"
        >
          Clear Chat
        </button>
      </div>
    </div>
  );
}
