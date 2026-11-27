26-11-19-01:repo start
26-11-21-01:basic pushed
26-11-22-01:hybrid/npu(detect-only)/RAG finished
26-11-22-02:beta(v0.0.1)published
26-11-25-01:fixed Download-PSLMAssets.ps1 temporary-file collisions, partial-download cleanup, redirect-host validation, archive validation, and missing llama-server.exe detection
26-11-25-02:replaced BM25 RAG splitting/ranking with Lite Paragraph Cutter, added CJK-aware lightweight matching, modernized responsive UI styling
26-11-25-03:packaged and published beta v0.0.2 source bundle
26-11-25-04:added GUI file selection for in-place engine/model paths, portable path persistence, and safer quick-command TerminalUI for beta v0.0.3
26-11-26-01:secured local management API with per-start random token and file-origin CORS, escaped SendKeys literals, split Chinese RAG punctuation, resolved Git identity dynamically, and added scanned button actions with mandatory red-outline approval
26-11-26-02:connected the UI Agent panel to authenticated scan/click APIs, added two-second target-window handoff, revalidated target bounds before approved clicks, and surfaced Agent/API/model connection failures in the UI for beta v0.0.4
26-11-26-03:added static local-AI PowerShell explanations with project-path and SHA-256 review checks plus explicit native execution approval, and created local launcher/installer C# sources and test executables (not included in Git)
26-11-27-01:expanded the local-only installer with final-folder selection, CPU/RAM/NVIDIA detection, optional confirmed GGUF pre-download with redirect/hash/header/free-space checks, cancellable progress, optional desktop shortcut and launch, and safer existing-file handling; built installer EXE, kept C# sources and EXEs unpushed
26-11-27-02:hardened the asset downloader to check HTTPS and the exact approved host before every redirect request, and added verified Hugging Face storage CDN hosts
26-11-27-03:refreshed ui.html with the full PSLM mark, accessible motion and responsive chat, animated local-model thinking and recording states, in-memory conversation context with copy/clear controls, plus persistent theme and focus modes; embedded the PSLM mark as the icon in local launcher and installer builds
26-11-28-01:restored the shared preview to desktop dimensions, moved the app-style conversation view above TerminalUI, and added timestamped local chat transcript persistence with explicit clear behavior; documented browser-local privacy
26-11-28-02:debugged the v0.0.5 source bundle with PowerShell parsing, C# installer compilation, browser chat persistence/clear and responsive-layout checks; prepared a source-only beta release with no executable or test_code directory
