import { useState, useEffect, useRef, useCallback } from 'react'

// Auth: nginx injects Authorization header for all /api/ requests (see nginx.conf).

// Peers are probed live on every call, so poll slower than the GPU panel.
const POLL_INTERVAL = 15000

export function useMeshPeers() {
  const [mesh, setMesh] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const fetchInFlight = useRef(false)

  const fetchPeers = useCallback(async () => {
    if (document.hidden) return
    if (fetchInFlight.current) return
    fetchInFlight.current = true
    try {
      const res = await fetch('/api/mesh/peers')
      if (res.ok) {
        setMesh(await res.json())
        setError(null)
      } else {
        // A failing discovery call is itself the diagnosis worth showing:
        // 503 means the peer file is missing or the host agent is unreachable.
        const body = await res.json().catch(() => ({}))
        setError(body.detail || `discovery failed (HTTP ${res.status})`)
      }
    } catch (err) {
      setError(err.message)
    } finally {
      fetchInFlight.current = false
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    fetchPeers()
    const interval = setInterval(fetchPeers, POLL_INTERVAL)
    const onVisibility = () => { if (!document.hidden) fetchPeers() }
    document.addEventListener('visibilitychange', onVisibility)
    return () => {
      clearInterval(interval)
      document.removeEventListener('visibilitychange', onVisibility)
    }
  }, [fetchPeers])

  return { mesh, loading, error, refresh: fetchPeers }
}
