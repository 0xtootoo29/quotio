# Quotio Claude Relay Fork

This repository is a personal fork of [nguyenphutrong/quotio](https://github.com/nguyenphutrong/quotio), focused on one practical goal:

- make Quotio work smoothly with a Claude Code relay API (middle proxy API)
- keep the setup simple for daily usage in Claude Code

Repository: [0xtootoo29/quotio](https://github.com/0xtootoo29/quotio)

## Why This Fork Exists

The upstream Quotio project is feature-rich. In this fork, priority is:

1. Claude Code relay compatibility first
2. minimal configuration path
3. stable local verification loop

## Current Status

### MVP A (Completed)

MVP A is done and verified locally:

- Quotio can read and write Claude Code relay settings
- Claude configuration supports direct editing of proxy URL and API key
- existing relay settings can be detected and loaded back into setup UI
- `/v1` normalization is handled automatically for Claude setup
- end-to-end requests pass through Quotio and appear in logs

### MVP B (Planned)

Next step is model-based routing strategy:

- Opus -> relay route
- Sonnet / Haiku -> domestic provider route

## What Changed in This Fork

Main code updates:

- `Quotio/Services/AgentConfigurationService.swift`
  - improved Claude relay endpoint detection logic
- `Quotio/ViewModels/AgentSetupViewModel.swift`
  - load existing relay URL/token from saved config
  - normalize proxy URL and token before test/apply
- `Quotio/Views/Components/AgentConfigSheet.swift`
  - Claude setup now supports editable proxy URL and API key fields

## Quick Start

### 1. Build

Requirements:

- macOS
- Xcode installed (full app, not command-line tools only)

Build command:

```bash
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build
```

Open built app:

```bash
open "$HOME/Library/Developer/Xcode/DerivedData/Quotio-carfafughcvpnbdvonlotcwjdapz/Build/Products/Debug/Quotio.app"
```

If your DerivedData suffix differs, locate it with:

```bash
find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/Quotio.app" -print
```

### 2. Configure Relay Provider in Quotio

In `Providers` -> `Custom Providers`:

- add your relay provider (for example `ccmix`)
- fill base URL and API key
- ensure provider status is enabled

### 3. Configure Claude Code Agent

In `Agents` -> `Claude Code`:

- setup mode: `Proxy`
- config mode: `Automatic`
- storage: `JSON` (or `Both`)
- set proxy URL and API key
- choose model slots (Opus/Sonnet/Haiku)
- click `Test`, then `Apply`

### 4. Verify

Check Claude settings:

```bash
grep -E "ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_DEFAULT_" ~/.claude/settings.json
```

Expected result includes:

- `ANTHROPIC_BASE_URL`
- `ANTHROPIC_AUTH_TOKEN`
- `ANTHROPIC_DEFAULT_OPUS_MODEL`
- `ANTHROPIC_DEFAULT_SONNET_MODEL`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`

Then send a real Claude Code request and confirm request records in Quotio `Logs` tab.

## Troubleshooting

### Models list does not show expected relay models

- ensure proxy is running in Quotio
- confirm custom provider is enabled
- retry model refresh in Agent setup
- restart proxy once after changing custom provider

### `~/.claude/settings.json` not updated

- ensure setup mode is `Proxy`
- ensure config mode is `Automatic`
- ensure you clicked `Apply` (not just `Test`)
- check file permissions for `~/.claude/settings.json`

### `rg` command not found

Use `grep` instead:

```bash
grep -E "ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_DEFAULT_" ~/.claude/settings.json
```

## Upstream Credits

This fork is based on the excellent upstream project:

- [nguyenphutrong/quotio](https://github.com/nguyenphutrong/quotio)

## License

MIT License. See `LICENSE`.
