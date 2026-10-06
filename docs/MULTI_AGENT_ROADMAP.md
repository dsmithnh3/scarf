# Scarf Multi-Agent Architecture Roadmap

Updated: 2026-10-06
Branch: `cursor/session-lifecycle-hardening-89c0` (PR #1 → `feature/multi-agent-architecture`)
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
- Phase 3 backend-aware slash command registry model (`319f8610`) — `AgentSlashCommandDescriptor` + `AgentSlashCommandRegistry` in ScarfCore with backend scope, capability gating, first-wins dedupe, and name/alias prefix matching. Separate from `HermesSlashCommand` / transcript `AgentCommand`. No CLUI UI. Claude structured history remains blocked (no verified protocol source). CI run [37352437757](https://github.com/dsmithnh3/scarf/actions/runs/37352437757) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 3 Scarf-native command hints + catalog sources (`0a986fa2`) — `AgentSlashCommandCatalogs` (Scarf-local builtins, Hermes ACP static roster, empty Claude stub) + `AgentSlashCommandHint` / `hints(matching:backendID:capabilities:)`. No CLUI UI. Claude permissions stay unadvertised; Claude catalog empty until slash forwarding/discovery is verified. CI run [37356365121](https://github.com/dsmithnh3/scarf/actions/runs/37356365121) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 3 Scarf-native slash hint UI (`a8b14173`) — `AgentSlashHintPresenter` + `AgentChatViewModel` draft/hints wiring + `AgentSlashHintMenu` in the multi-agent composer (`AgentProjectChatView`). ScarfDesign tokens only (no CLUI/Opal). Hermes shows Scarf-local + ACP roster; Claude shows Scarf-local only (empty Claude catalog). CI run [37358088673](https://github.com/dsmithnh3/scarf/actions/runs/37358088673) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 3 live Hermes ACP command discovery into registry (`f60b2382`) — `AgentSlashCommandACPDiscovery` parses verified `available_commands_update` payloads; `AgentSlashCommandRegistry.mergingLiveHermesACPCommands` supersedes static Hermes fallbacks while keeping Scarf-local; `AgentEvent.availableCommandsUpdated` + state store; `HermesEventMapper` no longer drops the event; `AgentChatViewModel` rebuilds hint registry from discovery. Claude discovery stays empty. CI run [37360158348](https://github.com/dsmithnh3/scarf/actions/runs/37360158348) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 3 unified extension catalog model (`e047bd70`) — distinct kinds + Hermes fixture adapters; Claude/Scarf-local stubs empty. CI: Multi-Agent [37363578642](https://github.com/dsmithnh3/scarf/actions/runs/37363578642); Compile+macOS+Claude [37368212525](https://github.com/dsmithnh3/scarf/actions/runs/37368212525).
- Phase 3 Hermes loaders into catalog (read-only) (`ce4b7232`, tip `fda7fcc8`) — `AgentExtensionHermesLoaders` + `makeCatalog(fromHermesHome:)` wire plugin walk / skill scan / MCP config roster; Claude stub empty; tests in `AgentExtensionCatalogHermesLoaderTests`. Multi-Agent + Compile + macOS [37372242630](https://github.com/dsmithnh3/scarf/actions/runs/37372242630); Claude prior green [37368212525](https://github.com/dsmithnh3/scarf/actions/runs/37368212525).
- Phase 4 generic permission coordinator (model slice) (`261dc822`, test compile fix `db652228`) — `AgentPermissionRecord` + `AgentPermissionCoordinator` in ScarfCore (pending/answered/cancelled queue; Hermes `AgentPermissionRequest` round-trip; Claude `.permissions` still unadvertised). Tests: `AgentPermissionCoordinatorTests`. CI filter includes `AgentPermission`. CI run [37378030823](https://github.com/dsmithnh3/scarf/actions/runs/37378030823) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 4 wire permission coordinator into respond/cancel (`97bf9f63`) — `AgentConversationState` owns `permissionCoordinator`; `permissionRequested` enqueues (Hermes-mapped via `forEvent`); controller `respond`/`cancelPermission` prefer coordinator wire shape then update queue; legacy `permissionRequest` stays FIFO-presented. Claude `.permissions` still unadvertised; no Claude round trip / CLUI UI. Tests: `AgentConversationPermissionWiringTests` (+ state/coordinator coverage). CI run [37380432695](https://github.com/dsmithnh3/scarf/actions/runs/37380432695) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 2 GuardedJSONStore for identity + transcript sidecars (`ee56c946`) — `AgentConversationIdentityStore` and `AgentConversationTranscriptStore` conform to `GuardedSidecarStore` (`refuseForever`, `LocalTransport` default): inspect→mutate→publish RMW, one store per file, one-deep `.bak` on overwrite. Undecodable bytes refuse writes and are quarantined for the human. Claude `can_use_tool` wire encode/decode exists but live round trip remains blocked (`dontAsk`, respond throws, incoming `control_request` not consumed); `.permissions` stays unadvertised. Tests: corrupt-refuse + bak coverage in identity/transcript suites. CI run [37382269610](https://github.com/dsmithnh3/scarf/actions/runs/37382269610) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 4 Claude `can_use_tool` host round trip (wire + coordinator) (`16586ea9`) — `ClaudeCodeBackend` consumes incoming `control_request` / `can_use_tool` → `permissionRequested`; `respond`/`cancelPermission` send `ClaudeControlProtocol.encodePermissionResponse` allow/deny (cancel→deny). Channel stand-in + fake-process controller tests. Launch still `--permission-mode dontAsk`; `.permissions` stays unadvertised until a verified prompting mode matches the bridge. No CLUI UI. Tests: `ClaudeCodeBackendTests` permission suite. CI run [37383730860](https://github.com/dsmithnh3/scarf/actions/runs/37383730860) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 4 Claude host-prompting launch mode (`40c99134`) — replace `dontAsk` with verified Agent SDK host flags (`--permission-mode default` + `--permission-prompt-tool stdio`); advertise Claude `.permissions` behind an explicit launch+round-trip audit test. Hermes unchanged; no CLUI UI; no Codex. Tests: `ClaudeProcessConfigurationTests`, `ClaudeCodeBackendTests` host-prompting audit, ScarfCore capability defaults. CI filter also runs `ClaudeProcessConfigurationTests`. CI run [37385508997](https://github.com/dsmithnh3/scarf/actions/runs/37385508997) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 5 provider installation/version diagnostics (`34655028`, CI note `06d8ef1c`) — `AgentBackend.resolvedExecutablePath()` + `AgentBackendStatusSnapshot.executablePath`; Claude path/version/not-installed; Hermes local `HermesPathSet.resolveInstalledBinary` / `hermesBinaryIfInstalled` (missing → `.notInstalled`, no guessed path); Settings detail shows `version · path`. No auth/models UI; no Codex. Tests: `AgentProviderDiagnosticsTests`, `HermesPathSetInstalledBinaryTests`, Claude path asserts in `ClaudeCodeBackendTests`. CI filters include `AgentProviderDiagnosticsTests` + `HermesPathSetInstalled`. CI run [37387956415](https://github.com/dsmithnh3/scarf/actions/runs/37387956415) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 5 project default agent preference UI + models blocked (`d0f48cbe`, docs `5dca2fd6`) — `ProjectAgentPreferencePresenter` builds Hermes-always / Claude-when-available options from installation probes (detail = `version · path`); New Project + Project Chat Settings share it; Chat Settings saves via `ProjectStore.setPreferredAgentID` and hides Hermes model/auto-accept when Claude is selected. `HermesBackend.models()` / `ClaudeCodeBackend.models()` remain `[]` (locked by diagnostics tests) — no invented model lists or OAuth. No Codex. Tests: `ProjectAgentPreferencePresenterTests` (+ existing store suite). Multi-Agent filter already includes `ProjectAgentPreference`. CI run [37389266360](https://github.com/dsmithnh3/scarf/actions/runs/37389266360) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 4 Scarf-native permission card UI + models discovery blocked (`046d23e4`, docs cite) — Inspected Claude `ClaudeControlProtocol` (only `can_use_tool` / interrupt; no control-init model list) and Hermes catalog bridges (`ModelCatalogService` / `NousModelCatalogService` remain Rich Chat authoritative). Multi-agent `models()` stays `[]`. Shipped `AgentPermissionPresenter` + ScarfDesign `AgentPermissionCard` in `AgentProjectChatView` (respond/cancel via existing coordinator). No CLUI transplant; no Codex; no OAuth. Tests: `AgentPermissionPresenterTests`. Multi-Agent filter already includes `AgentPermission`. CI run [37390800959](https://github.com/dsmithnh3/scarf/actions/runs/37390800959) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 5 Hermes auth/credential health diagnostics (`90851309`, flake harden `e283bf08`) — `AgentAuthHealth` + `AgentBackend.authHealth()`; Hermes uses the verified chat preflight (`HermesFileService.hasAnyAICredential` → env / `.env` / `auth.json` / config); Claude stays `.notProbed` (no invented OAuth / credential-file parser); Settings detail appends `AI credentials detected` / `No AI credentials detected` only when probed. Models discovery still blocked (`models()` empty). No Codex. Tests: `AgentAuthHealthTests`, `AgentProviderDiagnosticsTests` auth suite. Multi-Agent filter includes `AgentAuth`. CI run [37393274059](https://github.com/dsmithnh3/scarf/actions/runs/37393274059) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.
- Phase 5 project preference auth-detail polish (`cd23e2c1`) — `ProjectAgentBackendProbe.authHealth` + preference option detail via `AgentAuthHealthFormatting` (same suffixes as Settings). New Project + Chat Settings map `statusSnapshots().authHealth`. Claude stays silent when `.notProbed`. Models still blocked; no OAuth. Tests: `ProjectAgentPreferencePresenterTests` auth suite. CI run [37394465278](https://github.com/dsmithnh3/scarf/actions/runs/37394465278) passed Multi-Agent Tests, ScarfCore Compile Gate, macOS App Build, and Claude Process Tests.

## Current TDD milestone

### Claude CLI bridges — verified sources found (implement next)

**Sources verified (research only; no feature code yet).** Auth/models/slash for Claude are no longer “unknown how” — primary docs + Agent SDK `@anthropic-ai/claude-agent-sdk@0.3.291` types confirm:

1. Reuse logged-in CLI via same-user spawn (Keychain / credential stores read by the CLI itself).
2. Probe with `claude auth status` and/or control `initialize` → non-secret `account` fields.
3. Discover `models` + `commands` from the same `initialize` success payload (`commands_changed` for live slash refresh).

Full cite: [`documents/research/2026-10-06-claude-cli-bridge-sources.md`](../documents/research/2026-10-06-claude-cli-bridge-sources.md). Memory: `multi-agent-claude-cli-bridge-sources`.

**Next code slice (not started):** implement ordered bridges — auth status → `ClaudeControlProtocol` initialize encode/decode → handshake cache → `models()` → slash catalog — still no OAuth UI, no Keychain/`.credentials.json` parsers, no hard-coded model lists. History stays Scarf transcripts until a version-pinned SDK-aligned path.

### Phase 5 — diagnostics / preferences / permissions UI (this PR) — COMPLETE

**GREEN for this PR's Phase 5 diagnostics/preferences slice + Phase 4 permission card UI.** Landed and CI-green on PR #1 (`cursor/session-lifecycle-hardening-89c0`). Claude auth/models/slash **implementation** still pending the next slice above (sources now verified).

| Slice | Tip commits | CI |
| --- | --- | --- |
| Provider install/path/version diagnostics | `34655028` | [37387956415](https://github.com/dsmithnh3/scarf/actions/runs/37387956415) |
| Project default agent preference UI | `d0f48cbe` | [37389266360](https://github.com/dsmithnh3/scarf/actions/runs/37389266360) |
| Scarf-native permission card UI (Phase 4) | `046d23e4` | [37390800959](https://github.com/dsmithnh3/scarf/actions/runs/37390800959) |
| Hermes credential-health diagnostics | `90851309` / `e283bf08` | [37393274059](https://github.com/dsmithnh3/scarf/actions/runs/37393274059) |
| Preference-row auth-detail polish | `cd23e2c1` | [37394465278](https://github.com/dsmithnh3/scarf/actions/runs/37394465278) |

**Still not implemented (sources verified for 2–4; do not invent alternate paths):**

1. Claude structured history — prefer Scarf transcripts; SDK `listSessions`/`getSessionMessages` later, version-pinned (see research doc).
2. Claude auth probe — stays `.notProbed` until `claude auth status` / initialize `account` is wired.
3. Claude slash-command discovery — catalog stays empty until initialize + `commands_changed`.
4. Multi-agent `models()` — stays `[]` until initialize `models` is wired; Hermes Rich Chat catalog remains authoritative meanwhile.
5. Codex adapter — roadmap Phase 4; no verified stub plan on this PR.
6. Native agent loops / sub-agents — Priority C only; Scarf is not an agent runtime (charter).

**Human decision point:** next implement slice is the verified Claude CLI bridges above; Codex/native-loop still needs an explicit roadmap plan.

### Phase 5 — project preference auth-detail polish (models blocked)

**GREEN for preference-row credential detail; models discovery BLOCKED.** After Hermes `authHealth()` landed in Agent Backends Settings, project default-agent option detail now appends the same truthful credential suffixes (`AI credentials detected` / `No AI credentials detected`) when a probe carries probed health. Claude preference detail stays silent for `.notProbed`. `HermesBackend.models()` / `ClaudeCodeBackend.models()` remain `[]` — Rich Chat `ModelCatalogService` stays authoritative; Claude slash discovery stays empty (no verified Claude command source). No OAuth. Hermes remains default. Tests: `ProjectAgentPreferencePresenterTests`. Commit `cd23e2c1`. CI green (all 4 gates including Claude Process Tests): [37394465278](https://github.com/dsmithnh3/scarf/actions/runs/37394465278).

### Phase 5 — Hermes auth/credential health diagnostics (Claude not probed; models blocked)

**GREEN for truthful Hermes credential health; Claude auth still not probed; models discovery BLOCKED.** Surface Hermes AI-credential presence in Agent Backends Settings via the same verified file/env checks as Rich Chat's missing-credentials banner (`hasAnyAICredential`). Claude remains `.notProbed` — do not invent Claude OAuth or `~/.claude` credential parsers. Multi-agent `models()` stays `[]`. No login/OAuth UI. Hermes remains default. Tests: `AgentAuthHealthTests`, `AgentProviderDiagnosticsTests` (auth + empty-models locks). Commits `90851309` / `e283bf08`. CI green (all 4 gates including Claude Process Tests): [37393274059](https://github.com/dsmithnh3/scarf/actions/runs/37393274059).

### Phase 4 — Scarf-native permission card UI (models discovery blocked)

**GREEN for multi-agent permission card; models discovery BLOCKED.** Verified: Claude has no control-initialize model listing in `ClaudeControlProtocol`; Hermes model catalogs stay outside `AgentBackend.models()`. Pure `AgentPermissionPresenter` maps coordinator FIFO head → `AgentPermissionPresentation`; `AgentChatViewModel` exposes it; `AgentPermissionCard` (ScarfDesign) sits above the multi-agent composer with option buttons → `respond` and Cancel → `cancelPermission`. Hermes remains default. No invented model lists, OAuth, or Claude-only chrome beyond coordinator fields. Tests: `AgentPermissionPresenterTests`. Commit `046d23e4`. CI green (all 4 gates including Claude Process Tests): [37390800959](https://github.com/dsmithnh3/scarf/actions/runs/37390800959).

### Phase 5 — project default agent preference (models blocked)

**GREEN for project-default backend clarity; models discovery BLOCKED.** Pure `ProjectAgentPreferencePresenter` + Chat Settings agent picker wired to existing install/path/version diagnostics. Hermes remains default; Claude selectable only when `.available`. Hermes model presets / auto-accept stay Hermes-only. Multi-agent `models()` stays empty until a verified discovery path exists (Hermes catalog UI remains authoritative; Claude awaits control-init discovery — do not hard-code). Auth/OAuth UI not invented. Permissions/lifecycle/diagnostics untouched. Commits `d0f48cbe` / `5dca2fd6`. CI green (all 4 gates including Claude Process Tests): [37389266360](https://github.com/dsmithnh3/scarf/actions/runs/37389266360).

### Phase 5 — provider installation/version diagnostics

**GREEN for installation/path/version diagnostics.** Scarf-native provider diagnostics expose executable path discovery, version when installed, and truthful not-installed (nil path + `.notInstalled`) for Claude Code and Hermes. Hermes launch path (`hermesBinary` fallback) unchanged; diagnostics use `hermesBinaryIfInstalled`. Auth/model/capability UI not invented. Hermes remains default; permissions/lifecycle untouched. Commits `34655028` / `06d8ef1c`. CI green (all 4 gates including Claude Process Tests): [37387956415](https://github.com/dsmithnh3/scarf/actions/runs/37387956415).

### Phase 4 — Claude host-prompting launch mode

**GREEN for verified host-prompting launch + truthful `.permissions`.** Launch uses `--permission-mode default` and `--permission-prompt-tool stdio` (Agent SDK `canUseTool` path; `dontAsk` never emits host prompts). Capability audit requires those flags plus receive/answer round trip before advertising `.permissions`. Hermes unchanged; no CLUI UI; no Codex. Commit `40c99134`. CI green (all 4 gates including Claude Process Tests): [37385508997](https://github.com/dsmithnh3/scarf/actions/runs/37385508997).

### Phase 4 — Claude can_use_tool host round trip

**GREEN for fake-process / channel stand-in round trip; superseded for launch gating by host-prompting slice above.** Incoming Claude `can_use_tool` control requests normalize to `AgentEvent.permissionRequested` (allow/deny options) and enqueue via existing conversation coordinator wiring. Controller `respond("allow")` / `cancelPermission` write the verified allow/deny `control_response` envelopes through `ClaudeProcessManager.sendRecord`. Commit `16586ea9`. CI green (all 4 gates including Claude Process Tests): [37383730860](https://github.com/dsmithnh3/scarf/actions/runs/37383730860).

### Phase 2 — GuardedJSONStore for identity + transcript sidecars

**GREEN for transport-safe RMW on Phase 2 persistence sidecars.** Both stores adopt `GuardedSidecarStore` / `GuardedJSONStore` with `damagePolicy = .refuseForever` (resume identity and durable transcripts must not silently rebuild from empty). Healthy save/load/remove and controller restore paths stay intact; corrupt JSON refuses overwrite and preserves bytes; overwrite refreshes `.bak`. Single store per file (no parallel writer). Hermes remains default. Claude `.permissions` stays unadvertised. Commit `ee56c946`. CI green (all 4 gates including Claude Process Tests): [37382269610](https://github.com/dsmithnh3/scarf/actions/runs/37382269610).

### Phase 4 — Claude permissions launch-mode gap

**RESOLVED by host-prompting launch slice** — see "Claude host-prompting launch mode" above. `dontAsk` replaced; `.permissions` advertised only with launch+round-trip audit.

### Phase 4 — wire permission coordinator into respond/cancel

**GREEN for Hermes-preserving conversation wiring.** `permissionRequested` events enqueue into `AgentConversationState.permissionCoordinator` (Hermes ACP numeric ids via `AgentPermissionRecord.forEvent` / `hermes(from:)`). Controller `respond` / `cancelPermission` forward the coordinator wire request to the backend, then answer/cancel the pending row and advance presented `permissionRequest`. Turn/session/user-turn clears drop only pending rows. Claude default capabilities still omit `.permissions`; no Claude `can_use_tool` round trip; no CLUI UI. Tests: `AgentConversationPermissionWiringTests`, `AgentConversationStateTests`, `AgentPermissionCoordinatorTests`. Commit `97bf9f63`. CI green (all 4 gates including Claude Process Tests): [37380432695](https://github.com/dsmithnh3/scarf/actions/runs/37380432695).

### Phase 4 — generic permission coordinator (model slice)

**GREEN for ScarfCore permission state machine (model only).** `AgentPermissionRecord` carries request id, backend id, session id, category, description, structured details, options, scope, and status. `AgentPermissionCoordinator` records pending requests with Rich Chat queue semantics (FIFO pending, id-keyed answer/cancel, duplicate-id refresh, clearPending keeps answered history). Hermes adapter `AgentPermissionRecord.hermes(from:sessionID:)` + `asAgentPermissionRequest` preserves numeric ACP ids for existing `HermesBackend.respond` / `cancelPermission`. Claude default capabilities still omit `.permissions`; no Claude round trip, no CLUI UI. Tests: `AgentPermissionCoordinatorTests`. Multi-Agent CI filter includes `AgentPermission`. Commits `261dc822` / `db652228`. CI green (all 4 gates including Claude Process Tests): [37378030823](https://github.com/dsmithnh3/scarf/actions/runs/37378030823).

### Phase 3 — Hermes loaders into extension catalog (read-only)

**GREEN for production factory wiring.** `AgentExtensionHermesLoaders.installed` + `AgentExtensionCatalogs.makeCatalog(fromHermesHome:)` / `makeCatalog(using:)` call existing read-only loaders: `HermesPluginDirectoryScanner`, `SkillsScanner` (with `skills.disabled`), and a lightweight `config.yaml` MCP roster via `HermesYAML`. Injectable loaders cover the test seam. Claude skill catalog stays empty; no CLUI UI; no permissions UI; no Codex. Tests: `AgentExtensionCatalogHermesLoaderTests`. Commits `ce4b7232` / tip `fda7fcc8`. CI: Multi-Agent + Compile + macOS green on [37372242630](https://github.com/dsmithnh3/scarf/actions/runs/37372242630) (Claude cancelled by concurrency; prior Claude green [37368212525](https://github.com/dsmithnh3/scarf/actions/runs/37368212525)).

### Phase 3 — live Hermes ACP slash command discovery

**GREEN for verified ACP → registry wiring.** `AgentSlashCommandACPDiscovery` mirrors `RichChatViewModel.parseACPCommands` (name trim, description, `input.hint`). Live Hermes ACP names supersede the static Hermes roster; Scarf-local stays first-wins; static Hermes names absent from the advertisement remain as resume fallbacks. `HermesEventMapper` emits `availableCommandsUpdated`; conversation state stores discovery (cleared on close); multi-agent composer hints rebuild from the merged registry. No Claude invention; permissions stay unadvertised. Tests: `AgentSlashCommandRegistryTests`, `AgentConversationStateTests`, `HermesEventMapperTests`. CI green: [37360158348](https://github.com/dsmithnh3/scarf/actions/runs/37360158348).

### Phase 3 — Scarf-native slash hint UI

**GREEN for multi-agent composer hint menu.** ViewModel-facing `AgentSlashHintPresenter` drives `AgentSlashCommandRegistry.hints` from composer draft text (same `/token` visibility rules as Hermes chat). `AgentChatViewModel` owns draft + presentation; `AgentSlashHintMenu` renders ScarfDesign rows above the multi-agent composer. Claude remains empty of Claude-specific commands; permissions stay unadvertised. Tests: `AgentSlashHintPresenterTests`. Live ACP discovery lands in the slice above. CI green: [37358088673](https://github.com/dsmithnh3/scarf/actions/runs/37358088673).

### Phase 3 — Scarf-native command hints + catalog sources

**GREEN for catalog sources + hint query API.** Extends the registry model with `AgentSlashCommandCatalogSource`, static catalogs (`scarfLocal`, `hermes(preferCompressSpelling:)`, empty `claudeCode` stub), `AgentSlashCommandCatalogs.makeRegistry`, and `AgentSlashCommandRegistry.hints(...)`. Hermes roster mirrors ACP always-available / non-interruptive truth (no CLI-only `clear`/`cost`/…). Claude catalog stays empty rather than inventing unverified commands. Composer UI lands in the slash-hint-UI slice above. Tests: `AgentSlashCommandRegistryTests`. Hermes remains the default route. Claude permissions stay unadvertised. Claude structured history remains blocked. CI green: [37356365121](https://github.com/dsmithnh3/scarf/actions/runs/37356365121).

### Phase 3 — backend-aware slash command registry (model slice)

**GREEN for the ScarfCore registry model.** `AgentSlashCommandDescriptor` + `AgentSlashCommandRegistry` merge Scarf-local and backend-scoped commands with capability gating, first-wins name dedupe, and case-insensitive name/alias prefix matching. Separate from `HermesSlashCommand` (ACP/project menu) and `AgentCommand` (shell activity). No CLUI UI transplant, no composer wiring yet. Tests: `AgentSlashCommandRegistryTests`. Hermes remains the default route. Claude permissions stay unadvertised. CI green: [37352437757](https://github.com/dsmithnh3/scarf/actions/runs/37352437757).

### Phase 2 — Claude structured history (blocked)

**BLOCKED pending a verified protocol or file source.** Inspected `ClaudeCodeBackend`, `ClaudeProcessConfiguration` (`--resume` / `--session-id` only), `ClaudeProcessManager` / `ProcessACPChannel` (stream-json send/receive), and `ClaudeStreamDecoder` (live event lines only). `fetchConversationHistory` correctly returns `[]` with an explicit comment that Scarf has no verified structured transcript API. Do **not** invent session-file parsers or advertise a history capability. Scarf durable transcripts remain preferred on Claude restore. GuardedJSONStore for identity/transcript sidecars is done (see above).

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
2. ~~Optional GuardedJSONStore adoption for identity/transcript sidecars (transport-safe RMW); keep a single store per file.~~ **Done** — both stores are `GuardedSidecarStore` with `refuseForever`.
3. ~~Unified extension catalog abstraction (Hermes plugins/skills vs Claude skills vs MCP as distinct sources) — model only, Scarf-native.~~ **Done** — `AgentExtensionDescriptor` / `AgentExtensionCatalog` / `AgentExtensionCatalogs` (distinct kinds; Hermes fixture adapters; Claude + Scarf-local stubs empty; no UI). Multi-Agent Tests [37363578642](https://github.com/dsmithnh3/scarf/actions/runs/37363578642); Compile+macOS+Claude [37368212525](https://github.com/dsmithnh3/scarf/actions/runs/37368212525).
4. ~~Integrate Hermes skills/plugins/MCP read-only into the catalog.~~ **Done** — `AgentExtensionHermesLoaders` + `makeCatalog(fromHermesHome:)` / `makeCatalog(using:)` call `HermesPluginDirectoryScanner`, `SkillsScanner`, and a lightweight config.yaml MCP roster; Claude skill catalog stays empty; no UI. Tests: `AgentExtensionCatalogHermesLoaderTests`. Commits `ce4b7232` / `fda7fcc8`. Multi-Agent+Compile+macOS [37372242630](https://github.com/dsmithnh3/scarf/actions/runs/37372242630); Claude prior [37368212525](https://github.com/dsmithnh3/scarf/actions/runs/37368212525).
5. ~~Phase 5 diagnostics / preferences / permissions UI on this PR~~ **GREEN / COMPLETE for PR #1** — install/path/version diagnostics, project-default preference (+ auth-detail polish), Hermes credential health, and Scarf-native permission card. Keep the CLUI adoption order unchanged for what remains: Claude history stays blocked; Codex remains later; native agent loops stay Priority C. Hermes catalog UI stays authoritative for Hermes models.
6. **Next code slices (verified sources — do not wait on CLUI):** Claude `auth status` → `AgentAuthHealth`, then control `initialize` handshake → `models()` + Claude slash catalog (+ `commands_changed`). Cite `documents/research/2026-10-06-claude-cli-bridge-sources.md`. Optional parallel: Scarf-native extensions browser on existing `AgentExtensionCatalog` (no CLUI UI).
7. **CLUI production-transfer audit (2026-10-06):** `macOS-CLUI-CC` still **unreadable** in this environment (Mac path missing; GitHub 404). Full ranked steal/adapt/skip + next slices: `documents/research/2026-10-06-clui-scarf-production-transfer.md` (and `/tmp/clui-scarf-transfer-audit.md`). Verdict: unread CLUI does **not** change auth/initialize/extensions/Hermes-catalog advice; event-normalizer delta stays deferred cite-only until the private repo is reachable. Do not transplant Opal UI.

## macOS-CLUI-CC adoption analysis

Reference repository: `dsmithnh3/macOS-CLUI-CC` (Opal architecture). **Still unreachable here** — see transfer audit above before treating prior-cited Opal paths as freshly verified.

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
- [x] GuardedJSONStore for identity/transcript sidecars (`ee56c946` — `GuardedSidecarStore` / `refuseForever`; one store per file).
- [ ] Claude structured history when a verified protocol/file source exists (**blocked** — no verified source found; do not invent).
- [x] Claude `can_use_tool` host round trip through coordinator (channel + fake-process tests; `.permissions` still unadvertised while `dontAsk`).
- [x] Verify Claude launch permission mode that prompts the host (`--permission-mode default` + `--permission-prompt-tool stdio`; advertise `.permissions` behind launch+round-trip audit).

### Phase 2 — adopt high-value CLUI patterns

- Compare/port provider normalization improvements.
- [x] Build backend-aware slash command registry + Scarf-native command hints + composer hint UI (`AgentSlashHintPresenter` / `AgentSlashHintMenu`).
- [x] Live Hermes ACP `available_commands_update` → registry (`AgentSlashCommandACPDiscovery` / `mergingLiveHermesACPCommands`).
- Add unified skills/plugins/MCP catalog abstractions while preserving Hermes.
- [x] Introduce generic permission state machine with truthful capability gating (`AgentPermissionCoordinator` model slice; Claude `.permissions` still unadvertised).
- [x] Wire permission coordinator into conversation respond/cancel (Hermes-preserving ACP ids; Claude round trip still deferred).
- Improve session persistence/tool-result/usage merge semantics.

### Phase 3 — Scarf-native setup and UX

- [x] Backend-aware slash command registry + Scarf-native hint query + multi-agent composer menu (`AgentSlashHintMenu`; no CLUI transplant).
- [x] Live Hermes ACP command discovery into the registry (static Hermes fallback retained).
- [x] Agent/provider settings for Hermes and Claude Code — installation/path/version + Hermes credential-health diagnostics in Settings and project preference detail (Claude auth still not probed; models blocked).
- [x] Project-level backend preference (Chat Settings + New Project via `ProjectAgentPreferencePresenter`, including verified Hermes auth-health detail); Hermes model presets remain Hermes-only.
- [x] Scarf-native permission card on the multi-agent composer (Phase 4 coordinator; Hermes default).
- [ ] Scarf-native backend indicator/switcher (product UX; not gated on blocked discovery — defer until a human prioritizes it over waiting on verified sources).
- [ ] Transcript rendering for reasoning, tool calls, commands, files, usage, permissions, and errors.
- [ ] Diff/artifact review surfaces adapted to Scarf's visual language.

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
