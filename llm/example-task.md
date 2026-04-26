Fine-tune DistilBERT on SST-2 (binary sentiment classification) using LoRA.

## Goal

Produce a working training script that:
1. Loads `distilbert-base-uncased` from HuggingFace Hub.
2. Wraps it with a LoRA adapter (rank 8, targeting the query/value projection
   layers) using `peft`.
3. Trains on the `glue/sst2` train split for 3 epochs with AdamW, linear
   warmup, and mixed precision (fp16).
4. Evaluates on the `glue/sst2` validation split after each epoch using
   accuracy from `evaluate`.
5. Saves the final LoRA adapter weights to `./output/sst2-lora/`.

## Constraints

- Use only the libraries pre-installed in the llm sandbox: `transformers`,
  `datasets`, `peft`, `accelerate`, `evaluate`, `torch`.
- No internet access is assumed at training time — load the dataset and model
  once, cache in `~/.cache/huggingface`, then run entirely from cache.
- Target batch size 32 (gradient-accumulate if GPU memory requires it).
- Script must be runnable with `python train.py` from the project root with no
  arguments.
- Final validation accuracy must reach ≥ 90% (DistilBERT + LoRA on SST-2
  should comfortably hit ~92%).

## Acceptance criteria

- `python train.py` runs to completion without error.
- Prints per-epoch validation accuracy to stdout.
- `output/sst2-lora/adapter_config.json` and `adapter_model.safetensors` exist
  after training.
- A `README.md` documents how to load and use the saved adapter for inference.
