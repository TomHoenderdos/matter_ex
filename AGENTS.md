# Repository Guidelines

## Project Structure & Module Organization

`lib/matter_ex/` contains the Matter protocol library. Core modules live at the top level; protocol areas are split into `crypto/`, `im/`, `protocol/`, `transport/`, `tlv/`, and `cluster/`. Tests mirror this layout under `test/matter_ex/`. `config/` holds Mix configuration. `examples/ble_test/` and `examples/net_test/` are separate Nerves example apps with their own `mix.exs`, configs, tests, and README files. Do not edit generated `_build/` or `deps/` content.

## Build, Test, and Development Commands

- `mix deps.get` installs project dependencies.
- `mix compile --warnings-as-errors` compiles the library, matching CI.
- `mix test` runs the ExUnit suite.
- `mix test test/matter_ex/tlv_test.exs` runs one test file while iterating.
- `mix credo --strict` runs static analysis.
- `mix format` formats source, config, and tests covered by `.formatter.exs`.
- `mix docs` builds ExDoc documentation locally.

Run example commands from the example directory, for example `cd examples/ble_test && mix test`.

## Coding Style & Naming Conventions

Use standard Elixir formatting with two-space indentation and let `mix format` decide layout. Module names follow `MatterEx.*` and should match file paths, for example `MatterEx.Protocol.MessageCodec` in `lib/matter_ex/protocol/message_codec.ex`. Use `snake_case` for functions, variables, files, attributes, and command names. Keep protocol logic pure where existing modules are pure; use GenServers mainly for stateful runtime boundaries.

## Testing Guidelines

Add ExUnit tests under `test/matter_ex/`. Name files with `_test.exs` and test modules with a matching `Test` suffix. Prefer focused unit tests for encoders, decoders, crypto helpers, and routers; add integration-style tests when behavior crosses sessions, transports, or Interaction Model routing. Before opening a PR, run `mix test`, `mix credo --strict`, and `mix format --check-formatted`.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects such as `Fix README: remove false claims` and `Add minimal BLE test example for Pi Zero 2W`. Keep subjects specific and explain the why in the body when behavior changes. PRs should follow `.github/pull_request_template.md`: include a summary, changes, and a test plan. Link issues when available; include screenshots or logs only for user-visible or hardware/Nerves changes.

## Security & Configuration Tips

Do not commit device credentials, fabric secrets, certificates, or private keys. Treat Matter passcodes, discriminators, operational credentials, and generated certificates as test-only unless documented otherwise. Keep host-specific Nerves configuration inside the relevant example app and avoid changing global library config for device-specific experiments.
