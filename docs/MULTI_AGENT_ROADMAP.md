# Scarf Multi-Agent Architecture Roadmap

Updated: 2026-10-05
Branch: `feature/multi-agent-architecture`
Primary near-term backend: Claude Code CLI
Compatibility requirement: Hermes remains the default backend and its existing backend/UI behavior must continue to work throughout the migration.

## Objective

Evolve Scarf from a Hermes-centered application into a backend-neutral macOS agent client without replacing or destabilizing Hermes. The generic ScarfCore contract owns session routing, event normalization, conversation state, capabilities, and lifecycle. Backend adapters translate Hermes, Claude Code, and later Codex/other agents into that contract. Scarf's existing UI remains the product surface; ideas adopted from other projects must be restyled and integrated into Scarf rather than transplanted as a second UI architecture.

## Non-negotiable guardrails

1. `.hermes` remains the default route unless a project/session explicitly selects another backend.
2. Hermes-specific functionality remains available behind the Hermes adapter; generic core/UI code must not silently remove Hermes features.
3. Backend capabilities are truthful. Do not advertise permissions, tools, models, attachments, resume, or other features until the adapter implements them.
4. Routed streaming data is ordered protocol data and must not be silently dropped.
5. Session-scoped events must not leak between windows or conversations.
6. Lifecycle operations must clean up backend processes/sessions deterministically.
7. Prefer deterministic async tests over sleeps/polling.
8. Every implementation milestone must pass the targeted multi-agent tests, ScarfCore compile gate, and macOS app build before it is considered complete.

## Architecture implemented so far

### Backend-neutral core

- `AgentBackend` abstraction and backend IDs/capabilities.
- `AgentCoordinator` backend registry and routing.
- Default session creation continues to route to Hermes.
- Explicit Claude Code routing is supported.
- Generic `AgentEvent` stream plus `AgentRoutedEvent` containing sequence, backend ID, optional session ID, and event.
- Session-scoped backends can expose `sessionEvents`.

### Multi-window and streaming reliability

- Independent `subscribeToRoutedEvents()` subscriptions allow multiple consumers/windows without competing for one stream.
- Routed subscriptions are unbounded/lossless rather than `bufferingNewest(256)` because dropping old text/tool deltas corrupts the protocol stream.
- Regression coverage sends 2,048 routed deltas and verifies exact sequence/backend/event preservation.

### Conversation/session isolation

- `AgentConversationController` owns a backend-neutral conversation lifecycle.
- Active backend/session filtering prevents scoped events for one conversation from mutating another.
- Session-isolation tests use exact completion conditions rather than fixed sleeps.

### Claude Code adapter

Current Claude Code work supports the core create/resume/send/interrupt/close and session-scoped streaming path, with normalized reasoning/tool/file/command/usage events. Claude-specific permission responses are not yet treated as complete and therefore must not be advertised as a supported capability.

## Verification history

- `a6d6dab` — hardened routed event delivery under burst load.
- `c8002fe` — added lossless 2,048-event burst regression coverage. CI run 37303356088 passed all three gates.
- `9cbdb9b` — made session-isolation testing deterministic. CI run 37306053532 passed macOS App Build, Multi-Agent Tests, and ScarfCore Compile Gate.
- `cfdc588` — RED TDD regression requiring replacement sessions to close the prior active session. CI run 37307337357 failed only the new expected lifecycle assertion while the macOS build and compile gate passed. This is the current implementation point.

## Current TDD milestone

### Replacement-session cleanup

**RED confirmed.** Starting a replacement session currently leaves the previous active backend session open.

Next production change:

1. Before installing a newly created/resumed active session, close the previous active session when one exists and it is being replaced.
2. Preserve the existing Hermes route and backend semantics.
3. Define failure semantics deliberately: a failed cleanup must not leave the controller claiming an ambiguous active session.
4. Re-run the replacement-session test and all multi-agent gates.
5. Commit only after GREEN verification.

## Next lifecycle milestones

1. Reject late scoped events from a previous session after switching to a new session.
2. Reject late unscoped legacy events after an explicit close without breaking Hermes compatibility.
3. Harden cancel/close/process termination semantics for Claude Code.
4. Test rapid start/resume/switch/close races and multi-window operation.
5. Add lifecycle observability/diagnostics where backend process failures need to surface in UI state.

## macOS-CLUI-CC adoption analysis

Reference repository: `dsmithnh3/macOS-CLUI-CC` (Opal architecture).

The repository is valuable as a pattern/source library, but Scarf should **selectively port concepts and tested logic**, not merge the application wholesale. Scarf already has a mature Hermes product surface and a backend-neutral core under construction. The correct direction is to adapt CLUI capabilities behind ScarfCore interfaces and present them through Scarf-native views.

### Priority A — adopt/port early

#### 1. Provider/event normalization patterns

CLUI contains dedicated provider adapters and normalizers for Claude, Codex, Gemini, Ollama, OpenAI Responses, Foundation Models, and mocks. Particularly useful references include:

- `Sources/OpalProviders/ClaudeProvider.swift`
- `Sources/OpalProviders/ClaudeEventNormalizer.swift`
- `Sources/OpalProviders/CodexProvider.swift`
- `Sources/OpalProviders/CodexEventNormalizer.swift`
- `Sources/OpalProviders/ProviderBootstrap.swift`
- `Sources/OpalProviders/ProviderEnvironment.swift`
- `Sources/OpalRuntime/ProviderAdapter.swift`

**Scarf action:** use the normalization and capability ideas to harden `AgentBackend` adapters. Do not replace Scarf's coordinator with Opal's provider runtime.

#### 2. Session/transcript persistence semantics

CLUI's `SessionModels`, `SessionCoordinator`, application-support persistence, transcript merging, cost accumulation, and session tests are directly relevant to Claude/Codex chat continuity.

**Scarf action:** compare its persisted session schema, tool-result merge behavior, resume semantics, usage/cost accumulation, and migration strategy with Scarf's conversation state. Port only backend-neutral semantics that improve resume/history correctness.

#### 3. Slash-command discovery and routing

CLUI has `SlashCommandRouter`, `SlashHintList`, composer integration, and tests around composer state.

**Scarf action:** build a Scarf-native command registry that merges:

- Scarf/Hermes commands,
- backend-provided commands,
- Claude Code commands where discoverable/supported,
- future Codex commands,
- Scarf-local commands.

The UI should use Scarf styling and existing chat/composer structure. Command availability must be capability/backend aware.

#### 4. Skills/plugins/MCP discovery patterns

CLUI includes `SkillStore`, `MCPCatalog`, plugin/skill/MCP overlays, and settings surfaces.

**Scarf action:** adopt the catalog/store separation and discovery logic where compatible. Scarf should expose a unified Scarf-native capability surface while keeping Hermes plugins/skills intact and allowing Claude Code-specific skills/MCP configuration to coexist rather than overwrite Hermes configuration.

#### 5. Permission coordination

CLUI includes a dedicated `PermissionCoordinator` and UI permission surfaces.

**Scarf action:** use it as a design reference for a generic permission state machine. Do not mark Claude Code permissions supported until the adapter can round-trip actual permission requests/responses safely. Hermes permission behavior must continue through its existing path or a verified adapter.

### Priority B — adopt after Claude lifecycle is green

#### 6. Provider setup and bootstrap UX

CLUI has provider descriptors/bootstrap/environment handling and Settings integration for multiple providers.

**Scarf action:** create a Scarf-native Agent/Provider settings layer with installation detection, executable path/version, authentication/setup status, default backend by project, model selection, and capability diagnostics. Start with Hermes + Claude Code. Add Codex after the Claude path is stable. API-provider setup (OpenAI Responses, Gemini, Ollama, Foundation Models) should be a later backend category rather than conflated with CLI agents.

#### 7. Workspace and terminal concepts

Useful CLUI components include workspace models, file navigation/edit buffers, terminal session store, diff views, repo-map indexing, and workspace persistence.

**Scarf action:** selectively adopt workspace/session concepts only where they strengthen agent workflows. Scarf should not become an Opal clone. High-value candidates are persistent terminal sessions, diff/edit review, repo context, and workspace state associated with an agent session.

#### 8. Diff/edit journal and artifacts

CLUI's `DiffStore`, artifact/context models, file compare UI, and edit-history concepts can make Claude Code actions inspectable.

**Scarf action:** design a backend-neutral `AgentArtifact` / edit-event representation so Hermes, Claude Code, and Codex can surface file modifications consistently in Scarf.

### Priority C — evaluate later

#### 9. Native agent loop and sub-agents

CLUI contains `AgentLoop`, native tool registry, shell/file/git/search/skill tools, `SubAgentCoordinator`, and `AgentMailbox`.

**Scarf action:** do not import this as the current control plane. Claude Code and Hermes already provide their own agent runtimes. Reuse ideas for orchestration only when Scarf intentionally becomes a coordinator of multiple agent workers. Keep this separate from backend adapter work.

#### 10. Repo map/indexing

CLUI's `RepoMapIndexer` and symbol extractors are useful for local context/navigation.

**Scarf action:** evaluate as an optional Scarf workspace service. It should not be required for Claude Code transport.

#### 11. Automation, browser, inspector, iMessage/wake-word surfaces

These are substantial CLUI product features but are not prerequisites for Scarf's multi-agent conversion.

**Scarf action:** defer. Revisit individually after Hermes + Claude Code + Codex foundations are stable.

## Explicitly do not transplant

- Opal's entire `AppModel` or application shell.
- Opal branding, layout, pill UI, sidebar, or workspace shell as a replacement for Scarf UI.
- A second provider/session coordinator parallel to `AgentCoordinator`.
- Native tool/agent loops that duplicate Hermes or Claude Code behavior.
- Permission UI that implies unsupported backend capabilities.
- Provider secrets/configuration formats without a Scarf-specific security and migration review.

## Proposed integration sequence

### Phase 1 — finish Claude Code foundation

- GREEN replacement-session cleanup.
- Late-event and closed-session isolation.
- Process cancel/close cleanup.
- Claude Code installation/version diagnostics.
- Session resume/history fidelity.
- Capability contract audit.

### Phase 2 — adopt high-value CLUI patterns

- Compare/port provider normalization improvements.
- Build backend-aware slash command registry + Scarf-native command hints.
- Add unified skills/plugins/MCP catalog abstractions while preserving Hermes.
- Introduce generic permission state machine with truthful capability gating.
- Improve session persistence/tool-result/usage merge semantics.

### Phase 3 — Scarf-native setup and UX

- Agent/provider settings for Hermes and Claude Code.
- Project-level backend/model preference.
- Scarf-native backend indicator/switcher.
- Transcript rendering for reasoning, tool calls, commands, files, usage, permissions, and errors.
- Diff/artifact review surfaces adapted to Scarf's visual language.

### Phase 4 — Codex

- Implement Codex adapter using the same `AgentBackend` contract.
- Reuse CLUI Codex normalizer/provider lessons where applicable.
- Add Codex installation/auth/model/capability diagnostics.
- Run the same lifecycle, burst, isolation, and multi-window contract tests used by Claude Code.

### Phase 5 — optional providers and advanced orchestration

- Evaluate Gemini CLI/API, OpenAI Responses, Ollama, Foundation Models, and other backends.
- Evaluate repo map, terminal/workspace services, artifacts, automation, and sub-agent coordination as independent Scarf features.

## Definition of done for a backend

A backend is production-ready only when it has:

- installation/auth status,
- truthful capabilities,
- create/resume/send/cancel/close lifecycle,
- ordered streaming normalization,
- session isolation,
- deterministic replacement/cleanup semantics,
- multi-window-safe subscriptions,
- error/recovery mapping,
- persisted backend/session identity,
- relevant commands/models surfaced without hard-coded generic-UI assumptions,
- CI contract tests,
- no regression to Hermes default behavior.

## Documentation discipline

Update this document with every substantive multi-agent milestone. Record the commit, behavior added/fixed, verification result, and any change to the adoption order. `TASKS.md` remains the upstream/Hermes-oriented task board; this roadmap is the focused source of truth for the multi-agent conversion so upstream task history is not rewritten or lost.
