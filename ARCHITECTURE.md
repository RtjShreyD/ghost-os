# Ghost OS — Architecture Deep Dive

This document explains exactly how Ghost OS performs mouse-navigated clicks on
web apps, how recipes are built from scratch to execution, how it compares to
tools like PyAutoGUI, and what role vision models play.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [How Web-App Clicks Work (End-to-End)](#2-how-web-app-clicks-work-end-to-end)
3. [Recipe Lifecycle: Creation → Execution](#3-recipe-lifecycle-creation--execution)
4. [Is This AI-Driven PyAutoGUI?](#4-is-this-ai-driven-pyautogui)
5. [Vision Model Integration (ShowUI-2B)](#5-vision-model-integration-showui-2b)
6. [Component Reference](#6-component-reference)

---

## 1. System Overview

Ghost OS is a **macOS-native MCP server** written in Swift. An AI agent (Claude,
GPT-4, Cursor, etc.) connects to it over the Model Context Protocol (JSON-RPC on
stdio) and receives 29 tools that let it see and operate every app on the Mac.

```
┌──────────────────────────────────────────────────────────────────┐
│  AI Agent (Claude Code / Cursor / any MCP client)                │
│  Plans tasks, decides which tools to call, synthesizes recipes   │
└───────────────────────────┬──────────────────────────────────────┘
                            │  MCP Protocol — JSON-RPC over stdio
                            │  (Content-Length framing or NDJSON)
┌───────────────────────────▼──────────────────────────────────────┐
│  Ghost OS MCP Server  (Swift, macOS 14+)                         │
│                                                                  │
│  MCPServer.run() reads stdin → MCPDispatch.handle() → tool fn   │
│  29 tools, 60-second timeout per call                            │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────┐  ┌─────────┐ │
│  │ Perception   │  │   Actions    │  │  Vision  │  │ Recipes │ │
│  │ (AX tree)    │  │ (mouse/kbd)  │  │ (VLM)    │  │ (JSON)  │ │
│  └──────┬───────┘  └──────┬───────┘  └────┬─────┘  └────┬────┘ │
└─────────┼─────────────────┼───────────────┼──────────────┼──────┘
          │                 │               │              │
   ┌──────▼─────────────────▼───────────────▼──────────────▼──────┐
   │                  AXorcist Library                             │
   │  Element (AX tree navigation)  ·  InputDriver (CGEvent)      │
   │  PerformActionCommand  ·  Locator                             │
   └──────┬────────────────────────────────────────────────────────┘
          │                            │
   macOS Accessibility API       Chrome DevTools Protocol
   (AXUIElement, CGEvent)        (WebSocket, port 9222)
                                        │
                          Python Vision Sidecar
                          localhost:9876 — ShowUI-2B (MLX)
```

---

## 2. How Web-App Clicks Work (End-to-End)

Web apps (Gmail, Slack web, Notion, etc.) are notoriously hard to automate
because Chrome exposes nearly all DOM nodes as `AXGroup` — a role with no
accessible name and no actionable attribute. Ghost OS solves this with a
**layered fallback strategy**.

### The Four-Layer Click Stack

```
ghost_click query:"Compose" app:"Chrome"
      │
      ▼
Layer 1 ── AX-Native (AXPress)
      │   AXorcist.PerformActionCommand("AXPress", locator)
      │   ✓ Perfect for native macOS apps (Finder, Messages, Xcode)
      │   ✗ Fails on Chrome — "Compose" is AXGroup, no AXPress available
      │
      ▼
Layer 2 ── AX Tree Search + Synthetic Click
      │   Perception.findElements(query: "Compose")
      │   → AXorcist walks the AX tree (up to depth 25)
      │   → Finds element, reads .position(), sends CGEvent
      │   ✓ Works for Chrome elements that do have computed names
      │   ✗ Fails for deeply nested AXGroup nodes (depth > 25)
      │
      ▼
Layer 2.5a ── Chrome DevTools Protocol (CDP)
      │   CDPBridge.findElements(query: "Compose")
      │   → WebSocket to localhost:9222 (Chrome debug port)
      │   → Runtime.evaluate runs JavaScript in the page:
      │       1. Searches [aria-label] attributes
      │       2. Searches [placeholder] attributes
      │       3. Searches button/link text content
      │       4. Searches <label for="..."> elements
      │       5. Searches [title] and [alt] attributes
      │   → Returns {centerX, centerY} in Chrome viewport coordinates
      │   → Converts to screen coords: windowOrigin + toolbarHeight + viewport
      │   → InputDriver.click(at: screenPoint)
      │   ✓ Fast (~50ms), accurate, works for ALL Chrome/Electron apps
      │   ✗ Requires Chrome to be launched with --remote-debugging-port=9222
      │
      ▼
Layer 2.5b ── Vision / VLM Grounding (ShowUI-2B)
          VisionPerception.visionFallbackClick(query: "Compose")
          → ScreenCapture.captureWindowSync() → base64 PNG
          → VisionBridge.ground(imageBase64, description: "Compose")
          → HTTP POST to Python sidecar (localhost:9876)
          → ShowUI-2B inference: returns (x_norm, y_norm) in [0,1]
          → Scale to screen: norm * displayWidth/Height + windowOffset
          → InputDriver.click(at: screenPoint)
          ✓ Works on ANY visible element — canvas, SVG, WebGL, shadow DOM
          ✓ Confidence threshold 0.5 prevents spurious clicks
          ✗ Slow: 0.5–3s per inference (model warm) / 10–15s first call
```

### Coordinate Conversion (CDP Path)

CDP returns **viewport-relative** coordinates (origin = top-left of the
rendered page, not the OS window). To click the right spot on screen, Ghost OS
applies this transform:

```
screenX = windowX + viewportX
screenY = windowY + toolbarHeight + viewportY
                    ^^^^^^^^^^^^^^^^^
                    Chrome's tab strip + address bar (~88pt)
```

The window origin (`windowX`, `windowY`) comes from the macOS Accessibility
API: `appElement.focusedWindow()?.position()`.

### Synthetic Mouse Events

Once Ghost OS has a screen coordinate, it dispatches OS-level mouse events via
AXorcist's `InputDriver`:

```swift
InputDriver.click(at: CGPoint(x: 86, y: 223), button: .left, count: 1)
// Internally:
//   CGEvent(.leftMouseDown, location: point) → post(tap: .cghidEventTap)
//   CGEvent(.leftMouseUp,   location: point) → post(tap: .cghidEventTap)
//   Thread.sleep(forTimeInterval: 0.15)    // let app process the event
```

`cghidEventTap` is the same source used by legitimate pointing devices, so
apps cannot distinguish Ghost OS clicks from physical mouse clicks.

---

## 3. Recipe Lifecycle: Creation → Execution

A **recipe** is a JSON file that turns a multi-step workflow into a single
tool call with typed parameters. It is the mechanism that makes Ghost OS
economical: the AI reasons once and encodes the workflow; a lightweight model
runs it forever.

### Recipe JSON Structure

```json
{
  "schema_version": 2,
  "name": "gmail-send",
  "description": "Send an email via Gmail",
  "app": "Google Chrome",
  "params": {
    "recipient": { "type": "string", "required": true,  "description": "To address" },
    "subject":   { "type": "string", "required": true,  "description": "Subject line" },
    "body":      { "type": "string", "required": false, "description": "Email body" }
  },
  "preconditions": {
    "app_running": "Google Chrome",
    "url_contains": "mail.google.com"
  },
  "steps": [
    {
      "id": 1,
      "action": "click",
      "note": "Open compose window",
      "target": {
        "criteria": [{ "attribute": "AXRole", "value": "AXButton" }],
        "computedNameContains": "Compose"
      },
      "wait_after": { "condition": "elementExists", "value": "To recipients", "timeout": 5 }
    },
    {
      "id": 2,
      "action": "type",
      "note": "Fill To field",
      "target": { "criteria": [], "computedNameContains": "To recipients" },
      "params": { "text": "{{recipient}}" }
    },
    {
      "id": 7,
      "action": "hotkey",
      "note": "Send",
      "params": { "keys": "cmd,return" },
      "wait_after": { "condition": "elementGone", "value": "Send", "timeout": 10 }
    }
  ],
  "on_failure": "stop"
}
```

Key concepts:
- **`{{param}}`** — template placeholders substituted at runtime
- **`wait_after`** — polling condition that confirms the action took effect
- **`on_failure`** — `"stop"` (default) or `"skip"` per step or globally
- **`preconditions`** — checked before the first step; surfaced as actionable errors

### Three Ways to Create a Recipe

**Method 1 — Self-Learning (v2.2.1+, recommended)**

The user performs the task once while Ghost OS observes via a CGEvent tap:

```
Agent:  ghost_learn_start task_description:"send email in Gmail"
User:   [clicks Compose, types address, types subject, Cmd+Return]
Agent:  ghost_learn_stop
        → Returns 8 enriched action objects:
          { type: "click", ax_name: "Compose", ax_role: "AXButton",
            position: {x:86,y:223}, timestamp: 1710000001.2 }
        → LLM synthesizes JSON recipe with parameters + wait conditions
Agent:  ghost_recipe_save name:"gmail-send" recipe:{...}
```

No screenshots. No vision model. The CGEvent tap captures:
- Mouse button, click count, position
- Keyboard key codes and modifiers
- AX context at the moment of each event (role, name, value, window title, URL)

The LLM's job is to: identify which values are parameters (e.g. email address),
group related steps, add appropriate `wait_after` conditions, and write the JSON.

**Method 2 — Manual Authoring**

The agent inspects the app with `ghost_context` / `ghost_find` / `ghost_inspect`,
identifies locators (role + name or DOM id), and writes the JSON directly.
Best for simple recipes or when the user cannot or won't demonstrate the workflow.

**Method 3 — Hybrid**

Use `ghost_learn_start/stop` to get the raw action sequence, then have the LLM
refine it: merge redundant steps, parameterize values, add robust waits.

### Recipe Execution

`RecipeEngine.run(recipe, params)` orchestrates every step:

```
1. Validate required params are present
2. Check preconditions (app running? URL correct?)
3. ghost_focus app — brings target app to front
4. For each step:
   a. Substitute {{params}} in all string fields
   b. Dispatch to action handler (click/type/press/hotkey/scroll/…)
   c. If action fails:
        on_failure=stop  → return error with full diagnostic context
        on_failure=skip  → log and continue
   d. If wait_after set:
        WaitManager.waitFor() polls every 500ms up to timeout
        Returns error if condition never satisfied
5. Return step-by-step timing + success/fail breakdown
```

---

## 4. Is This AI-Driven PyAutoGUI?

**Short answer**: Ghost OS is architecturally different and more reliable, but it
can perform the same end goal (clicking, typing, scrolling any UI on screen).

### Comparison Table

| Dimension | PyAutoGUI | Ghost OS |
|-----------|-----------|----------|
| **Language / Platform** | Python, cross-platform | Swift, macOS-only |
| **How it finds elements** | Screenshots + image matching | Accessibility tree (structured labels) |
| **Fallback for web apps** | Screenshots only | AX tree → CDP → VLM (3 layers) |
| **Synthetic input method** | `CGEvent` via ctypes | `CGEvent` via AXorcist InputDriver |
| **AX-native actions** | No | Yes (`AXPress`, `AXSetValue`) |
| **Recipe / replay system** | No | Yes (JSON recipes, self-learning) |
| **LLM role** | External (user-written code) | Integral (synthesizes recipes, drives tools) |
| **Vision model needed?** | Often (for element finding) | Optional (last-resort fallback only) |
| **Speed** | 100–500ms/action | 50–300ms/action (AX/CDP path) |
| **Canvas/WebGL support** | Via screenshots | Via ShowUI-2B VLM grounding |

### Where the LLM Fits

Ghost OS itself contains **zero LLM code**. It is a pure automation backend.
The AI lives in the **agent** (Claude Code, Cursor, GPT-4) that:

1. **Decides what to do** — parses user intent, picks the right recipe or sequence
2. **Calls Ghost OS tools** — via MCP protocol, exactly like calling a function
3. **Synthesizes recipes** — reads raw action recordings from `ghost_learn_stop`
   and writes parameterised JSON (the LLM's reasoning is the "compiler")
4. **Handles failures** — inspects error context, retries with different strategies

This split — frontier model for reasoning, lightweight tools for execution —
is what makes Ghost OS fast and local. Once a recipe is saved, subsequent
runs need no LLM reasoning at all.

---

## 5. Vision Model Integration (ShowUI-2B)

### What ShowUI-2B Is

ShowUI-2B is a **2-billion-parameter vision-language model** fine-tuned
specifically for UI grounding — given a screenshot and a text description,
it returns the `(x, y)` coordinate of the described element.

- **Architecture**: Qwen2VL with MLX optimisation for Apple Silicon
- **Size**: ~3 GB
- **Inference speed**: 250ms–3s (warm), 10–15s (cold load)
- **Runs locally**: Python HTTP sidecar on `localhost:9876` via `mlx_vlm`
- **Zero cloud calls**: your screenshots never leave the machine

ShowUI-2B is a **grounding** model, not a general-purpose VLM. It does not
describe screenshots, answer questions, or understand context. Its only job
is: "where is the thing described by this text?"

### When It Is Invoked

```
ghost_click  ──► Layer 1 AX-native  ──(fail)──►
              ► Layer 2 AX search   ──(fail)──►
              ► Layer 2.5a CDP      ──(fail)──►
              ► Layer 2.5b VLM  ◄─── ShowUI-2B runs here
```

and explicitly via:

```
ghost_ground description:"Send button" crop_box:[510,168,840,390]
  → screenshot → VisionBridge.ground() → HTTP POST /ground → ShowUI-2B
  → returns {x: 620.0, y: 350.0, confidence: 0.95}
```

### Crop Box Optimisation

Passing `crop_box` dramatically improves both speed and accuracy:

```
Full-screen grounding:  1280×800 image → VLM → 1–3s, can confuse similar items
Crop-based grounding:   330×222 region → VLM → 250ms, no background confusion
```

Ghost OS crops the image server-side (Python sidecar), runs VLM on the crop,
then maps the returned normalized coordinates back to full-screen space.

### Architecture Diagram

```
Swift (Ghost OS)                   Python (Vision Sidecar)
─────────────────────              ────────────────────────────────────
VisionBridge.ground()
  → POST /ground                 →  _handle_ground()
    {image: base64,                   if crop_box: crop image
     description: "...",              _vlm_ground(crop_path, ...)
     screen_w: 1728,                    mlx_vlm.stream_generate(
     screen_h: 1117,                      model=ShowUI-2B,
     crop_box: [510,168,840,390]}         image=path,
                                          prompt="Find <description>",
                                          max_tokens=128)
                                    → parse [x, y] from output
  ← {x: 620.0, y: 350.0,        ←  → scale by screen_w / screen_h
     confidence: 0.95,               → return JSON
     method: "crop-based",
     inference_ms: 280}
VisionPerception:
  mappedX = result.x + windowOffsetX
  mappedY = result.y + windowOffsetY
InputDriver.click(at: CGPoint(mappedX, mappedY))
```

### ghost_parse_screen vs ghost_ground

| | `ghost_parse_screen` | `ghost_ground` |
|---|---|---|
| **Purpose** | Enumerate all visible interactive elements | Locate one specific element |
| **VLM needed?** | No — uses AX tree + CDP | Yes — requires ShowUI-2B sidecar |
| **Returns** | Array of elements with coordinates | Single (x, y) coordinate |
| **When to use** | Orientation, planning | Targeting a specific element |
| **YOLO future** | Will upgrade to /detect when YOLO ships | N/A |

`ghost_parse_screen` was previously a stub that required the sidecar even
though it did nothing with it. It now works without the sidecar by collecting
elements from the AX tree (native apps) or Chrome DevTools Protocol (web apps),
making it genuinely useful for both app types.

---

## 6. Component Reference

| File | Purpose |
|------|---------|
| `Sources/ghost/main.swift` | CLI entry: `ghost mcp / setup / doctor / status` |
| `Sources/GhostOS/MCP/MCPServer.swift` | JSON-RPC stdio loop, timeout management |
| `Sources/GhostOS/MCP/MCPDispatch.swift` | Maps 29 tool names to handler functions |
| `Sources/GhostOS/MCP/MCPTools.swift` | Tool schema definitions (names, params, descriptions) |
| `Sources/GhostOS/Perception/Perception.swift` | `ghost_context/find/read/inspect/element_at/screenshot` |
| `Sources/GhostOS/Perception/Annotate.swift` | `ghost_annotate` — labeled screenshots |
| `Sources/GhostOS/Actions/Actions.swift` | `ghost_click/type/press/hotkey/scroll/drag/hover/long_press` |
| `Sources/GhostOS/Actions/FocusManager.swift` | App focus save/restore |
| `Sources/GhostOS/Recipes/RecipeEngine.swift` | `ghost_run` — step execution with waits and failure handling |
| `Sources/GhostOS/Recipes/RecipeTypes.swift` | Recipe JSON schema (Codable structs) |
| `Sources/GhostOS/Recipes/RecipeStore.swift` | Recipe file I/O (`~/.ghost-os/recipes/`) |
| `Sources/GhostOS/Vision/CDPBridge.swift` | Chrome DevTools Protocol client (DOM search, coordinates) |
| `Sources/GhostOS/Vision/VisionBridge.swift` | HTTP client to Python vision sidecar |
| `Sources/GhostOS/Vision/VisionPerception.swift` | `ghost_parse_screen` / `ghost_ground` |
| `Sources/GhostOS/Learning/LearningRecorder.swift` | CGEvent tap for `ghost_learn_start/stop` |
| `Sources/GhostOS/Screenshot/ScreenCapture.swift` | ScreenCaptureKit wrapper |
| `vision-sidecar/server.py` | Python HTTP server hosting ShowUI-2B (MLX) |
| `recipes/` | Pre-built workflows (gmail-send, slack-send, arxiv-download, …) |
| `GHOST-MCP.md` | Agent instructions injected into Claude's system prompt |
