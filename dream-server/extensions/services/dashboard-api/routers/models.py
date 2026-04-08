"""Model Library router — browse, filter, and manage GGUF models."""

import json
import logging
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends

from config import DATA_DIR, INSTALL_DIR
from models import ModelLibraryEntry, ModelLibraryGpu, ModelLibraryResponse
from security import verify_api_key

logger = logging.getLogger(__name__)

router = APIRouter(tags=["models"])

_LIBRARY_PATH = Path(INSTALL_DIR) / "config" / "model-library.json"
_MODELS_DIR = Path(DATA_DIR) / "models"
_ENV_PATH = Path(INSTALL_DIR) / ".env"


def _load_library() -> list[dict]:
    """Load the model library catalog from config/model-library.json."""
    if not _LIBRARY_PATH.exists():
        logger.warning("Model library not found: %s", _LIBRARY_PATH)
        return []
    try:
        data = json.loads(_LIBRARY_PATH.read_text(encoding="utf-8"))
        return data.get("models", [])
    except (json.JSONDecodeError, OSError) as exc:
        logger.warning("Failed to load model library: %s", exc)
        return []


def _scan_downloaded_models() -> dict[str, int]:
    """Scan data/models/ for downloaded GGUF files. Returns {filename: size_bytes}."""
    downloaded: dict[str, int] = {}
    if not _MODELS_DIR.is_dir():
        return downloaded
    try:
        for f in _MODELS_DIR.iterdir():
            if f.is_file() and f.suffix == ".gguf" and not f.name.endswith(".part"):
                try:
                    downloaded[f.name] = f.stat().st_size
                except OSError:
                    pass
    except OSError as exc:
        logger.warning("Failed to scan models directory: %s", exc)
    return downloaded


def _read_active_model() -> Optional[str]:
    """Read the currently active GGUF_FILE from .env."""
    if not _ENV_PATH.exists():
        return None
    try:
        for line in _ENV_PATH.read_text(encoding="utf-8").splitlines():
            if line.startswith("GGUF_FILE="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return None


def _get_gpu_vram() -> Optional[ModelLibraryGpu]:
    """Get GPU VRAM info for model compatibility gating."""
    try:
        from gpu import get_gpu_info
        gpu = get_gpu_info()
        if gpu is None:
            return None
        total_gb = gpu.memory_total_mb / 1024
        used_gb = gpu.memory_used_mb / 1024
        return ModelLibraryGpu(
            vramTotal=round(total_gb, 1),
            vramUsed=round(used_gb, 1),
            vramFree=round(total_gb - used_gb, 1),
        )
    except Exception:
        return None


def _format_size(size_mb: int) -> str:
    """Format size in MB to a human-readable string."""
    if size_mb >= 1024:
        return f"{size_mb / 1024:.1f} GB"
    return f"{size_mb} MB"


@router.get("/api/models", response_model=ModelLibraryResponse)
def list_models(api_key: str = Depends(verify_api_key)):
    """List available models with VRAM compatibility and download status."""
    library = _load_library()
    downloaded = _scan_downloaded_models()
    active_gguf = _read_active_model()
    gpu = _get_gpu_vram()

    vram_total_gb = gpu.vramTotal if gpu else 0
    vram_free_gb = gpu.vramFree if gpu else 0

    entries: list[ModelLibraryEntry] = []
    current_model: Optional[str] = None

    for model in library:
        gguf_file = model.get("gguf_file", "")
        model_id = model.get("id", "")

        # Determine status
        if gguf_file and gguf_file == active_gguf:
            status = "loaded"
            current_model = model_id
        elif gguf_file and gguf_file in downloaded:
            status = "downloaded"
        else:
            status = "available"

        vram_req = model.get("vram_required_gb", 0)

        entries.append(ModelLibraryEntry(
            id=model_id,
            name=model.get("name", model_id),
            size=_format_size(model.get("size_mb", 0)),
            sizeGb=round(model.get("size_mb", 0) / 1024, 1),
            vramRequired=vram_req,
            contextLength=model.get("context_length", 0),
            specialty=model.get("specialty", "General"),
            description=model.get("description", ""),
            tokensPerSec=model.get("tokens_per_sec_estimate", 0),
            quantization=model.get("quantization"),
            status=status,
            fitsVram=vram_req <= vram_total_gb if vram_total_gb > 0 else True,
            fitsCurrentVram=vram_req <= vram_free_gb if vram_free_gb > 0 else False,
        ))

    return ModelLibraryResponse(
        models=entries,
        gpu=gpu,
        currentModel=current_model,
    )


@router.get("/api/models/download-status")
def model_download_status(api_key: str = Depends(verify_api_key)):
    """Get current model download progress (if any)."""
    status_path = Path(DATA_DIR) / "model-download-status.json"
    if not status_path.exists():
        return {"status": "idle"}
    try:
        return json.loads(status_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {"status": "idle"}
