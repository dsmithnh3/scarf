# Multi-Agent Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a multi-agent backend architecture to Scarf while preserving Hermes behavior and implementing Claude Code as the first additional backend.

**Architecture:** Introduce generic agent-domain models, a backend protocol, registry, and coordinator. Wrap existing Hermes ACP behavior first, verify regressions, then add Claude Code using structured stream-json and gradually route shared UI through the generic layer.

**Tech Stack:** Swift, SwiftUI, Xcode project with file-system synchronized groups, Swift Testing/XCTest as already used by the repository, existing ACP/Hermes services, Foundation `Process`/pipes for Claude CLI.

**Spec:** `scarf/docs/superpowers/specs/2026-10-04-multi-agent-architecture-design.md`

## Global Constraints

- Hermes must remain a first-class, functional backend throughout the work.
- Existing projects without agent metadata must resolve to Hermes.
- Existing Hermes-specific UI and services remain available.
- Shared UI must depend on generic capabilities/events, not backend-name checks.
- Claude Code must use structured CLI I/O, not terminal scraping.
- New source files live under the existing synchronized `scarf` source root so no manual PBX file references are required.
- Refactor incrementally; do not rewrite unrelated SwiftUI or Hermes services.

## Review Focus

- Existing project/session data with no agent field must behave exactly as Hermes.
- A backend that is installed but lacks a capability must not expose unsupported UI/actions.
- Backend cancellation or process failure must not leave the coordinator/session in a permanently running state.
- Unknown/new event payloads from a backend must fail safely instead of crashing shared UI.
- Remote Hermes behavior must remain unchanged when local Claude support is added.

---

### Task 1: Generic Agent Domain Types

**Files:**
- Create: `scarf/scarf/Core/Agents/AgentID.swift`
- Create: `scarf/scarf/Core/Agents/AgentCapabilities.swift`
- Create: `scarf/scarf/Core/Agents/AgentModels.swift`
- Create: `scarf/scarf/Core/Agents/AgentEvent.swift`
- Test: `scarf/scarfTests/AgentDomainTests.swift`

**Interfaces:**
- Produces: `AgentID`, `AgentCapabilities`, `AgentModel`, `AgentSession`, `AgentSessionConfiguration`, `AgentMessage`, `AgentToolCall`, `AgentToolResult`, `AgentPermissionRequest`, `AgentUsage`, `AgentEvent`.

- [ ] Write tests for stable Hermes/Claude IDs, capability membership, Codable/Hashable round trips where applicable, and event payload equality.
- [ ] Confirm tests fail because the new types do not exist.
- [ ] Implement the minimal domain types as `Sendable` value types.
- [ ] Run targeted tests and confirm pass.
- [ ] Commit.

### Task 2: Backend Contract and Registry

**Files:**
- Create: `scarf/scarf/Core/Agents/AgentBackend.swift`
- Create: `scarf/scarf/Core/Agents/AgentRegistry.swift`
- Test: `scarf/scarfTests/AgentRegistryTests.swift`

**Interfaces:**
- Consumes: domain types from Task 1.
- Produces: `AgentBackend` protocol and `AgentRegistry` actor.

- [ ] Write a mock backend in tests.
- [ ] Test registration, duplicate replacement policy, lookup, available backend listing, and missing-backend behavior.
- [ ] Implement `AgentBackend` with installation detection, models, session create/resume, send, cancel, close, and event stream contract.
- [ ] Implement deterministic actor-backed registry.
- [ ] Run targeted tests and confirm pass.
- [ ] Commit.

### Task 3: Hermes Adapter Without UI Reroute

**Files:**
- Create: `scarf/scarf/Agents/Hermes/HermesBackend.swift`
- Create: `scarf/scarf/Agents/Hermes/HermesEventMapper.swift`
- Modify only existing Hermes/ACP files strictly as required to expose safe seams.
- Test: `scarf/scarfTests/HermesBackendTests.swift`

**Interfaces:**
- Consumes: `AgentBackend`, existing ACP/Hermes services.
- Produces: `HermesBackend` with a capability set representing current supported functionality.

- [ ] Capture current Hermes capability/runtime expectations in tests.
- [ ] Implement adapter by delegation, not duplicate process logic.
- [ ] Map ACP events to generic events while keeping existing ACP path intact.
- [ ] Run existing Hermes-related tests plus new adapter tests.
- [ ] Commit only if baseline behavior is preserved.

### Task 4: Coordinator and Hermes-First Routing

**Files:**
- Create: `scarf/scarf/Core/Agents/AgentCoordinator.swift`
- Test: `scarf/scarfTests/AgentCoordinatorTests.swift`
- Modify: current chat/session ownership seams only after tests identify exact integration points.

**Interfaces:**
- Consumes: `AgentRegistry`, `AgentBackend`.
- Produces: coordinator session lifecycle and normalized event forwarding.

- [ ] Test create/send/cancel/close lifecycle with mock backend.
- [ ] Test backend errors reset running state.
- [ ] Test Hermes is the fallback/default backend.
- [ ] Implement coordinator.
- [ ] Route one existing Hermes chat/session seam through coordinator.
- [ ] Run Hermes regression tests.
- [ ] Commit.

### Task 5: Backward-Compatible Project Agent Selection

**Files:**
- Modify: actual project persistence/model files identified during implementation.
- Test: project persistence tests near the existing project test suite.

**Interfaces:**
- Produces: preferred `AgentID` per project, default `.hermes` when absent.

- [ ] Add decoding/migration test for existing project data with no agent field.
- [ ] Add persistence round-trip test for explicit agent selection.
- [ ] Implement minimal schema change.
- [ ] Verify existing project tests and Hermes defaults.
- [ ] Commit.

### Task 6: Claude Installation and Process Layer

**Files:**
- Create: `scarf/scarf/Agents/ClaudeCode/ClaudeCodeBackend.swift`
- Create: `scarf/scarf/Agents/ClaudeCode/ClaudeProcessManager.swift`
- Create: `scarf/scarf/Agents/ClaudeCode/ClaudeConfiguration.swift`
- Test: `scarf/scarfTests/ClaudeProcessManagerTests.swift`

**Interfaces:**
- Produces: Claude installation detection and process lifecycle abstraction.

- [ ] Test executable discovery and missing-installation behavior with injectable resolver.
- [ ] Test command/argument construction and working directory selection without launching live Claude.
- [ ] Implement process manager using Foundation pipes/processes.
- [ ] Implement cancellation/termination state cleanup.
- [ ] Commit.

### Task 7: Claude Stream Decoder and Event Mapper

**Files:**
- Create: `scarf/scarf/Agents/ClaudeCode/ClaudeStreamDecoder.swift`
- Create: `scarf/scarf/Agents/ClaudeCode/ClaudeEventMapper.swift`
- Add: stable JSON fixtures under the test target if the repository's test conventions support fixtures.
- Test: `scarf/scarfTests/ClaudeStreamDecoderTests.swift`

**Interfaces:**
- Consumes: Claude newline-delimited structured output.
- Produces: normalized `AgentEvent` values.

- [ ] Add fixtures/tests for assistant text, tool use, command output, permission requests, usage, completion, errors, and unknown events.
- [ ] Implement decoder tolerant of additive unknown fields/events.
- [ ] Implement mapper.
- [ ] Confirm malformed/unknown payloads fail safely.
- [ ] Commit.

### Task 8: Claude Sessions and Backend Registration

**Files:**
- Create: `scarf/scarf/Agents/ClaudeCode/ClaudeSessionManager.swift`
- Modify: app composition/root service registration seam.
- Test: `scarf/scarfTests/ClaudeCodeBackendTests.swift`

**Interfaces:**
- Produces: complete `ClaudeCodeBackend` registered beside Hermes.

- [ ] Test session creation/resume/cancel contract with mocked process layer.
- [ ] Test Claude capabilities declaration.
- [ ] Register Claude only when appropriate while keeping Hermes always registered.
- [ ] Run registry/coordinator/Hermes tests.
- [ ] Commit.

### Task 9: Agent-Aware UI

**Files:**
- Modify: project/chat selection surfaces identified from current app structure.
- Create focused views only where necessary; avoid broad redesign.
- Test: existing UI/unit tests plus new state tests.

**Interfaces:**
- Consumes: registry/coordinator/capabilities.
- Produces: selectable Hermes/Claude backend while shared chat remains generic.

- [ ] Add agent selection with Hermes default.
- [ ] Capability-gate backend-specific actions.
- [ ] Keep Hermes-only navigation/configuration visible when Hermes is selected.
- [ ] Add Claude status/configuration surface.
- [ ] Run Hermes and Claude targeted tests.
- [ ] Commit.

### Task 10: Full Regression and Documentation

**Files:**
- Modify: `scarf/docs/MULTI_AGENT_ROADMAP.md` with implemented status.
- Add/update user-facing setup/troubleshooting docs.

- [ ] Run macOS build.
- [ ] Run existing test suite.
- [ ] Run Hermes regression checklist from the roadmap.
- [ ] Run Claude local smoke test when Claude CLI is available.
- [ ] Record known limitations precisely.
- [ ] Commit final documentation and open a reviewable PR only after regression gates pass.
