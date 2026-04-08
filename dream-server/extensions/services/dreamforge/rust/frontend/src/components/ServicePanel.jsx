import React, { useState, useEffect } from 'react';

const DASHBOARD_API = 'http://localhost:3002';

const STATUS_COLORS = {
  healthy: 'bg-green-500',
  running: 'bg-green-500',
  up: 'bg-green-500',
  down: 'bg-red-500',
  error: 'bg-red-500',
  stopped: 'bg-red-500',
  not_deployed: 'bg-gray-500',
  unknown: 'bg-gray-500',
};

function statusDot(status) {
  const color = STATUS_COLORS[status] || STATUS_COLORS.unknown;
  return <span className={`inline-block w-2 h-2 rounded-full ${color}`} />;
}

export default function ServicePanel() {
  const [services, setServices] = useState([]);
  const [expanded, setExpanded] = useState(false);
  const [gpu, setGpu] = useState(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    const fetchHealth = async () => {
      try {
        const resp = await fetch(`${DASHBOARD_API}/api/services`);
        if (resp.ok) {
          setServices(await resp.json());
          setError(false);
        } else {
          setError(true);
        }
      } catch {
        setError(true);
      }
      try {
        const resp = await fetch(`${DASHBOARD_API}/api/gpu`);
        if (resp.ok) setGpu(await resp.json());
      } catch {
        // GPU endpoint may not exist — that's fine
      }
    };
    fetchHealth();
    const interval = setInterval(fetchHealth, 30000);
    return () => clearInterval(interval);
  }, []);

  const healthyCount = services.filter(
    (s) => s.status === 'healthy' || s.status === 'running' || s.status === 'up'
  ).length;

  return (
    <div className="mx-2 mb-2">
      <button
        onClick={() => setExpanded(!expanded)}
        className="liquid-metal-frame--soft w-full flex items-center justify-between px-2 py-1.5 rounded-lg text-xs transition-colors"
      >
        <span className="text-gray-400 font-medium flex items-center gap-1.5">
          <span className="text-[10px]">{expanded ? '\u25BC' : '\u25B6'}</span>
          Services
        </span>
        {!error && services.length > 0 && (
          <span className="text-gray-500 font-mono">
            {healthyCount}/{services.length}
          </span>
        )}
        {error && <span className="text-gray-600 font-mono">offline</span>}
      </button>

      {expanded && (
        <div className="mt-1 rounded-lg bg-gray-800/40 border border-gray-700/50 p-2 space-y-1.5">
          {error && services.length === 0 && (
            <p className="text-[10px] text-gray-500 italic">
              Cannot reach dashboard-api at {DASHBOARD_API}
            </p>
          )}

          {services.map((svc) => (
            <div key={svc.name || svc.id} className="flex items-center gap-2">
              {statusDot(svc.status)}
              <span className="text-[11px] text-gray-300 truncate flex-1">
                {svc.name || svc.id}
              </span>
              <span className="text-[10px] text-gray-500 font-mono">
                {svc.status}
              </span>
            </div>
          ))}

          {gpu && (
            <div className="pt-1 border-t border-gray-700/50">
              <div className="flex items-center justify-between mb-0.5">
                <span className="text-[10px] text-gray-400">GPU</span>
                <span className="text-[10px] text-gray-500 font-mono">
                  {gpu.utilization != null ? `${gpu.utilization}%` : 'N/A'}
                </span>
              </div>
              {gpu.utilization != null && (
                <div className="w-full h-1.5 bg-gray-700 rounded-full overflow-hidden">
                  <div
                    className="h-full rounded-full transition-all duration-500"
                    style={{
                      width: `${gpu.utilization}%`,
                      backgroundColor:
                        gpu.utilization > 90
                          ? '#ef4444'
                          : gpu.utilization > 60
                          ? '#f59e0b'
                          : '#22c55e',
                    }}
                  />
                </div>
              )}
              {gpu.vram_used != null && gpu.vram_total != null && (
                <p className="text-[10px] text-gray-500 mt-0.5">
                  VRAM: {gpu.vram_used}MB / {gpu.vram_total}MB
                </p>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
