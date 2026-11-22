# PSLM

**Portable Small Language Model** is a USB-first, zero-install local AI control environment. It is designed to keep executable code, downloaded inference engines, and GGUF models on removable media while providing a private local inference server and an optional desktop automation workflow.

Zero-install, air-gapped portable AI assistant and UI Automation click-agent running entirely from a USB drive via native PowerShell and HTML.

PSLM uses PowerShell for hardware detection and process orchestration, a plain HTML control surface for user interaction, a local `llama-server` process for inference, and a restricted automation API for preview and approval-driven desktop actions.

![PSLM official mark](https://img.shields.io/badge/PSLM-Official%20Mark-1e7e34?style=for-the-badge)

## Core Principles

- **Zero install:** No required application installation on the host PC. Runtime assets are resolved relative to `$PSScriptRoot`.
- **Air-gapped operation:** Once downloaded, inference and the control interface can operate without cloud AI services.
- **Removable-media portability:** Remove the USB device to leave no runtime engine or model on the host.
- **Hardware adaptation:** Detect NVIDIA hardware and use the CUDA profile when `nvidia-smi` is available; otherwise use the CPU profile.
- **Official source-only distribution:** Runtime binaries and models are not stored in Git. A setup script guides acquisition from approved hosts.
- **Human approval:** Clicking, typing, shortcuts, and other state-changing automation require explicit confirmation.
- **Emergency stop:** Holding the Escape key prevents approved actions and aborts automation request handling.

## Repository Layout

```text
[USB_Drive]/
├── Run.bat
├── Start-AI-Daemon.ps1
├── Download-PSLMAssets.ps1
├── ui.html
├── models.json
├── LICENSE
├── README.md
├── pslm.log
├── movements.jsonl
├── bin_cpu/
├── bin_cuda/
└── models/
```

The source repository intentionally excludes engine binaries, GGUF models, temporary downloads, and runtime logs.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7
- `.NET Framework` classes used by WPF, WinForms, and Windows UI Automation
- Optional NVIDIA GPU plus a CUDA-compatible `llama-server` build
- A GGUF model license that permits the intended use
- Sufficient RAM or VRAM for the selected model

CPU mode requires a CPU-compatible engine and a model such as a 1.5B–4B Q4_K_M GGUF. CUDA mode is intended for larger compatible engines and models such as 8B–12B Q4_K_M GGUF files. Exact compatibility depends on the llama.cpp release, Windows architecture, and GPU driver.

## Quick Start

1. Copy the complete PSLM source directory to a USB drive.
2. Double-click `Run.bat`.
3. The daemon creates `bin_cpu`, `bin_cuda`, and `models` if they do not exist.
4. Place an official CPU or CUDA `llama-server.exe` build in the matching directory.
5. Place a compatible GGUF model in `models` using the configured filename:
   - CPU: `cpu-model.gguf`
   - CUDA: `cuda-model.gguf`
6. Restart `Run.bat`.
7. Open the control page if it does not open automatically.

The inference health endpoint is available at `http://127.0.0.1:8080/health`. The daemon management API is bound only to `http://127.0.0.1:8091`.

## Downloading Official Assets

`Download-PSLMAssets.ps1` accepts HTTPS URLs only and restricts downloads to GitHub, GitHub Release asset hosts, Hugging Face, and Hugging Face CDN hosts. Supply a complete 64-character SHA-256 value whenever one is published by the provider.

Download a CPU engine release:

```powershell
.\Download-PSLMAssets.ps1 `
  -Asset engine-cpu `
  -Url "https://github.com/ggerganov/llama.cpp/releases/download/<tag>/<release>.zip" `
  -Sha256 "<64-character-SHA256>" `
  -Extract
```

Download a CUDA engine release:

```powershell
.\Download-PSLMAssets.ps1 `
  -Asset engine-cuda `
  -Url "https://github.com/ggerganov/llama.cpp/releases/download/<tag>/<release>.zip" `
  -Sha256 "<64-character-SHA256>" `
  -Extract
```

Download a CPU or CUDA model:

```powershell
.\Download-PSLMAssets.ps1 `
  -Asset model-cpu `
  -Url "https://huggingface.co/<owner>/<repo>/resolve/main/<file>.gguf" `
  -Sha256 "<64-character-SHA256>"
```

The downloader deletes a downloaded file after a hash mismatch and does not silently accept it. If no published hash is available, independently verify the provider's checksum through a trusted channel before use.

## Hardware Profiles

At startup, PSLM checks `nvidia-smi.exe`. A successful result selects the CUDA profile. Otherwise, PSLM selects the CPU profile and starts `llama-server` with GPU offload disabled.

The selected profile changes:

- the engine directory inspected by the daemon;
- the filename and model location requested at startup;
- the GPU layer count passed to llama.cpp;
- the status information displayed in `ui.html`.

Changing hardware after startup may require restarting the daemon.

## NPU and Hybrid Acceleration

PSLM detects Windows-recognized Neural Processing Units by inspecting `Win32_PnPEntity` names for terms such as NPU, Neural Processing, AI Boost, Versal, or Intel AI. Detection is advisory: it does not assume that a particular vendor runtime or llama.cpp build can execute a model on the NPU.

The default hardware policy is represented in `models.json`:

- `preferredMode: hybrid`
- `npuEnabled: true`
- `embeddingDevice: npu`
- `generationDevice: cuda`
- `cpuFallback: true`

In the current zero-dependency implementation:

- GPU generation remains owned by the installed llama.cpp CUDA or CPU engine.
- RAG indexing and search use the local CPU process.
- An NPU is reported and reserved as an embedding target for future Windows ML or DirectML integration.
- CUDA takes priority for generation when an NVIDIA GPU is available.
- NPU hybrid mode is selected when no NVIDIA GPU is found but an NPU is recognized.
- CPU-only mode remains the guaranteed fallback.

The hybrid policy is intentionally conservative. It does not claim NPU acceleration until an NPU-specific embedding runtime and kernel are installed and verified. This avoids presenting detection as end-to-end acceleration.

## Local RAG Knowledge Base

Place private knowledge files in the `knowledge/` directory. PSLM recursively supports `.txt`, `.md`, `.csv`, `.json`, and `.log` files.

At startup and through `POST /rag/index`, PSLM:

1. reads supported text files from removable media;
2. splits each file into overlapping chunks;
3. records source filename and chunk number;
4. writes a local JSON index to `rag/index.json`;
5. ranks relevant chunks using a dependency-free BM25-style text ranker.

The daemon augments chat completion requests with the highest-ranked chunks and instructs the model to cite source file and chunk values. No embedding service or vector database is required. The ranker is portable, deterministic, and fully local.

For a larger knowledge base or stronger semantic retrieval, replace `Search-RagIndex` with a local ONNX, DirectML, Windows ML, or llama.cpp embedding backend. The HTTP and citation interfaces can remain unchanged.

## Local API

The local management API exposes a small loopback-only interface:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/status` | Report hardware profile, resource state, and movement recorder state |
| `POST` | `/completion` | Forward an OpenAI-compatible chat request to local llama.cpp |
| `POST` | `/search` | Perform a zero-dependency local DuckDuckGo HTML search request |
| `POST` | `/action` | Preview or execute an allowlisted automation action |
| `POST` | `/recording` | Start or stop full cursor movement recording |
| `POST` | `/rag/index` | Build the local knowledge index from `knowledge/` |
| `POST` | `/rag/search` | Search indexed knowledge with a dependency-free BM25-style ranker |

The API has no authentication because it is bound to loopback, but users should still treat the host as sensitive: local browser extensions or same-user malware can attempt local HTTP access. Do not expose port 8091 to other network interfaces or a firewall.

## Desktop Automation Safety

Automation preview scans controls in the current foreground window through Windows UI Automation. It returns control names, types, and bounding rectangles.

The supported action types are:

- `preview`: list visible supported controls; no state change;
- `click`: move to coordinates and perform a left click;
- `type`: move to coordinates, click once, and send text;
- `shortcut`: send a command from a strict shortcut allowlist.

Before a write action, PSLM opens a red topmost preview and a native approval dialog. Only **Approve** executes the action; Reject and Abort do not. The red preview is coordinate-based and should be visually verified by the operator.

The allowlist does not include arbitrary shell commands, application launches, or unrestricted key sequences. Sending text is still potentially sensitive because it can trigger application behavior, submit forms, or modify files. Never approve an action outside your intent.

## Escape Emergency Stop

Holding or pressing Escape is checked through `GetAsyncKeyState` before approval and immediately before execution. Escape may be used to abort the whole daemon interaction, including background movement recording.

The Escape stop is a convenience control, not a substitute for platform isolation, antivirus protection, or operator supervision.

## Full Movement Recording

The **Record Full Movements** control in `ui.html` enables opt-in cursor telemetry. While active, PSLM samples the current cursor position every 25 milliseconds and writes only changed positions as JSON Lines to:

```text
movements.jsonl
```

Each record contains a timestamp, X coordinate, Y coordinate, ESC state, and event type. Recording creates these event types:

- `recording_started`;
- `cursor_moved`;
- `recording_stopped`.

Recording is disabled at startup, can be stopped from the UI, and is stopped automatically when the daemon exits. Movement logs may reveal private on-screen activity and should be treated as sensitive. Delete logs when no longer needed and do not upload them to third-party services.

## Web Search

The `/search` endpoint requests DuckDuckGo's HTML result page and extracts a small set of result titles. This is a convenience integration only:

- it sends the query to DuckDuckGo;
- it does not run in a completely offline mode;
- it does not verify every source or fact;
- AI-generated summaries must be checked against original sources.

## Local Conversation

The control UI forwards chat payloads to the standard llama.cpp OpenAI-compatible chat endpoint:

```text
http://127.0.0.1:8080/v1/chat/completions
```

No chat data is sent to a PSLM cloud API. The only network services involved are the explicitly configured web search and asset download operations.

## Runtime Logs

- `pslm.log`: daemon startup, inference process, API, and error events
- `movements.jsonl`: opt-in full cursor position event recording

Both logs remain on the removable media. They are not deleted automatically by startup.

## Security Model

PSLM should not be used as an authority for unattended actions. It is a local automation scaffold intended for reviewed workflows.

Before distribution, operators should:

1. verify engine and model checksums;
2. review model license and redistribution restrictions;
3. test with a disposable profile;
4. inspect the downloaded archive contents;
5. keep movement and system logs private;
6. remove the USB device after use;
7. never approve shell-like, destructive, or credential-related actions.

## Official Branding

The official green-and-black PSLM mark is used in `ui.html` as a header brand block and a large sidebar logo. The browser favicon uses the complete vector mark supplied with the project. Reuse of the mark should preserve the dark center, green border, and exact PSLM lettering.

## License

See [LICENSE](LICENSE). Third-party llama.cpp binaries, GGUF models, and downloaded libraries remain subject to their own upstream licenses and redistribution terms.
