# Google AI Edge Gallery — Recon Map

## Scope
- **App:** Google AI Edge Gallery
- **Platform:** Android (primary), iOS, macOS
- **Slice:** Core AI features — Chat, Ask Image, Prompt Lab, Model Management
- **Target user:** AI enthusiasts, developers, mobile AI power users

## Sources

| Source | What it gives |
| --- | --- |
| https://github.com/google-ai-edge/gallery | Full source code, feature list, architecture |
| https://play.google.com/store/apps/details?id=com.google.ai.edge.gallery | Store listing, screenshots, feature pitch |
| https://developers.google.com/edge/gallery | Official docs, feature descriptions |
| https://github.com/google-ai-edge/gallery/releases | APKs, release notes |

## Screen Inventory

| ID | Screen | Route | Purpose | Key Components | States |
| --- | --- | --- | --- | --- | --- |
| S01 | Home/Model Gallery | Launch | Browse available models | Model cards, download buttons, category filters | Empty, loading, error |
| S02 | AI Chat | Nav → Chat tab | Multi-turn conversation | Chat bubbles, input, model selector, thinking toggle | Empty, thinking, error, offline |
| S03 | Ask Image | Nav → Image tab | Upload image + query | Image picker, preview, camera button, text input | No image, processing, result |
| S04 | Prompt Lab | Nav → Prompt tab | Single-turn prompt testing | Prompt input, output, parameter controls (temp, top-k) | Empty, running, result |
| S05 | Audio Scribe | Nav → Audio tab | Voice transcription | Mic button, waveform, transcript | Not started, recording, transcribing, done |
| S06 | Model Manager | Settings → Models | Download/manage models | Model list, download progress, storage info | Few models, many models, full |
| S07 | Settings | Nav → Settings | App configuration | Theme, model settings, permissions | Basic |
| S08 | About/Legal | Nav → About | Credits, terms | Text blocks | Static |

## User Flows

### F01 User downloads and chats with a model
- S01 gallery → pick model → download (with progress) → S02 chat → send message → view response
- Clicks: ~5 on happy path
- Edge: offline mode, model not enough RAM, failed download

### F02 User asks about an image
- S03 ask image → pick photo → type question → view answer
- Clicks: ~4
- Edge: no camera permission, large image, model doesn't support vision

### F03 User tests a prompt in Prompt Lab
- S04 prompt lab → type prompt → set params → run → view result
- Clicks: ~4
- Edge: model not loaded, parameter constraints

### F04 User transcribes audio
- S05 audio scribe → record → wait for transcription → save/share
- Clicks: ~3
- Edge: no mic permission, offline mode, unsupported format

## Components

- **Model card** — name, size, category, download button, progress bar, status chip
- **Chat bubble** — user/AI message, thinking indicator, copy button
- **Image picker** — camera/gallery selector, preview thumbnail
- **Parameter slider** — temperature, top-k, max tokens
- **Waveform visualizer** — recording indicator, playback
- **Navigation bar** — tabs: Chat, Image, Prompt, Audio, Settings
- **Empty state** — "Download a model to start" CTA

## Inferred Data Model

```
Model
  id, name, size, category (llm/vision/multimodal), 
  download_url, download_status (none/downloading/downloaded/error),
  ram_required, context_size

ChatSession
  id, model_id, title, created_at, messages[]

Message
  role (user/assistant), content, timestamp, thinking_mode (bool)

ImageQuery
  id, image_path, question, answer, model_id, timestamp

PromptResult
  prompt, result, model_id, parameters, timestamp

AudioRecording
  id, audio_path, transcript, model_id, timestamp, duration
```

## Feature Matrix

| Feature | Area | Priority | Original | Clone | Notes |
| --- | --- | --- | --- | --- | --- |
| AI Chat (multi-turn) | Core | must | yes | no | |
| Ask Image (vision) | Core | must | yes | no | |
| Prompt Lab | Core | must | yes | no | |
| Audio Scribe | Core | should | yes | no | |
| Model Management | Core | must | yes | no | |
| Agent Skills | Advanced | could | yes | no | Plugin system |
| Thinking Mode | Advanced | could | yes | no | GPT-4 style reasoning |
| Tiny Garden Game | Fun | could | yes | no | Experimental |
| Mobile Actions | Advanced | could | yes | no | FunctionGemma |
| Online model list | Core | must | yes | no | Hugging Face integration |

## What Cannot Be Cloned

- Google's proprietary model weights (Gemma, FunctionGemma)
- Google branding, logos, assets
- Access to Google's ML infrastructure
- Google AI API keys for cloud features

## Size Estimate

- Screens: ~8
- Flows: 4 core
- Entities: 5
- Hard parts: Model download/resume, real-time inference on device, offline-first architecture
- Size: **M (a few weeks)** for core features; **L (a quarter)** for full parity including Agent Skills and Tiny Garden

## Next Step
`/replica-architect` — plan the stack and database schema for the clone.
