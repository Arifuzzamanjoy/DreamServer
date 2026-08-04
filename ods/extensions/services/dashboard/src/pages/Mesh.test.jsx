import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import { render } from '../test/test-utils'
import Mesh from './Mesh' // eslint-disable-line no-unused-vars

/**
 * The Mesh page exists to answer one operational question: which peer is
 * broken, and why. So the assertions here are mostly that each failure state
 * stays visually distinct and carries its own remedy — collapsing them into a
 * generic "offline" is the regression worth catching.
 */

const jsonResponse = (data, { ok = true, status = 200 } = {}) => ({
  ok,
  status,
  json: async () => data,
})

const peer = (overrides = {}) => ({
  hostname: 'vast-a',
  dns_name: null,
  address: 'http://203.0.113.10:41287',
  online: true,
  state: 'online-idle',
  idle: true,
  utilization_percent: 4,
  threshold_percent: 10,
  loaded_model: 'Qwen3.5-9B-Q4_K_M.gguf',
  skills: ['reasoning', 'logic'],
  detail: null,
  ...overrides,
})

const meshPayload = (peers, overrides = {}) => ({
  peers,
  peer_count: peers.length,
  idle_count: peers.filter((p) => p.state === 'online-idle').length,
  tailscale_running: true,
  tailscale_authenticated: true,
  peer_source: 'static',
  ...overrides,
})

describe('Mesh page', () => {
  beforeEach(() => {
    vi.stubGlobal('fetch', vi.fn())
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('renders an idle peer with its model and skills', async () => {
    globalThis.fetch.mockResolvedValue(jsonResponse(meshPayload([peer()])))
    render(<Mesh />)

    await waitFor(() => expect(screen.getByText('vast-a')).toBeInTheDocument())
    expect(screen.getByText('Idle')).toBeInTheDocument()
    expect(screen.getByText('Qwen3.5-9B-Q4_K_M.gguf')).toBeInTheDocument()
    expect(screen.getByText('reasoning')).toBeInTheDocument()
    expect(screen.getByText('logic')).toBeInTheDocument()
  })

  it('keeps failure states distinct rather than merging them', async () => {
    globalThis.fetch.mockResolvedValue(jsonResponse(meshPayload([
      peer({ hostname: 'a', state: 'unreachable', detail: 'connection refused' }),
      peer({ hostname: 'b', state: 'timed-out' }),
      peer({ hostname: 'c', state: 'unauthorized' }),
      peer({ hostname: 'd', state: 'online-busy', utilization_percent: 95, idle: false }),
    ])))
    render(<Mesh />)

    await waitFor(() => expect(screen.getByText('Unreachable')).toBeInTheDocument())
    expect(screen.getByText('Timed out')).toBeInTheDocument()
    expect(screen.getByText('Unauthorized')).toBeInTheDocument()
    expect(screen.getByText('Busy')).toBeInTheDocument()
  })

  it('explains what to fix for each failure', async () => {
    globalThis.fetch.mockResolvedValue(jsonResponse(meshPayload([
      peer({ hostname: 'a', state: 'unauthorized' }),
    ])))
    render(<Mesh />)

    await waitFor(() => expect(screen.getByText('Unauthorized')).toBeInTheDocument())
    expect(screen.getByText(/MESH_PEER_API_KEY differs/i)).toBeInTheDocument()
  })

  it('shows the peer detail for an unreachable peer', async () => {
    globalThis.fetch.mockResolvedValue(jsonResponse(meshPayload([
      peer({ hostname: 'a', state: 'unreachable', detail: 'connection refused' }),
    ])))
    render(<Mesh />)

    await waitFor(() => expect(screen.getByText('connection refused')).toBeInTheDocument())
  })

  it('counts idle peers separately from reachable ones', async () => {
    globalThis.fetch.mockResolvedValue(jsonResponse(meshPayload([
      peer({ hostname: 'a', state: 'online-idle' }),
      peer({ hostname: 'b', state: 'online-busy', idle: false }),
      peer({ hostname: 'c', state: 'unreachable' }),
    ])))
    render(<Mesh />)

    await waitFor(() => expect(screen.getByText('Idle now')).toBeInTheDocument())
    expect(screen.getByText('2/3')).toBeInTheDocument()
  })

  it('surfaces a discovery failure instead of showing an empty mesh', async () => {
    // 503 with no peer file looks identical to "no peers" unless it is shown.
    globalThis.fetch.mockResolvedValue(jsonResponse(
      { detail: 'MESH_PEER_SOURCE=static but /ods/config/mesh-peers.json does not exist.' },
      { ok: false, status: 503 },
    ))
    render(<Mesh />)

    await waitFor(() => expect(screen.getByText('Peer discovery failed')).toBeInTheDocument())
    expect(screen.getByText(/mesh-peers.json does not exist/)).toBeInTheDocument()
  })

  it('guides the operator when there are no peers yet', async () => {
    globalThis.fetch.mockResolvedValue(jsonResponse(meshPayload([])))
    render(<Mesh />)

    await waitFor(() => expect(screen.getByText('No peers yet')).toBeInTheDocument())
    expect(screen.getByText(/config\/mesh-peers.json/)).toBeInTheDocument()
  })

  it('names the discovery source so static vs tailnet is obvious', async () => {
    globalThis.fetch.mockResolvedValue(jsonResponse(meshPayload([peer()])))
    render(<Mesh />)

    await waitFor(() => expect(screen.getByText('static')).toBeInTheDocument())
  })
})
