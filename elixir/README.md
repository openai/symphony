# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) in the repository root.

> [!WARNING]
> Symphony is a low-key engineering preview.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates an isolated workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside that
   workspace
4. Sends workflow prompt to Codex

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so repo skills
can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings -> Security & access -> Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo and adjust it to fit your workflow.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Follow the instructions below to install the required runtime dependencies and start the service.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the HTTP observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for config, plus a Markdown body used as the Codex
session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
agent:
  max_concurrent_agents: 10
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project deps in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `env:LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory and values prefixed with `env:VAR` are
  replaced by `$VAR` before use. Example:
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell. Example:
 - If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
   the project deps in `hooks.after_create` before invoking `mise` later from other hooks.
 - `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `env:LINEAR_API_KEY`.
 - For env-backed values:
   - For path values, `~` is expanded to the home directory and values prefixed with `env:VAR` are
     replaced by `$VAR` before use.
   - For shell commands, values like `$VAR` are expanded by the launching shell.

  ```yaml
  workspace:
    root: "$SYMPHONY_WORKSPACE_ROOT"
  hooks:
    after_create: |
      git clone --depth 1 "$SOURCE_REPO_URL" .
      if command -v mise >/dev/null 2>&1; then
        cd elixir && mise trust && mise exec -- mix deps.get
      fi
  tracker:
    api_key: "$LINEAR_API_KEY"
  codex:
    command: "$CODEX_BIN app-server --model gpt-5.3-codex"
  ```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and scheduling are halted until fixed.
- `server.port` or CLI `--port` enables the optional HTTP dashboard and JSON API at `/`,
  `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Prerequisites

This project uses [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Testing

```bash
make all
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without killing
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.
