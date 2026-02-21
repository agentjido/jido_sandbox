# Jido.Workspace

[![Hex.pm](https://img.shields.io/hexpm/v/jido_workspace.svg)](https://hex.pm/packages/jido_workspace)
[![Documentation](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/jido_workspace)

Unified artifact workspace for agent sessions, built on `jido_shell` + `jido_vfs`.

## Package Boundary

`jido_workspace` is a strict workspace library. It owns:

- Workspace state and artifact lifecycle
- Optional shell-session convenience bound to workspace id
- Snapshot/restore of workspace artifacts

It does **not** own:

- Provider orchestration
- Harness runtime policy/bootstrap
- Sprite workflow orchestration

## Installation

Add `jido_workspace` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_workspace, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Create a new workspace (in-memory VFS mounted at /)
workspace = Jido.Workspace.new()

# Work with artifacts
{:ok, workspace} = Jido.Workspace.write(workspace, "/hello.txt", "Hello, World!")
{:ok, "Hello, World!"} = Jido.Workspace.read(workspace, "/hello.txt")
{:ok, ["hello.txt"]} = Jido.Workspace.list(workspace, "/")

# Snapshot and restore
{:ok, snapshot_id, workspace} = Jido.Workspace.snapshot(workspace)
{:ok, workspace} = Jido.Workspace.delete(workspace, "/hello.txt")
{:ok, workspace} = Jido.Workspace.restore(workspace, snapshot_id)

# Run a shell command in the workspace
{:ok, output, workspace} = Jido.Workspace.run(workspace, "pwd")

# Cleanup
{:ok, workspace} = Jido.Workspace.close(workspace)
```

## Why Jido.Workspace

- Unifies artifact lifecycle for an agent session
- Uses `Jido.Shell.VFS` for mount/routing
- Uses `Jido.VFS` adapter ecosystem for storage backends
- Provides a single state struct for files + session context

## Workspace vs Harness Exec

- Use `Jido.Workspace` when you need app-level stateful workspace operations:
: artifact files, snapshots, and optional shell command execution tied to that workspace.
- Use `Jido.Harness.Exec.Workspace` when you need provider-runtime orchestration primitives:
: provisioning/validation/bootstrap around coding-agent execution.

## Documentation

See [HexDocs](https://hexdocs.pm/jido_workspace) for full documentation.

## License

Apache-2.0

## Testing Paths

- Core workspace suite: `mix test`
- Full quality gate: `mix quality`
- Keep scenario-heavy testing in `jido_workspace_scenarios`
