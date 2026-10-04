# Multi-Agent Architecture Design

## Purpose

Refactor Scarf 3.5.0 into a multi-agent application architecture while preserving Hermes as a first-class, fully functional backend. Claude Code is the first new backend. Future backends must fit the same contracts without requiring a redesign of shared chat, project, session, tool, or event models.

## Success Criteria

- Existing Hermes users can launch and use Scarf without migration friction.
- Hermes chat, sessions, memory, cron, MCP, gateway, proxy, remote execution, and configuration remain supported.
- Shared UI depends on generic agent-domain types instead of Claude/Hermes-specific payloads.
- Hermes and Claude Code both implement the same backend contract.
- Agent feature visibility is driven by capabilities, not hard-coded backend checks.
- Project storage remains agent-neutral and backward-compatible.
- Claude Code uses structured CLI events rather than terminal scraping.
- Future Codex/Gemini/ACP backends can be added without changing the shared domain architecture.

## Architecture

```text
SwiftUI Features
      |
AgentCoordinator
      |
AgentRegistry
      |
      +-- HermesBackend -> existing ACP/Hermes services
      +-- ClaudeCodeBackend -> Claude CLI stream-json
      +-- future backends
```

### Core domain

Create generic models under `scarf/scarf/Core/Agents/`:

- `AgentID`
- `AgentCapabilities`
- `AgentModel`
- `AgentSession`
- `AgentSessionConfiguration`
- `AgentMessage`
- `AgentToolCall`
- `AgentPermissionRequest`
- `AgentUsage`
- `AgentEvent`
- `AgentBackend`
- `AgentRegistry`
- `AgentCoordinator`

### Backend isolation

Backend implementations own protocol translation and process semantics. Generic views must never parse ACP or Claude stream-json directly.

### Hermes preservation strategy

Hermes remains the default backend for existing project/session state. The first Hermes adapter wraps current behavior instead of replacing the existing service stack. Hermes-exclusive services remain authoritative for memory, cron, gateway, proxy, and other Hermes-specific functionality.

### Capability model

Capabilities include at minimum:

- streaming
- reasoning
- toolCalls
- permissions
- sessions
- resume
- mcp
- skills
- hooks
- subagents
- usage
- fileChanges
- shellCommands
- memory
- cron
- gateway
- proxy
- remoteExecution

Shared UI asks capabilities whether a feature is available. Backend-specific management screens remain backend-specific.

### Claude Code transport

Claude Code is launched as a child process in the selected project working directory using structured input/output. The backend normalizes Claude events into `AgentEvent` and supports installation detection, lifecycle, cancellation, session identity/resume where supported, tool activity, permissions, command output, file changes, and usage metadata made available by Claude.

### Project model

Projects remain independent from agents. Existing projects default to Hermes. A preferred-agent field is introduced backward-compatibly. The schema should not prevent multiple agent workspaces/sessions per project later.

## Migration Strategy

1. Establish Scarf 3.5.0 build/test baseline.
2. Introduce generic domain types with no runtime behavior change.
3. Add `HermesBackend` around existing ACP/Hermes behavior.
4. Route Hermes through `AgentCoordinator` and confirm no visible regression.
5. Add backward-compatible project agent selection.
6. Implement Claude Code backend and normalize events.
7. Add UI selector/status/configuration surfaces.
8. Expand shared UI abstraction incrementally.
9. Evaluate remote Claude support only after local Hermes + Claude are stable.

## Hermes Invariants

The following behavior must remain valid through every migration phase:

- Existing Hermes configuration continues to load.
- Hermes local chat continues to launch and stream.
- Hermes tool/permission/session behavior remains functional.
- Existing remote/SSH Hermes behavior remains functional.
- Hermes memory, cron, MCP, gateway, proxy, and configuration surfaces remain available.
- Existing projects without an agent field resolve to Hermes.
- Existing Hermes-specific files/services are not deleted merely because generic abstractions exist.

## Testing Strategy

- Add unit tests for generic identity, capability, registry, event, and coordinator behavior.
- Add mock backend tests before coordinator integration.
- Add Hermes adapter seam tests before rerouting UI/runtime paths.
- Preserve existing Scarf tests as regression suite.
- Add Claude decoder tests using stable fixture payloads before connecting live process execution.
- Run Hermes regression gates after every phase that touches runtime routing or UI.

## Non-Goals for Initial Release

- Autonomous agent-to-agent orchestration.
- Codex/Gemini implementation.
- Replacing Hermes-exclusive services with generic approximations.
- Removing Hermes UI.
- Owning or migrating external CLI credentials.
- Large unrelated SwiftUI redesigns.
