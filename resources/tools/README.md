# Tools

Utilities and scripts built by the Light Heart Labs collective for operating, testing, and monitoring DreamServer infrastructure.

## Quick Reference

| Tool | Description | Category |
|------|-------------|----------|
| `ai-health-monitor.sh` | Monitors AI service health with JSON output and webhook alerts (Discord/Slack) | Monitoring |
| `gpu_temp_monitor.py` | Tracks GPU temperature and VRAM usage on cluster nodes with Discord alerts | Monitoring |
| `bench-test-concurrent.py` | Load tests local LLM performance under concurrent user load with latency metrics | Testing |
| `livekit-concurrent-test.py` | Stress tests WebRTC voice sessions measuring connection and audio latency | Testing |
| `livekit-analyze-results.py` | Parses and visualizes LiveKit test results with scalability analysis | Testing |
| `m4-classifier-benchmark.py` | Benchmarks DistilBERT vs Qwen latency and accuracy for intent classification | Testing |
| `m4-export-distilbert-onnx.py` | Exports trained DistilBERT to ONNX format with INT8 quantization for CPU inference | Dev |
| `m8-conversation-stress-test.py` | Tests context handling stability over 20+ turn conversations | Testing |
| `m8-load-test.sh` | Concurrent load test for vLLM with configurable request counts and timing | Testing |
| `m8-tool-calling-test.py` | Measures OpenAI-format tool call success rate on local models (target >90%) | Testing |
| `m8-voice-latency-test.py` | Tests full voice pipeline latency under concurrent STT->LLM->TTS round trips | Testing |
| `llm-cold-storage.sh` | Archives idle HuggingFace models to cold storage with symlink management | Operations |
| `local_spawner.py` | Spawns reliable sub-agents on local Qwen models using atomic chain pattern | Dev |
| `m2-voice-pipeline-wired.py` | Implements complete STT->LLM->TTS voice pipeline with cluster endpoints | Dev |
| `session-cleanup.sh` | Manages session file lifecycle to prevent context overflow crashes | Operations |
| `start-proxy.sh` | Starts vLLM tool call proxy server with configurable port and backend | Operations |
| `start-vllm.sh` | Launches vLLM with local models via Docker with Qwen3 tool parser config | Operations |
| `vllm-tool-proxy.py` | Proxy wrapper fixing tool calling JSON parsing with safety nets | Dev |
| `SUBAGENT-TASK-TEMPLATE.md` | Template and learnings for reliable sub-agent task spawning on local models | Reference |

## Usage

Most scripts are designed for the Light Heart Labs cluster (nodes at 192.168.0.122 and 192.168.0.143). Adapt IP addresses and ports to your environment.

### Monitoring

```bash
# Check health of all AI services
./ai-health-monitor.sh --json

# Monitor GPU temps with Discord alerts
python gpu_temp_monitor.py
```

### Testing

```bash
# Load test local LLM
python bench-test-concurrent.py --users 10 --duration 60

# Test tool calling reliability
python m8-tool-calling-test.py
```

### Operations

```bash
# Archive unused models to save disk space
./llm-cold-storage.sh --execute

# Clean up bloated sessions
./session-cleanup.sh
```
