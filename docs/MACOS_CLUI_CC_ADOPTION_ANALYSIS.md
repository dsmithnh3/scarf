# macOS-CLUI-CC → Scarf Adoption Analysis

Updated: 2026-10-05
Scarf branch: `feature/multi-agent-architecture`
Reference repository: `dsmithnh3/macOS-CLUI-CC`
Target repository: `dsmithnh3/scarf`

## Executive summary

`macOS-CLUI-CC` is highly relevant to Scarf's multi-agent conversion. It contains working architectural patterns and code for provider normalization, Claude/Codex integration, sessions, transcript state, slash commands, skills/plugins/MCP discovery, permissions, provider setup, workspace/terminal state, diffs/artifacts, repository indexing, native tools, and sub-agent orchestration.

Scarf should **not merge or transplant the CLUI/Opal application wholesale**. Scarf already has a mature Hermes backend and product UI, and the current branch is deliberately creating a backend-neutral `ScarfCore` architecture. Importing Opal's application shell or parallel coordinator would create competing state/lifecycle systems and threaten Hermes compatibility.

The recommended strategy is therefore:

> **Harvest proven CLUI concepts, algorithms, normalization rules, persistence semantics, tests, and selected services; adapt them behind Scarf's `AgentBackend`/`AgentCoordinator` contracts; render them through Scarf-native UI.**

The first implementation priority remains completing and hardening Claude Code lifecycle support. Once that foundation is GREEN, CLUI should be used aggressively as a reference for the next Scarf capabilities rather than reinventing those systems.

---

## 1. Scarf architecture that must remain authoritative

Scarf's multi-agent architecture should continue to be centered on:

- backend-neutral agent protocols and event types in ScarfCore;
- `AgentBackend` adapters;
- `AgentCoordinator` for registration/routing;
- `AgentConversationController` for one conversation lifecycle;
- `AgentConversationState` as the backend-neutral reducer/state model;
- routed, ordered events with backend and session identity;
- capability flags that accurately describe each backend;
- Scarf's existing UI as the presentation layer.

### Hermes compatibility requirements

Hermes remains a first-class backend, not a legacy feature to be replaced.

Required invariants:

1. `.hermes` remains the default session route unless explicitly changed.
2. Existing Hermes backend functionality continues to work.
3. Existing Hermes UI workflows remain available.
4. Generic abstractions must not silently reduce Hermes capabilities.
5. New Claude/Codex features should be capability-gated instead of introducing assumptions into shared UI.
6. No CLUI adoption should create a second session/provider coordinator beside `AgentCoordinator`.

---

## 2. Current Scarf multi-agent state

### Implemented foundation

Scarf already has:

- `AgentBackend` abstraction;
- backend IDs and capability descriptions;
- `AgentCoordinator` backend registry/routing;
- Hermes default routing;
- explicit Claude Code routing;
- generic `AgentEvent` handling;
- `AgentRoutedEvent` with sequence, backend ID, optional session ID, and event;
- session-scoped backend event streams;
- independent routed subscriptions for multiple consumers/windows;
- backend/session filtering in conversation controllers;
- Claude Code create/resume/send/interrupt/close paths;
- normalized Claude reasoning/tool/file/command/usage events.

### Streaming reliability work

Routed subscriptions were changed from a bounded `bufferingNewest(256)` policy to lossless/unbounded delivery because agent text/tool/file deltas are ordered protocol information. Silently discarding older deltas can corrupt a transcript or tool stream.

A 2,048-event regression test verifies exact sequence, backend identity, and event preservation.

### Session isolation work

Session-isolation tests now wait for deterministic state conditions instead of relying on fixed sleeps. Multiple conversations sharing a session-scoped backend must not consume each other's events.

### Current lifecycle TDD milestone

Replacement-session cleanup is GREEN on `cursor/session-lifecycle-hardening-89c0`. Starting or resuming a different session closes the previous active session. Late scoped events from the replaced session do not modify the new one. After `close()`, scoped and legacy unscoped events do not mutate or resurrect the conversation. Hermes remains the default, and Claude permissions stay unadvertised.

The adoption strategy in this document is unchanged.

Relevant recent commits:

- `a6d6dab` — hardened routed agent event delivery.
- `c8002fe` — lossless routed burst regression.
- `9cbdb9b` — deterministic session-isolation test.
- `cfdc588` — RED replacement-session cleanup test.
- `830f55f` — updated multi-agent roadmap and initial CLUI adoption analysis.
- `3d7c5c81` — close the previous session before creating a replacement.
- `bbbc5e11` — lock late scoped events after replacement.
- `83cf7bfa` — close the previous session when resume switches identity.
- `e5de0682` — ignore events after close, including unscoped legacy events.
- `568f1366` — rapid replacements close each outgoing session.

---

## 3. What exists in macOS-CLUI-CC that matters to Scarf

The CLUI/Opal repository contains mature work across several categories that overlap directly with Scarf's roadmap.

### Provider/backend architecture

Relevant areas include provider adapters, provider bootstrap/environment handling, event normalizers, provider descriptors, and tests. The repository includes work for Claude, Codex, Gemini, Ollama, OpenAI Responses, Apple Foundation Models, and mocks.

Representative files include:

- `Sources/OpalProviders/ClaudeProvider.swift`
- `Sources/OpalProviders/ClaudeEventNormalizer.swift`
- `Sources/OpalProviders/CodexProvider.swift`
- `Sources/OpalProviders/CodexEventNormalizer.swift`
- `Sources/OpalProviders/ProviderBootstrap.swift`
- `Sources/OpalProviders/ProviderEnvironment.swift`
- `Sources/OpalRuntime/ProviderAdapter.swift`

### Sessions and chat

CLUI contains session models, session coordination, application-support persistence, transcript merging, tool-result merging, usage/cost accumulation, and session-related tests.

### Slash commands

CLUI includes command routing, slash-command suggestions/hints, composer integration, and composer-state tests.

### Skills, plugins, and MCP

CLUI contains skill stores/catalog concepts, MCP catalog logic, plugin/skill/MCP overlays, settings integration, and tests.

### Permissions

CLUI includes a dedicated permission coordinator and permission-oriented UI/state handling.

### Provider setup

CLUI contains provider descriptors, environment/bootstrap logic, settings integration, and multi-provider configuration concepts.

### Workspace and terminal

CLUI includes persistent terminal session state, workspace tabs, file navigation, editable file buffers, code/markdown views, and workspace persistence concepts.

### Diffs and artifacts

CLUI contains diff/edit concepts, artifact/context models, and file comparison/review surfaces that can make agent changes inspectable.

### Repository intelligence

CLUI includes repository mapping/indexing and symbol extraction concepts that can provide local project context.

### Native tools and orchestration

CLUI also contains a native agent loop, tool registry, shell/file/git/search/skill tools, script services, sub-agent coordination, and agent mailbox concepts.

These are strategically interesting, but they should not replace Claude Code or Hermes as the current agent runtimes.

---

## 4. Adoption matrix

| CLUI capability | Scarf recommendation | Priority | Integration strategy |
|---|---|---:|---|
| Claude event normalization | Adopt patterns and missing mappings | Very High | Fold into Claude `AgentBackend` adapter |
| Provider capability modeling | Adopt concepts | Very High | Extend Scarf capability contract |
| Session persistence/resume | Adapt semantics | Very High | Keep Scarf conversation/session authority |
| Tool/result transcript merging | Port proven logic/tests | Very High | Backend-neutral reducer/persistence |
| Slash-command routing | Adapt | Very High | Scarf-native registry + composer UI |
| Slash command hints | Rebuild in Scarf style | Very High | Existing Scarf composer/chat surface |
| Skills catalog/store | Adapt architecture | Very High | Unified capability/catalog service |
| Plugins catalog | Adapt architecture | High | Preserve Hermes plugin behavior |
| MCP catalog/setup | Adapt architecture | Very High | Unified Scarf settings/capability surface |
| Permission coordinator | Adapt state machine | High | Generic permission contract + capability gate |
| Provider bootstrap/setup | Adapt | High | Scarf Settings, Hermes + Claude first |
| Codex provider/normalizer | Use as major reference | High | Future Codex `AgentBackend` |
| Usage/cost accumulation | Adapt | High | Generic usage accounting |
| Diff/edit journal | Adapt | Medium-High | Generic artifacts/file-change model |
| Terminal session persistence | Selectively adopt | Medium | Scarf workspace enhancement |
| File navigator/editor | Selectively adopt | Medium | Only if aligned with Scarf product direction |
| Repo map/indexer | Evaluate as service | Medium | Optional workspace context service |
| Native tool registry | Study only initially | Later | Avoid duplicating backend agent tools |
| Native agent loop | Do not make current control plane | Later | Possible future orchestration layer |
| Sub-agent coordinator/mailbox | Evaluate later | Later | Multi-worker orchestration phase |
| Browser/inspector | Defer | Later | Independent product feature |
| Automation | Defer | Later | Independent product feature |
| iMessage/wake word | Defer | Later | Not required for multi-agent foundation |

---

## 5. Backend and provider logic

### What should be reused

CLUI's provider implementations should be inspected for:

- CLI executable discovery;
- environment construction;
- process launch arguments;
- authentication/setup detection;
- model discovery/selection;
- stream parsing;
- event normalization;
- malformed-event handling;
- command/tool event interpretation;
- usage/token extraction;
- error normalization;
- resume/session identifiers;
- cancellation and process termination;
- tests for provider-specific edge cases.

### What should not be reused directly

Scarf should not introduce Opal's provider coordinator/runtime as a parallel authority. All imported provider logic should terminate at Scarf's `AgentBackend` boundary.

Conceptually:

`Claude CLI → ClaudeCodeBackend → AgentEvent → AgentCoordinator → AgentConversationController → Scarf UI`

Future Codex:

`Codex CLI → CodexBackend → AgentEvent → AgentCoordinator → AgentConversationController → Scarf UI`

Hermes remains:

`Hermes → HermesBackend → AgentEvent → AgentCoordinator → AgentConversationController/compatible Scarf UI`

---

## 6. Sessions, chat, and persistence

CLUI's session work is one of the highest-value sources for Scarf.

### Areas to compare

- session identifiers and provider/backend identity;
- create versus resume semantics;
- transcript persistence;
- restoring sessions after application restart;
- backend/model metadata persistence;
- tool call/result reconciliation;
- partial streamed assistant messages;
- reasoning blocks;
- command execution/output/result grouping;
- file modifications;
- usage and cost accumulation;
- stop reasons;
- recoverable versus terminal errors;
- migrations when persisted schemas evolve.

### Scarf requirement

Persisted data should remain backend-neutral wherever possible, with backend-specific metadata isolated in an extensible field/structure. A stored conversation must retain enough identity to know whether it belongs to Hermes, Claude Code, Codex, or another future backend.

### Lifecycle invariants

Scarf should eventually have contract tests proving:

- create → send → close;
- create → send → resume;
- session A → replace with B cleans up A;
- late A events cannot mutate B;
- closing a session rejects late events;
- two windows can independently consume routed events;
- application relaunch can restore supported sessions;
- failed resume produces recoverable state rather than corrupting history.

---

## 7. AI provider setup

CLUI's provider bootstrap/settings work should inform a new Scarf-native Agent/Provider settings architecture.

### Phase-one providers

1. Hermes
2. Claude Code

### Phase-two provider

3. Codex

### Later provider classes

- Gemini CLI/API;
- OpenAI Responses/API-based agents;
- Ollama/local models;
- Apple Foundation Models;
- other CLI or API agents.

### Recommended setup information per backend

Scarf should be able to surface:

- installed/not installed;
- executable path;
- executable version;
- authentication/setup status when safely detectable;
- selected/default model;
- supported capabilities;
- session/resume support;
- permissions support;
- skills/plugins/MCP support;
- tool/file/command support;
- diagnostics/test connection;
- project-specific default backend/model.

Secrets should not be copied from CLUI without a separate security/storage review.

---

## 8. Slash commands

CLUI's slash-command system is directly applicable but should be generalized.

### Proposed Scarf command registry

The command registry should merge commands from several sources:

1. Scarf-local application commands;
2. Hermes-supported commands;
3. Claude Code-supported commands;
4. future Codex commands;
5. backend-discovered commands where supported;
6. skills/plugins that intentionally expose commands.

### Command metadata

A command should be able to describe:

- name;
- aliases;
- description;
- backend scope;
- capability requirements;
- argument syntax;
- whether execution is local or forwarded to backend;
- availability for the active session;
- optional category/icon information for UI.

### UI

CLUI's `SlashHintList` behavior is useful, but the visual component should be rebuilt to match Scarf. Typing `/` should produce context-aware suggestions without turning the composer into an Opal-derived UI.

---

## 9. Skills, plugins, and MCP

This is another major adoption opportunity.

### Goal

Scarf should eventually provide one coherent management surface while respecting that different backends have different extension systems.

A unified model could classify an extension as:

- Hermes plugin;
- Hermes skill;
- Claude Code skill;
- MCP server;
- Scarf-local extension;
- future Codex capability/extension.

### Important constraint

"Unified UI" must not mean "pretend all systems are identical." The underlying provider/backend and configuration ownership must remain explicit.

### CLUI concepts worth adapting

- catalog/store separation;
- discovery and refresh;
- enablement state;
- configuration status;
- source/path metadata;
- MCP server definitions;
- settings integration;
- overlays/list presentation concepts;
- tests for catalog behavior.

### Scarf UI direction

Use Scarf-native settings/sidebar/chat affordances. Do not transplant CLUI's pill or overlay visual language.

---

## 10. Permissions

CLUI's `PermissionCoordinator` is a strong reference for separating permission lifecycle from transcript rendering.

### Proposed generic state machine

A backend-neutral permission request should carry enough information for:

- request ID;
- backend/session identity;
- action/tool category;
- human-readable description;
- structured details;
- available responses;
- scope/duration if supported;
- pending/resolved/cancelled state.

### Claude Code constraint

Scarf must not advertise Claude permission support until it can reliably receive, display, answer, and cancel real Claude Code permission requests. Capability flags should remain false until the entire round trip works and is tested.

### Hermes constraint

Do not regress existing Hermes permission behavior while introducing the generic coordinator.

---

## 11. UI adoption strategy

CLUI contains many useful interaction patterns, but Scarf should remain visually and structurally Scarf.

### Adopt behavior, not shell

Good candidates to reproduce in Scarf style:

- backend/provider status;
- model selection;
- slash-command hints;
- tool activity;
- permission requests;
- reasoning visibility;
- command execution/output;
- file-change summaries;
- diff review;
- session/history metadata;
- skills/plugins/MCP management;
- provider diagnostics;
- usage/cost information.

### Do not transplant

- Opal `AppModel` as Scarf's application state;
- Opal workspace shell;
- pill UI;
- Opal sidebar/navigation architecture;
- branding;
- parallel provider/session state ownership.

### Principle

If a CLUI component has valuable logic and UI tightly coupled together, split the logic into a Scarf service/model first and then build a Scarf-native SwiftUI surface on top of it.

---

## 12. Workspace, terminal, and file editing

CLUI has useful engineering around persistent terminal sessions and editable workspace tabs.

### High-value candidates

- terminal session persistence;
- agent/session-linked working directory;
- file navigation tied to active project;
- edit buffers;
- Markdown/code preview;
- diff/review surfaces;
- workspace restoration.

### Recommendation

Do not make these prerequisites for Claude Code support. They should be optional workspace enhancements after the transport/session architecture is stable.

---

## 13. Diff, edits, and agent artifacts

Scarf should consider a backend-neutral artifact model.

Potential artifact categories:

- created file;
- modified file;
- deleted file;
- patch/diff;
- command output;
- generated document;
- image/artifact;
- test result;
- link/reference.

A generic artifact layer would allow Hermes, Claude Code, and Codex to present changes consistently even when their raw protocols differ.

CLUI's diff/edit implementation should be mined for merge behavior, persistence, UI affordances, and tests.

---

## 14. Usage and cost accounting

CLUI has cost-accumulation tests and session model work that can inform Scarf.

Scarf should normalize where available:

- input tokens;
- output tokens;
- cached tokens;
- reasoning tokens if separately reported;
- provider-reported cost;
- model;
- turn/session totals.

Do not fabricate cost for providers that do not expose enough information. Provider-specific pricing calculation should remain separate from raw usage accounting.

---

## 15. Codex roadmap impact

CLUI significantly reduces the conceptual uncertainty around a future Scarf Codex backend because it already contains Codex provider and normalizer work plus tests.

When Claude Code is stable, Codex implementation should begin by comparing:

- CLUI Codex launch/configuration;
- event types;
- session/thread identity;
- tool calls;
- command/file events;
- usage events;
- error handling;
- cancellation;
- resume behavior;
- normalizer tests.

Then implement those semantics behind Scarf's existing `AgentBackend` contract rather than copying the Opal runtime.

The same backend contract tests used for Claude should be reused for Codex wherever behavior is supposed to be common.

---

## 16. Native agent loop and sub-agent architecture

CLUI's native agent loop, native tool registry, agent scripts, `SubAgentCoordinator`, and mailbox are important future references.

### Why not adopt them now

Hermes and Claude Code already contain agent runtimes. Adding another native loop now would blur responsibilities:

- Is Scarf the agent?
- Is Claude Code the agent?
- Is Hermes the agent?
- Which runtime owns tools and permissions?
- Which runtime owns context compaction and retries?

That ambiguity should be avoided during the backend conversion.

### Future use

Once multiple backends are stable, Scarf could evolve into an orchestrator that delegates work to multiple workers. At that point CLUI's sub-agent and mailbox concepts become highly relevant.

Potential future architecture:

`Scarf Orchestrator → Hermes worker / Claude Code worker / Codex worker / local worker`

That should be a separate milestone from provider integration.

---

## 17. Repo map and local project intelligence

CLUI's repository indexing/map system could be valuable for:

- fast symbol navigation;
- project summaries;
- context selection;
- showing relevant files before dispatching work;
- backend-independent project awareness.

It should be implemented as an optional Scarf workspace/context service rather than embedded in Claude Code transport.

Claude Code and Codex may already perform their own repository discovery, so Scarf's map should add UI/context value rather than duplicate expensive analysis without purpose.

---

## 18. Features to defer

The following CLUI features may be valuable products but should not distract from Scarf's current architecture work:

- browser engine/surface;
- ambient inspector;
- wake-word monitoring;
- iMessage remote service;
- automation system;
- headless screen capture;
- unrelated pill-specific interactions.

Each can be evaluated independently after multi-agent foundations are stable.

---

## 19. Recommended implementation sequence

### Phase 1 — finish Claude Code foundation

- [x] Make replacement-session cleanup GREEN.
- [x] Verify Hermes routing remains the default and resume-to-Hermes closes the previous backend session.
- [x] Add late-event-after-switch regression coverage.
- [x] Add late-event-after-close regression coverage, including unscoped legacy events.
- [ ] Harden Claude cancel/close/process cleanup with an app-target test. Process-manager replacement close already exists; this environment cannot compile the macOS target.
- [ ] Add Claude installation/version diagnostics.
- [ ] Audit resume/session identity fidelity beyond controller cleanup.
- [ ] Audit Claude event normalization against CLUI. The reference repository was not readable here.
- [ ] Audit capability flags. Permissions remain explicitly unsupported.

### Phase 2 — sessions and provider semantics

- [ ] Compare CLUI session persistence with Scarf conversation state.
- [x] Define persisted backend/session identity (`AgentConversationIdentity` / `AgentConversationIdentityStore`).
- [x] Wire production callers to HermesPathSet identity path (`makePersisting` / `AgentRuntime` / `startOrRestorePersistedSession`).
- [x] Persist/restore durable transcript slice (`AgentConversationTranscriptStore` — messages / toolResults / usage).
- [x] Deeper activity fields on the same durable snapshot (`toolCalls` / commands / files / reasoning).
- [x] Backend-history reconcile contract (`reconciling(withBackendHistory:)` — prefer Scarf when empty; merge by message id).
- [ ] Port useful tool-result merge semantics/tests (beyond Scarf-owned snapshot restore).
- [ ] Normalize usage accounting (beyond snapshot restore).
- [x] Add restart/resume identity tests (`restorePersistedSession`).
- [x] Add restart/resume transcript fidelity tests (`AgentConversationTranscriptFidelityTests`).
- [x] Add backend-history reconciliation tests (`AgentConversationBackendHistoryReconciliationTests`).
- [x] Wire `fetchConversationHistory` into restore (`AgentConversationBackendHistoryFetchTests`; Hermes/Claude return `[]` until a structured source exists).
- [ ] Implement first real Hermes/Claude structured history source behind `fetchConversationHistory`.
- [x] Decide cross-source turn matching when backend ids ≠ Scarf UUIDs (role + exact content after id pass).
- [ ] Define migration strategy for persisted session schema.

### Phase 3 — slash commands and extensions

- [ ] Define backend-aware Scarf command registry.
- [ ] Adapt CLUI slash routing concepts.
- [ ] Build Scarf-native slash hint UI.
- [ ] Define unified extension catalog model.
- [ ] Integrate Hermes skills/plugins without regression.
- [ ] Add Claude Code skills/MCP discovery where supported.
- [ ] Adapt CLUI MCP catalog concepts.

### Phase 4 — permissions

- [ ] Define generic permission request/response model.
- [ ] Adapt CLUI permission coordinator concepts.
- [ ] Preserve Hermes permission behavior.
- [ ] Implement Claude permission round trip.
- [ ] Enable Claude permission capability only after tests pass.

### Phase 5 — Scarf-native provider setup

- [ ] Build Agent/Provider settings section.
- [ ] Hermes status/configuration.
- [ ] Claude executable/version/auth diagnostics.
- [ ] Model selection where supported.
- [ ] Project-level backend/model defaults.
- [ ] Capability diagnostics.
- [ ] Test connection/health checks where meaningful.

### Phase 6 — artifacts and developer workflow UI

- [ ] Define generic agent artifact model.
- [ ] Normalize file changes.
- [ ] Add Scarf-native diff review.
- [ ] Evaluate terminal persistence.
- [ ] Evaluate file navigator/edit buffers.
- [ ] Associate workspace state with project/session.

### Phase 7 — Codex

- [ ] Deep-audit CLUI Codex provider and normalizer.
- [ ] Implement Scarf `CodexBackend`.
- [ ] Add install/auth/model diagnostics.
- [ ] Reuse lifecycle contract tests.
- [ ] Reuse burst/ordering tests.
- [ ] Reuse multi-window/session-isolation tests.
- [ ] Add Codex-specific normalization tests.

### Phase 8 — advanced capabilities

- [ ] Evaluate Gemini/OpenAI/Ollama/Foundation Models backends.
- [ ] Evaluate repo map service.
- [ ] Evaluate native tools.
- [ ] Evaluate Scarf-level orchestration.
- [ ] Evaluate sub-agents/mailbox only after worker backends are stable.

---

## 20. Testing strategy

Every adopted capability should use TDD and contract-level tests where practical.

### Backend contract tests

Common tests should verify:

- session creation;
- resume;
- send;
- cancellation;
- close;
- replacement cleanup;
- ordered streaming;
- no event loss under burst;
- session isolation;
- multi-window subscriptions;
- error mapping;
- capability accuracy.

### Feature tests

Additional suites should cover:

- slash command filtering/routing;
- extension catalog discovery;
- MCP configuration parsing;
- permission state transitions;
- persistence migrations;
- tool-result merging;
- usage accumulation;
- artifact/diff normalization;
- provider diagnostics.

### CI gates

The existing multi-agent branch gates remain mandatory:

1. Multi-Agent Tests
2. ScarfCore Compile Gate
3. macOS App Build

A feature is not considered integrated merely because the edited target compiles.

---

## 21. Architecture risks

### Risk: two competing control planes

**Avoid:** importing Opal's provider/session coordinator beside Scarf's coordinator.

**Mitigation:** all backend work terminates at `AgentBackend`.

### Risk: Hermes regression

**Avoid:** changing generic interfaces around Claude-specific assumptions.

**Mitigation:** default Hermes routing and Hermes regression coverage remain explicit.

### Risk: UI fragmentation

**Avoid:** adding Opal-style windows/pills/settings beside Scarf equivalents.

**Mitigation:** port behavior into Scarf-native surfaces.

### Risk: false capabilities

**Avoid:** displaying permissions, commands, resume, skills, or tools simply because another backend supports them.

**Mitigation:** backend capability gating and contract tests.

### Risk: duplicated agent behavior

**Avoid:** running Scarf native tools/agent loops on top of Claude Code without a defined orchestration model.

**Mitigation:** defer native control-plane work.

### Risk: session/process leaks

**Avoid:** switching sessions without deterministic cleanup.

**Mitigation:** lifecycle TDD, process ownership, replacement tests, late-event filtering.

### Risk: protocol event loss

**Avoid:** bounded buffers that silently discard deltas.

**Mitigation:** lossless routed delivery and burst regression tests.

---

## 22. Target end state

The desired Scarf architecture is not "Scarf plus a Claude tab" and not "Opal UI inside Scarf." It is a genuine multi-agent macOS client where the product experience remains Scarf while backends are interchangeable behind a stable contract.

A mature target should support:

- Hermes as a preserved first-class backend;
- Claude Code as a deeply integrated CLI backend;
- Codex as the next major CLI backend;
- backend-aware session creation/resume/history;
- multi-window isolation;
- provider/model setup and diagnostics;
- commands;
- skills/plugins/MCP;
- permissions;
- reasoning/tool/command/file event rendering;
- usage accounting;
- artifacts and diffs;
- optional workspace/terminal/repo intelligence;
- later provider expansion and multi-agent orchestration.

The key architectural rule is consistent throughout:

> **Scarf owns the product, routing contract, conversation state, and UI. Each agent/provider owns its backend-specific runtime behavior. CLUI supplies proven implementation ideas and code patterns, not a replacement application architecture.**

---

## 23. Immediate next action

Controller lifecycle cleanup for replacement, resume, and close is GREEN in `AgentConversationController` (see the commits listed in section 2). The adoption order below is unchanged. Next, run the three multi-agent CI gates on this branch, then continue the code-level CLUI audit in this order:

1. Claude provider/event normalization;
2. session models/persistence/tool merging;
3. slash commands;
4. skills/plugins/MCP;
5. permission coordinator;
6. provider bootstrap/settings;
7. Codex provider/normalizer.

This order maximizes reuse while keeping the critical Hermes + Claude Code foundation stable.
