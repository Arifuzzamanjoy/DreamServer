import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import torch
from transformers import pipeline

# Configure logging
import logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("routemoa-scorer")

app = FastAPI(title="RouteMoA Scorer Microservice")

# Data Models
class ScoreRequest(BaseModel):
    prompt: str
    candidates: list[str]

class ScoreResponse(BaseModel):
    scores: dict[str, float]

# Global variables for model
classifier = None

@app.on_event("startup")
async def load_model():
    global classifier
    logger.info("Loading Zero-Shot Classification Pipeline...")
    model_name = os.environ.get("ROUTEMOA_MODEL_NAME", "MoritzLaurer/DeBERTa-v3-base-mnli-fever-docnli-ling-2c")
    hf_token = os.environ.get("HF_TOKEN")
    
    device = 0 if torch.cuda.is_available() else -1
    
    try:
        classifier = pipeline(
            "zero-shot-classification",
            model=model_name,
            device=device,
            token=hf_token
        )
        logger.info(f"Successfully loaded {model_name} on device {device}")
    except Exception as e:
        logger.error(f"Failed to load model: {e}")
        raise RuntimeError("Could not initialize model pipeline")

@app.post("/score", response_model=ScoreResponse)
async def score(req: ScoreRequest):
    if not classifier:
        raise HTTPException(status_code=503, detail="Model is not loaded yet.")
    
    if not req.candidates:
        return {"scores": {}}

    try:
        # Evaluate prompt against all candidates simultaneously
        # multi_label=True means scores for each label are independent and can be high at the same time
        result = classifier(req.prompt, req.candidates, multi_label=True)
        
        # Result format:
        # {'sequence': '...', 'labels': ['algebra', 'geometry'], 'scores': [0.95, 0.05]}
        
        labels = result['labels']
        scores = result['scores']
        
        # Map back to the expected dictionary format
        score_dict = {label: score for label, score in zip(labels, scores)}
        
        return {"scores": score_dict}
        
    except Exception as e:
        logger.error(f"Inference error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health():
    return {"status": "ok", "model_loaded": classifier is not None}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
