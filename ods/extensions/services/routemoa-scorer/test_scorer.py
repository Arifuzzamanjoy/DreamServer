import os
import time

# Read HF_TOKEN from environment if set
hf_token = os.environ.get("HF_TOKEN")

# We can import the FastAPI app and test the pipeline directly
# Or we can just spin up the pipeline to verify functionality.
print("Testing the model initialization...")
from transformers import pipeline
import torch

def test_inference():
    model_name = "MoritzLaurer/DeBERTa-v3-base-mnli-fever-docnli-ling-2c"
    print(f"Loading {model_name}...")
    start = time.time()
    
    device = 0 if torch.cuda.is_available() else -1
    classifier = pipeline(
        "zero-shot-classification",
        model=model_name,
        device=device,
        token=hf_token
    )
    
    load_time = time.time() - start
    print(f"Model loaded in {load_time:.2f} seconds on device {device}")
    
    print("\n--- Running Inference Test ---")
    prompt = "How much is 15% of 200?"
    candidates = ["algebra", "geometry", "arithmetic", "writing", "code", "logic", "reasoning"]
    
    print(f"Prompt: {prompt}")
    print(f"Candidates: {candidates}")
    
    inf_start = time.time()
    result = classifier(prompt, candidates, multi_label=True)
    inf_time = time.time() - inf_start
    
    print(f"Inference took {inf_time:.2f} seconds")
    print("\nResult:")
    
    for label, score in zip(result['labels'], result['scores']):
        print(f"  {label}: {score:.4f}")

if __name__ == "__main__":
    test_inference()
