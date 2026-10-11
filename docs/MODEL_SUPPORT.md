# On-device model support

Why each entry in the catalogue is, or is not, offered — with the evidence.

## The short version

| Model | Kind | Status | Why |
|---|---|---|---|
| Qwen2.5 0.5B Instruct | chat | ✅ works | plain text GGUF |
| SmolLM2 360M Instruct | chat | ✅ works | plain text GGUF |
| Qwen2.5 1.5B Instruct | chat | ✅ works | plain text GGUF |
| **Qwen3.5 0.8B** | **vision** | ✅ **works** | `qwen35` arch + `qwen3vl_merger` projector both present |
| Moondream2 | vision | ❌ **impossible** | no `moondream` projector type in llama.cpp |
| all-MiniLM-L6-v2 | embeddings | ✅ works | ONNX, CPU |

## Moondream2 cannot work in this build — proven

The failure on a real phone was:

```
Qwen2.5 0.5B Instruct loaded, but vision failed to attach.
```

That message comes from `LlmService.loadVision` returning `false`, which it does
only when the plugin's native `initVision` throws or returns false.

**Root cause.** `llama.cpp`'s multimodal stack identifies a projector by a member
of the `projector_type` enum in `tools/mtmd/clip-impl.h`. The vendored tree
(`native_llama` 1.0.1 → `ios/shared_cpp/tools/mtmd/`) contains **42 projector
types and not one of them is Moondream2**:

```
MLP, MLP_NORM, LDP, LDPV2, MINICPMV, GLM_EDGE, QWEN2VL, QWEN3VL, STEP3VL,
GEMMA3, GEMMA3NV, GEMMA3NA, GEMMA4V, GEMMA4A, PHI4, IDEFICS3, PIXTRAL,
QWEN25VL, ULTRAVOX, INTERNVL, LLAMA4, QWEN2A, QWEN3A, GLMA, QWEN25O,
VOXTRAL, MERALION, MUSIC_FLAMINGO, LFM2, KIMIVL, PADDLEOCR, LIGHTONOCR,
COGVLM, JANUS_PRO, DOTS_OCR, DEEPSEEKOCR, LFM2A, GLM4V, YOUTUVL, KIMIK25,
NEMOTRON_V2_VL, HUNYUANOCR, UNKNOWN
```

A grep for `MOONDREAM` across the entire `tools/mtmd/` tree returns **zero
matches**. The projector loads as `PROJECTOR_TYPE_UNKNOWN` and the load fails.

So the previous catalogue comment — *"Moondream2 is the only small GGUF whose
projector llama.cpp can actually serve on-device"* — was exactly backwards. It
was the one vision option, and it was the one that could never load.

**Moondream2 is therefore kept in the catalogue but disabled**, with
`unsupportedReason` set and the row greyed out. Keeping it visible (rather than
deleting it) means a user who already downloaded 1.97 GB gets an explanation
instead of a mystery. The files on disk are never deleted.

## Qwen3.5 0.8B is the fix — verified

`Qwen/Qwen3.5-0.8B` is a **native vision** model: 0.9B parameters, Apache 2.0,
262K context, `image-text-to-text`. Released 2026-03-02. One GGUF carries both
the language model and its ViT, with a separate `mmproj` supplying the merger.

### Runtime support confirmed in the vendored tree

| Check | Evidence |
|---|---|
| Architecture registered | `llama-arch.cpp`: `{ LLM_ARCH_QWEN35, "qwen35" }` |
| Graph builder | `src/models/qwen35.cpp`, `llama-model.cpp:9078` |
| MoE variant | `src/models/qwen35moe.cpp` |
| Pre-tokenizer | `llama-vocab.cpp:2029` — `tokenizer_pre == "qwen35"` |
| Vision projector | `clip.cpp` — `PROJECTOR_TYPE_QWEN3VL` |
| Encoder graph | `tools/mtmd/models/qwen3vl.cpp` |

Qwen3.5 reuses Qwen3-VL's ViT, which this build ships.

### Pinned files

Commit `6ab461498e2023f6e3c1baea90a8f0fe38ab64d0`
(`unsloth/Qwen3.5-0.8B-GGUF`), values read from the Hugging Face tree API at
that exact commit — the LFS `oid` **is** the SHA-256:

| File | Bytes | SHA-256 |
|---|---|---|
| `Qwen3.5-0.8B-Q4_K_M.gguf` | 532,517,120 | `bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517` |
| `mmproj-F16.gguf` | 204,987,232 | `56e4c6cfe73b0c82e3e82bc518d7591997e61d81f723fc41a586f4fa69ea2453` |

**Total 737,504,352 B (703 MB)** — against Moondream2's 1,969,388,000 B. The
working vision model is **under half the size** of the broken one.

Both URLs were re-checked with an HTTP `HEAD`; `Content-Length` matches the pins
exactly.

## Rules this established

1. **Never ship a model whose runtime support has not been checked.** Grepping
   the vendored `projector_type` enum takes seconds and would have caught this.
2. **`isUsable` must be driven by the model, not hardcoded `true`.** It now
   reads `unsupportedReason`, so the UI cannot offer something the runtime will
   reject.
3. **A model in `ModelCatalog` needs a matching `modelIntegrityManifest` entry**
   or `download()` refuses it outright (it fails closed on an unpinned model).
4. **Pins come from the API, never from memory.** Every size and hash above was
   read programmatically at a specific commit.
