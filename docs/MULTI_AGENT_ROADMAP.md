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
- `cfdc588` — RED TDD regression requiring replacement sessions to close the prior active session. CI run 37307337357 failed only the new expected lifecycle assertion while the macOS build and compile gate passed.
- `3d7c5c81` — GREEN. `AgentConversationController.startSession` closes the previous active session before creating the replacement. A failed close leaves that session active and does not create another one. After a successful close, the controller drops the outgoing session before creation, so a later creation failure claims neither session.
- `bbbc5e11` — regression: a scoped late event from the replaced session cannot modify the replacement. Session-id filtering already enforced this; the test locks it.
- `83cf7bfa` — resume closes the previous session only when the resumed identity differs (other session id, other backend, or an id minted by resume). Resuming the active identity does not close it. A failed close keeps the previous session active and releases the resumed session.
- `e5de0682` — after `close()`, scoped and legacy unscoped events are ignored. A late `sessionStarted` cannot resurrect the conversation. Active legacy backends still receive unscoped events.
- `568f1366` — rapid sequential replacements close each outgoing session and leave only the last one active.
- `8daeeb59` — CI run [37313877576](https://github.com/dsmithnh3/scarf/actions/runs/37313877576) passed Multi-Agent Tests, ScarfCore Compile Gate, and macOS App Build.
- `a1234f23` — already-green lock for Claude process cleanup. `conversationCloseTerminatesClaudeProcess` proves conversation close terminates the Claude process. `turnCancelInterruptsClaudeWithoutTerminatingProcess` proves turn cancel delivers a control interrupt and leaves that process running until a later close. `ClaudeCodeBackend.close` already cancelled the stream tasks and closed the process manager, and `cancel` already sent the interrupt, so no production code changed. Dropping `manager.close()` makes the close test fail with `processStillRunning`.
- `9389a29a` — Claude Process Tests CI job. First run failed compiling scarfTests because `try #require(throwingCall)` does not compile under Xcode 26.6; follow-up fixes the Claude control protocol tests so the host-app suite can build.
- `2513c302` — Claude divergent system-init session ids are aligned to Scarf's runtime session id (`claudeReportedSessionID` metadata). Installation/resume not-installed paths and resume-of-active identity covered.
- `9a15aaa1` — failed create/resume and unexpected Claude process exit surface through `AgentConversationState.error`. CI run [37327549215](https://github.com/dsmithnh3/scarf/actions/runs/37327549215) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests (12/12 suite cases).
- Phase 2 persistence foundation (`67b3ac44`) — `AgentConversationIdentity` + file-backed `AgentConversationIdentityStore` persist `conversationID → (backendID, sessionID)`. `AgentConversationController` optionally wires a store: start/resume save, close removes, `restorePersistedSession()` reloads across a new store/controller instance. Not an extension of Hermes `SessionProjectMap`. Live transcript state stays in `AgentConversationState`. CI run [37329860714](https://github.com/dsmithnh3/scarf/actions/runs/37329860714) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 2 production wiring (`5d9d21ea`) — `AgentConversationController.makePersisting` + `startOrRestorePersistedSession` inject `AgentConversationIdentityStore` at the `HermesPathSet.agentConversationIdentities` path (`{home}/scarf/agent_conversation_identities.json`). `AgentRuntime.conversationController(for:)` uses project id as conversation key; `AgentChatViewModel.start()` prefers restore then create. GuardedJSONStore adoption remains an optional follow-up (store still uses atomic file writes; no parallel store). CI run [37332041624](https://github.com/dsmithnh3/scarf/actions/runs/37332041624) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 2 transcript fidelity (first durable slice) (`f7edf853`) — `AgentConversationTranscript` + file-backed `AgentConversationTranscriptStore` persist `conversationID → (messages, toolResults, usage)`. Controller saves after send/event reduction, clears on start/close, and `restorePersistedSession()` rehydrates into `AgentConversationState` after identity resume. Production path: `HermesPathSet.agentConversationTranscripts` / `makePersisting`. Live drafts/permissions/toolCalls remain reducer-only. CI run [37334461764](https://github.com/dsmithnh3/scarf/actions/runs/37334461764) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests. Hermes remains default; Claude permissions stay unadvertised.
- Phase 2 deeper resume fidelity (activity fields) (`2defeb07`) — extend the same `AgentConversationTranscript` snapshot with `toolCalls`, `commands` / `commandOutput` / `commandResults`, `fileChanges`, and `reasoningBlocks`. `restoreDurableTranscript` rehydrates those fields and aligns tool/command status from matching result ids. Legacy first-slice JSON still decodes (missing activity keys → empty). Drafts/permissions remain reducer-only. Backend-history reconciliation and GuardedJSONStore remain deferred. CI run [37336556378](https://github.com/dsmithnh3/scarf/actions/runs/37336556378) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests. Hermes remains default; Claude permissions stay unadvertised.
- Phase 2 backend-history reconciliation (smallest contract) (`7a671773`) — pure `AgentConversationTranscript.reconciling(withBackendHistory:)` plus `restorePersistedSession(backendHistory:)`. Empty backend prefers Scarf (messages + activity); empty Scarf messages adopt backend; both non-empty merge by `AgentMessage.id` (Scarf wins collisions, backend-only ids append, Scarf activity retained). Superseded for cross-source ids by role+content matching. GuardedJSONStore remains deferred. CI run [37338697417](https://github.com/dsmithnh3/scarf/actions/runs/37338697417) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests. Hermes remains default; Claude permissions stay unadvertised.
- Phase 2 backend-history fetch wiring (`e1af06be`) — `AgentBackend.fetchConversationHistory(for:)` (default `[]`) + `AgentCoordinator` route. `restorePersistedSession(backendHistory:)` now defaults to `nil` and fetches after identity resume; explicit arrays remain test overrides. Hermes ACP `session/load` only replays streaming chunks; Claude `--resume` has no structured history API yet — both backends return `[]` without advertising a history capability. Fake-backend tests prove fetch + reconcile. GuardedJSONStore / content-role matching remain deferred. CI run [37340873436](https://github.com/dsmithnh3/scarf/actions/runs/37340873436) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 2 Hermes state.db history source (first slice) (`7c240430`) — `HermesAgentConversationHistory` read-only maps `HermesDataService.fetchMessages` rows to `[AgentMessage]` with deterministic ids from `(sessionID, Hermes row id)`. `HermesBackend.fetchConversationHistory` uses this path; Claude still returns `[]`. No history capability advertised. CI run [37342752724](https://github.com/dsmithnh3/scarf/actions/runs/37342752724) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests. Hermes remains default; Claude permissions stay unadvertised.
- Phase 2 cross-source turn matching (role + content) (`1a6f6512`) — `AgentConversationTranscript.reconciling(withBackendHistory:)` keeps merge-by-id as the first pass, then matches unmatched backend messages by **role + exact content** (greedy against unmatched Scarf turns). Scarf ids/content/activity win on match; truly distinct backend messages still append. Closes the Hermes-deterministic-id vs Scarf-UUID duplicate gap without a second conversation state system. CI run [37347757216](https://github.com/dsmithnh3/scarf/actions/runs/37347757216) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests. Hermes remains default; Claude permissions stay unadvertised.
- Phase 2 fixture `state.db` end-to-end restore (`95f60cd0`) — `AgentConversationHermesStateDBRestoreTests` builds a throwaway Hermes home/`state.db`, persists Scarf identity + durable transcript (including activity), and drives `restorePersistedSession()` through `HermesAgentConversationHistory.fetchMessages` so role+content matching keeps Scarf UUIDs/activity while appending Hermes-only turns. No production glue. CI run [37349277921](https://github.com/dsmithnh3/scarf/actions/runs/37349277921) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests. Hermes remains default; Claude permissions stay unadvertised.

## Current TDD milestone

### Phase 3 — backend-aware slash command registry (model slice)

**IN PROGRESS — smallest ScarfCore model.** `AgentSlashCommandDescriptor` + `AgentSlashCommandRegistry` merge Scarf-local and backend-scoped commands with capability gating, first-wins name dedupe, and case-insensitive name/alias prefix matching. Separate from `HermesSlashCommand` (ACP/project menu) and `AgentCommand` (shell activity). No CLUI UI transplant, no composer wiring yet. Tests: `AgentSlashCommandRegistryTests`. Hermes remains the default route. Claude permissions stay unadvertised.

### Phase 2 — Claude structured history (blocked)

**BLOCKED pending a verified protocol or file source.** Inspected `ClaudeCodeBackend`, `ClaudeProcessConfiguration` (`--resume` / `--session-id` only), `ClaudeProcessManager` / `ProcessACPChannel` (stream-json send/receive), and `ClaudeStreamDecoder` (live event lines only). `fetchConversationHistory` correctly returns `[]` with an explicit comment that Scarf has no verified structured transcript API. Do **not** invent session-file parsers or advertise a history capability. Scarf durable transcripts remain preferred on Claude restore. Optional alternative later: GuardedJSONStore for identity/transcript sidecars.

### Phase 2 — fixture state.db end-to-end restore

**GREEN for `restorePersistedSession` through a throwaway Hermes `state.db`.** Identity restore + `HermesAgentConversationHistory` fetch + role+content reconcile + Scarf durable activity retention are locked by `AgentConversationHermesStateDBRestoreTests` (temp SQLite fixture; no shipped binary). No production code change. Hermes remains the default route. Claude permission capability stays unset. Claude structured history blocked (see above). CI green: [37349277921](https://github.com/dsmithnh3/scarf/actions/runs/37349277921) (docs cite [37350728319](https://github.com/dsmithnh3/scarf/actions/runs/37350728319)).

### Phase 2 — cross-source turn matching (role + content)

**GREEN for role+content matching after the id merge pass.** Same role+content turns from Scarf UUIDs and Hermes-style ids no longer duplicate; Scarf activity is retained; distinct messages still append. Tests: `AgentConversationBackendHistoryReconciliationTests` (pure + restore harness). Hermes remains the default route. Claude permission capability stays unset. Claude structured history still deferred until a verified protocol source exists. CI green: [37347757216](https://github.com/dsmithnh3/scarf/actions/runs/37347757216).

### Phase 2 — Hermes structured history source (state.db)

**GREEN for read-only Hermes `state.db` → `[AgentMessage]` behind `HermesBackend.fetchConversationHistory`.** Uses existing C3 read-only SQL; does not start ACP or change resume/lifecycle. Deterministic message ids are reconciled with Scarf UUIDs via role+content matching (slice above). Claude still returns `[]`. No history capability flag. CI green: [37342752724](https://github.com/dsmithnh3/scarf/actions/runs/37342752724). Fixture e2e restore covered above; Claude protocol source remains **blocked** (see Current TDD milestone).

### Phase 2 — backend-history fetch wiring

**GREEN for controller/coordinator history fetch into reconcile.** Production restore (`restorePersistedSession()` / `startOrRestorePersistedSession`) fetches `[AgentMessage]` from the resumed backend and passes it into the existing reconcile contract. Hermes and Claude return `[]` (no structured source yet; no capability advertised), so Scarf durable transcripts remain preferred. Fake backends in `AgentConversationBackendHistoryFetchTests` prove non-empty fetch merges. Cross-source id mapping remains open. Optional GuardedJSONStore adoption remains a later follow-up. CI green: [37340873436](https://github.com/dsmithnh3/scarf/actions/runs/37340873436).

Hermes remains the default route. Claude permission capability stays unset.

### Phase 2 — backend-history reconciliation (smallest contract)

**GREEN for the Scarf↔backend message reconcile contract.** Callers may pass optional backend history into `restorePersistedSession(backendHistory:)`; explicit arrays override fetch. Superseded for production wiring by the fetch slice above. Cross-source id mapping (Hermes state.db / ACP replay without Scarf UUIDs) remains an open product decision. Optional GuardedJSONStore adoption remains a later follow-up. CI green: [37338697417](https://github.com/dsmithnh3/scarf/actions/runs/37338697417).

Hermes remains the default route. Claude permission capability stays unset.

### Phase 2 — deeper resume fidelity (activity fields)

**GREEN for durable activity restore.** Same reload boundary as identity/transcript: save → new store/controller → restore identity **and** rehydrate messages plus toolCalls, toolResults, commands/output/results, fileChanges, reasoningBlocks, and usage. Status merge follows live reducer id semantics. `startSession` still clears prior transcript; `close` removes it. Superseded for reconcile by the backend-history contract above; GuardedJSONStore remains deferred. CI green: [37336556378](https://github.com/dsmithnh3/scarf/actions/runs/37336556378).

Hermes remains the default route. Claude permission capability stays unset.

### Phase 2 — transcript / resume fidelity (first durable slice)

**GREEN for durable message/tool-result/usage restore.** Temp-directory reload boundary proves save → new store/controller → restore identity **and** rehydrate transcript fields. `startSession` clears prior transcript for that conversation; `close` removes it. Superseded for activity fields by the deeper resume-fidelity slice above; backend-history reconciliation remains deferred. Optional GuardedJSONStore adoption remains a later follow-up. CI green: [37334461764](https://github.com/dsmithnh3/scarf/actions/runs/37334461764).

Hermes remains the default route. Claude permission capability stays unset.

### Phase 2 — persist backend id + session id

**GREEN for identity persistence + production wiring.** Temp-directory reload boundary proves save → new store instance → load. Controller start/resume persist; close clears; restore resumes the stored backend+session without a second conversation state system. App bootstrap factory `makePersisting(hermesHome:)` writes to the HermesPathSet production location; `AgentRuntime` / `AgentChatViewModel` consume that seam. CI green: [37332041624](https://github.com/dsmithnh3/scarf/actions/runs/37332041624).

Hermes remains the default route. Claude permission capability stays unset.

### Replacement and close lifecycle

**GREEN for the controller lifecycle covered above.** `replacementSessionClosesPrevious` now passes because the previous active session is closed before the replacement is created.

Failure semantics:

- `startSession`: close the outgoing session before creating the next one. Close failure keeps the outgoing session and does not create a replacement. Successful close followed by a failed create claims neither session.
- `resumeSession`: resume first, then close the outgoing session only if the effective identity changed. Close failure keeps the outgoing session and attempts to release the resumed session.
- `close()`: clear both the active session and the active backend id. Later events, including unscoped legacy events, do not mutate state.

Hermes remains the default route. Claude permission capability stays unset.

Claude process cleanup is locked without a production change. Conversation close terminates the Claude process. Turn cancel sends a control interrupt and does not terminate that process.

**CI gate:** `Claude Process Tests` runs `xcodebuild test -only-testing:scarfTests/ClaudeCodeBackendTests` on macOS. scarfTests compile required fixing `#require` usage around throwing Claude control decoders under Xcode 26.6.

**Identity:** Claude `system` init that reports a divergent `session_id` is aligned to Scarf's runtime session id; the reported id is kept in `metadata["claudeReportedSessionID"]` so scoped routing cannot be orphaned.

**Process failures:** Failed create/resume now write `conversation.start-failed` / `conversation.resume-failed` into the existing `AgentConversationState.error` slot. Unexpected process exit continues to emit `claude.process-ended` through the same error path (locked by controller + Claude process tests). macOS-CLUI-CC remains unreadable in this environment, so event-normalization ports are deferred.

## Next lifecycle milestones

1. **Claude structured history — blocked** until a verified protocol or file source exists (do not invent parsers; keep `fetchConversationHistory` as `[]`).
2. Backend-aware slash command registry model → Scarf-native hints (no CLUI UI transplant); wire sources after the model is green.
3. Optional GuardedJSONStore adoption for identity/transcript sidecars (transport-safe RMW); keep a single store per file.
4. Keep the CLUI adoption order unchanged: Claude history stays blocked; proceed with command registry / skills/MCP / permissions only behind truthful capabilities; Codex remains later.

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

- [x] GREEN replacement-session cleanup (`3d7c5c81`, test `replacementSessionClosesPrevious`).
- [x] Late scoped events after a switch (`bbbc5e11`).
- [x] Late scoped and unscoped events after close (`e5de0682`).
- [x] Resume replacement cleanup, including a minted session id and a backend switch (`83cf7bfa`).
- [x] Rapid sequential replacements (`568f1366`).
- [x] Claude close/cancel process release (`a1234f23`). Behavior was already present. Close terminates the process (`conversationCloseTerminatesClaudeProcess`). Cancel interrupts the turn and leaves the process alive (`turnCancelInterruptsClaudeWithoutTerminatingProcess`).
- [x] Claude Process Tests CI gate (`9389a29a` + scarfTests compile fixes). `xcodebuild test -only-testing:scarfTests/ClaudeCodeBackendTests` on macOS.
- [x] Claude Code installation/version diagnostics gaps: unavailable probe, create/resume not-installed, home PATH discovery, missing → nil.
- [x] Session resume identity: Scarf routing id wins when Claude system init reports a divergent `session_id`; resume-of-active keeps identity.
- [x] Capability contract audit. Claude permissions remain unimplemented and unadvertised (respond + cancelPermission).
- [x] Process failure surfacing via existing `AgentConversationState.error` (failed create/resume + unexpected exit).
- [x] Persist backend id + session id (`AgentConversationIdentityStore` + controller restore seam).
- [x] Wire production callers (`AgentRuntime` / `makePersisting` / `startOrRestorePersistedSession` → `HermesPathSet.agentConversationIdentities`).
- [x] Session resume/history fidelity first durable slice (`AgentConversationTranscriptStore` — messages / toolResults / usage across reload).
- [x] Deeper transcript activity fidelity (`toolCalls` / commands / fileChanges / reasoningBlocks on the same durable snapshot; result-id status merge).
- [x] Backend-history reconciliation smallest contract (`reconciling(withBackendHistory:)` — empty-backend prefers Scarf; id merge; Scarf activity retained).
- [x] Cross-source turn matching (role + exact content after id pass; Scarf wins; activity retained).
- [x] Fixture `state.db` end-to-end restore through `restorePersistedSession` (`AgentConversationHermesStateDBRestoreTests`).
- [ ] Optional GuardedJSONStore adoption for the identity/transcript sidecars (single store per file; no parallel writer).
- [ ] Claude structured history when a verified protocol/file source exists (**blocked** — no verified source found; do not invent).

### Phase 2 — adopt high-value CLUI patterns

- Compare/port provider normalization improvements.
- Build backend-aware slash command registry + Scarf-native command hints (model slice in progress under Phase 3 checklist / `AgentSlashCommandRegistry`).
- Add unified skills/plugins/MCP catalog abstractions while preserving Hermes.
- Introduce generic permission state machine with truthful capability gating.
- Improve session persistence/tool-result/usage merge semantics.

### Phase 3 — Scarf-native setup and UX

- Backend-aware slash command registry model (`AgentSlashCommandRegistry`) then Scarf-native hints (no CLUI UI transplant).
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
