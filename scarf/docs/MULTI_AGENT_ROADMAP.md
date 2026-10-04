# Scarf Multi-Agent Architecture Roadmap

## Objective

Evolve Scarf from a Hermes-only application into a multi-agent macOS/iOS client while preserving Hermes as a fully supported, first-class backend at all times. Claude Code is the first additional backend. Codex, Gemini CLI, generic ACP agents, and other runtimes remain future-compatible targets rather than immediate implementation scope.

## Non-Negotiable Requirements

1. Hermes must continue to work throughout every phase. Existing Hermes chat, sessions, memory, cron, MCP, gateway, proxy, remote/SSH, configuration, and UI behavior must not be intentionally removed or degraded.
2. Multi-agent support is architectural from the beginning. Claude Code must not be wired directly into SwiftUI views through Claude-specific conditionals.
3. UI code communicates with generic agent abstractions. Backend-specific translation stays inside backend implementations.
4. Existing Hermes services remain intact until equivalent abstractions are proven by tests. Migration is additive, not a rewrite.
5. Every refactor phase must have an explicit Hermes regression gate before proceeding.
6. Project/repository state must remain independent from agent state so one project can eventually use multiple agents.
7. Backend capabilities control feature visibility. Unsupported capabilities are hidden/disabled rather than faked.
8. Claude Code integration should use structured CLI I/O rather than terminal scraping.
9. Local and existing remote/SSH workflows must remain valid where the backend supports them.
10. No future backend should require redesigning the core event/session/project model.

## Target Architecture

```text
Scarf UI
   |
   v
AgentCoordinator
   |
   v
AgentRegistry
   |
   +-- HermesBackend        (always supported)
   +-- ClaudeCodeBackend    (first new backend)
   +-- CodexBackend         (future)
   +-- GeminiBackend        (future)
   +-- ACPBackend           (future generic adapter)
```

The UI depends on generic types such as `AgentID`, `AgentBackend`, `AgentCapabilities`, `AgentSession`, `AgentMessage`, `AgentEvent`, `AgentToolCall`, `AgentPermissionRequest`, and `AgentUsage`.

## Core Design Principles

### Backend isolation

Each runtime owns its process protocol, configuration discovery, event decoding, session semantics, and capability declaration. Claude JSON must never leak into generic UI models. Hermes ACP details must remain encapsulated in the Hermes adapter.

### Capability-driven UI

Features should be enabled by backend capability declarations rather than `if agent == .claude` or `if agent == .hermes` checks. Initial capability categories include streaming, reasoning, tool calls, permissions, sessions, resume, MCP, skills, hooks, subagents, usage, file changes, shell commands, memory, cron, gateway, proxy, and remote execution.

### Preserve Hermes first

The first backend adapter will wrap the existing Hermes ACP path rather than replace it. Existing Hermes services (`HermesFileService`, environment/configuration services, gateway services, proxy services, etc.) remain authoritative for Hermes-only features.

## Phase 0 — Baseline and Safety Gate

### Completed

- Synced `dsmithnh3/scarf:main` to upstream `awizemann/scarf:main`.
- Verified both point to upstream Scarf 3.5.0 commit `b97c2ea41ac22e1a530ce324d87d59b5546d5605`.
- Created `feature/multi-agent-architecture` from that clean baseline.

### Before functional refactors

- Record current macOS build/test commands and schemes.
- Run the existing test suite and capture baseline failures, if any.
- Identify current Hermes chat entry points, ACP transport paths, session handling, project working-directory behavior, remote execution paths, and capability/version gating.
- Add targeted regression tests around the seams being abstracted before changing behavior.

## Phase 1 — Generic Agent Domain Model

Create a generic domain layer without changing runtime behavior.

Proposed files:

```text
scarf/scarf/Core/Agents/
  AgentID.swift
  AgentCapabilities.swift
  AgentModels.swift
  AgentEvent.swift
  AgentBackend.swift
  AgentRegistry.swift
```

Responsibilities:

- `AgentID`: stable backend identity (`hermes`, `claudeCode`, future IDs).
- `AgentCapabilities`: capability set used by UI and coordinator logic.
- `AgentModels`: sessions, messages, tools, permissions, usage, model descriptors, configuration.
- `AgentEvent`: normalized event stream consumed by UI.
- `AgentBackend`: protocol implemented by agent runtimes.
- `AgentRegistry`: registration/discovery of available backends.

Hermes behavior remains unchanged in this phase.

## Phase 2 — Hermes Adapter

Introduce `HermesBackend` as the first implementation of `AgentBackend` while preserving the current ACP stack.

```text
scarf/scarf/Agents/Hermes/
  HermesBackend.swift
  HermesEventMapper.swift
```

Rules:

- Reuse existing `ACPClient`/`ACPChannel` behavior.
- Do not duplicate Hermes process/SSH/session logic if current services can be wrapped.
- Hermes remains default backend for existing users/projects until they explicitly select another agent.
- Existing Hermes-specific screens remain available.
- Hermes-exclusive capabilities (memory, cron, gateway, proxy, etc.) stay visible when Hermes is selected.

Regression gate:

- Existing Hermes chat works locally.
- Existing Hermes remote/SSH path works.
- Sessions/resume work as before.
- Existing Hermes-only sidebar/configuration pages remain reachable.
- Existing Hermes tests continue passing.

## Phase 3 — Agent Coordinator + Registry Integration

Create an app-level coordinator that owns backend selection and event routing without moving feature-specific business logic into the coordinator.

```text
scarf/scarf/Core/Agents/AgentCoordinator.swift
```

Responsibilities:

- Resolve active backend through `AgentRegistry`.
- Create/resume/cancel sessions through generic interfaces.
- Expose normalized events to chat/session UI.
- Keep backend lifecycle state isolated per session/project.

At this point Hermes should run through the generic path with no visible behavior change.

## Phase 4 — Project Agent Selection

Extend the project model so a project can select a preferred agent while remaining agent-neutral.

Initial behavior:

- Existing projects default to Hermes.
- New projects can select Hermes or Claude Code once Claude support is enabled.
- Future schema allows multiple agent workspaces per project without requiring a migration rewrite.

Do not bind project identity to a single backend-specific session representation.

## Phase 5 — Claude Code Backend

Create the first new backend:

```text
scarf/scarf/Agents/ClaudeCode/
  ClaudeCodeBackend.swift
  ClaudeProcessManager.swift
  ClaudeStreamDecoder.swift
  ClaudeEventMapper.swift
  ClaudeSessionManager.swift
  ClaudeConfiguration.swift
```

### Process strategy

Use Claude Code structured stream I/O, conceptually:

```bash
claude -p \
  --input-format stream-json \
  --output-format stream-json \
  --verbose
```

Implementation requirements:

- Detect Claude Code installation/version.
- Launch in selected project working directory.
- Stream structured events.
- Normalize assistant text, tool calls, Bash output, file changes, permissions, usage, and completion/error states into `AgentEvent`.
- Support cancellation.
- Capture/resume Claude sessions according to Claude CLI semantics.
- Read supported Claude configuration without taking ownership of files Claude itself manages.
- Reuse the user's existing MCP/Claude configuration where possible.

## Phase 6 — Claude Code UI Surfaces

Add agent-aware surfaces only after backend behavior is stable.

Initial Claude-specific management may include:

- Claude installation/status.
- Model selection when discoverable/supported.
- `CLAUDE.md` discovery/opening.
- `.claude/` configuration discovery.
- MCP status/configuration links or editors where safe.
- Session history/resume.
- Permissions/tool activity.
- Usage information when provided by the CLI.

Generic chat/tool/session UI should be shared with Hermes.

## Phase 7 — Shared Agent UI Refactor

Gradually move common chat/session/tool UI from Hermes assumptions to generic agent models.

Guardrails:

- Convert one seam at a time.
- Add tests before altering existing behavior.
- Keep Hermes-specific views intact for Hermes-exclusive features.
- Avoid backend name checks in shared views; use capabilities.

## Phase 8 — Remote Execution

Evaluate Claude Code through existing remote transport abstractions.

Target behavior:

```text
Scarf macOS/iOS
   -> existing SSH transport
   -> remote Mac/Linux host
   -> Claude Code CLI
   -> remote project
```

Hermes remote behavior must remain unchanged.

## Phase 9 — Multi-Agent Project Workspaces

After Claude and Hermes are stable, evolve project storage toward multiple agent workspaces:

```text
Project
  +-- Hermes workspace/session(s)
  +-- Claude Code workspace/session(s)
  +-- future Codex workspace/session(s)
```

This phase enables future primary-agent/reviewer/researcher workflows but does not implement autonomous orchestration yet.

## Phase 10 — Future Backends

Only after the Hermes + Claude architecture is proven:

- Codex via native App Server integration.
- Gemini CLI via its structured interface.
- Generic ACP backend for ACP-compatible agents.
- Optional additional runtimes.

Each backend should only require:

1. Backend implementation.
2. Event mapper.
3. Session/config adapter.
4. Capability declaration.
5. Backend-specific settings UI when necessary.

No shared chat/project architecture rewrite should be required.

## Step-by-Step Development Guide

1. Sync fork with upstream and create feature branch. **Done.**
2. Establish build/test baseline on Scarf 3.5.0.
3. Inventory Hermes/ACP seams and write regression tests around them.
4. Add generic agent value types with unit tests.
5. Add `AgentBackend` protocol with mock backend tests.
6. Add `AgentRegistry` with deterministic registration/resolution tests.
7. Wrap current Hermes runtime in `HermesBackend` without changing UI.
8. Verify all Hermes regression gates.
9. Add `AgentCoordinator` and route Hermes through it.
10. Verify all Hermes regression gates again.
11. Extend project persistence with backward-compatible preferred-agent selection defaulting to Hermes.
12. Add Claude installation detection and process manager.
13. Add Claude stream decoder from captured/test fixtures.
14. Add Claude event mapper into generic `AgentEvent`.
15. Add Claude session lifecycle and cancellation.
16. Add Claude backend registration.
17. Add agent selector to the appropriate project/chat surface.
18. Share chat/tool UI using generic models.
19. Add Claude-specific configuration/status surfaces.
20. Validate local Hermes and Claude flows side by side.
21. Validate remote Hermes; then evaluate remote Claude support.
22. Add broader integration/UI tests.
23. Document setup, troubleshooting, supported capability matrix, and migration behavior.
24. Open PR from `feature/multi-agent-architecture` only after the branch passes the defined Hermes regression gates.

## Hermes Regression Checklist (Run Repeatedly)

- [ ] App launches with existing Hermes configuration.
- [ ] Hermes installation/version detection works.
- [ ] Local Hermes chat starts and streams.
- [ ] Hermes tool events render.
- [ ] Hermes permission flows work.
- [ ] Hermes session creation/resume works.
- [ ] Project working directory behavior is unchanged.
- [ ] Remote/SSH Hermes execution works where previously supported.
- [ ] Hermes memory UI works.
- [ ] Hermes cron UI works.
- [ ] Hermes MCP UI works.
- [ ] Hermes gateway controls work.
- [ ] Hermes proxy functionality works.
- [ ] Existing Hermes configuration/editor flows work.
- [ ] Existing tests pass or match the recorded pre-change baseline.

## Definition of v0.1 Success

A v0.1 multi-agent build is successful when:

1. Scarf starts normally for an existing Hermes user without requiring migration steps.
2. Hermes functionality remains available and regression-tested.
3. Shared agent abstractions are in place and used by at least Hermes and Claude Code.
4. Claude Code can be selected for a project/session.
5. Claude Code can start in the project directory, stream responses, show tools/commands, handle cancellation, and resume supported sessions.
6. Hermes-specific capabilities remain available when Hermes is selected.
7. Adding a future backend does not require redesigning the shared UI/domain model.

## Explicitly Out of Scope for v0.1

- Autonomous cross-agent orchestration.
- Codex implementation.
- Gemini implementation.
- Replacing Hermes-specific configuration systems with generic approximations.
- Removing Hermes-only UI.
- Rewriting Scarf's existing remote infrastructure without necessity.
- Making Scarf responsible for managing credentials owned by external agent CLIs.

## Long-Term Direction

Scarf becomes a native agent development environment rather than a single-agent GUI: projects, sessions, tools, terminal activity, diffs, configuration, MCP, remote hosts, and agent-specific capabilities coexist behind a stable multi-agent core. Hermes remains a supported backend instead of being treated as legacy compatibility.
