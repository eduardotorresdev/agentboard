# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app (SwiftUI, Swift Package Manager). Not one of the schema's standard values; no web, Windows, or mobile version is planned.

## Users

A solo developer running several AI coding agents (Claude Code, Codex, and similar) in parallel, typically one per branch or worktree, across multiple projects. Their job is to keep all those agents moving: notice which one is waiting on them, give it feedback, and return to the rest.

## Product Purpose

AgentBoard tells the developer who needs their feedback right now. Success means no agent sits idle waiting for input without the developer knowing, and the developer spends attention only where it is needed.

## Positioning

- **Attention first:** surfaces only what needs the developer now (an agent waiting for input, an error, a finished task) instead of showing every agent equally.
- **Spatial overview:** all agents and their terminals visible at once on a board, rather than hidden behind tabs or tmux panes.
- **Native and light:** a native macOS app with low CPU and memory use, unlike Electron-based neighbors such as Orca and Conductor.

## Operating Context

Runs alongside the developer's normal tools: git repositories on disk, branches and worktrees, terminal-based coding agents. Projects are git repositories the developer adds from disk; branches are read live from git.

## Capabilities and Constraints

- Local-first: all data is local (SQLite at `~/Library/Application Support/AgentBoard/agentboard.sqlite`, git on disk). No server, no account.
- Current state: sidebar of projects with their git worktrees; each worktree is a canvas of agent terminals. Agents connected by a line on the canvas can message each other: the app runs a local MCP server (127.0.0.1, one token per agent) whose `list_peers` and `send_message` tools only reach connected agents, and a message arrives typed into the recipient's terminal. The cards' programs run in a local companion process (`AgentBoardCore`, see `docs/core.md`), so they survive the app being relaunched or rebuilt. The attention signal is not built yet.
- Open: how "needs feedback" is detected per agent; how agents are launched or attached.
- Distribution: personal use for now, but not a fixed constraint; avoid decisions that would prevent wider distribution later.

## Reference Products

- **Orca** (orca.dev, Electron): primary reference for flows and behavior. When a flow is undefined, check how Orca does it first (for example, Add Project offers clone from git URL, create from scratch, or open an existing folder, with a suggested default location). Match its behavior unless a product principle here says otherwise; do not copy its visual style.

## Product Principles

1. Attention is the scarce resource: every surface should reduce the time to find the agent that needs the developer.
2. Quiet by default: agents that are fine stay out of the way; only state changes that require action get emphasis.
3. See everything at a glance: parallel work should be visible at once, not navigated to.
4. Stay light: the app must never be the thing slowing the machine down while agents run.
5. Local and owned: the developer's code and history never leave their machine.
