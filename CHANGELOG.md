# Changelog

## 0.5.0 — 2026-09-21

### Added

- Optional fabric persistence through `MatterEx.Storage`, with a filesystem backend
  and restoration of commissioned fabrics after restart.
- `MatterEx.Node.factory_reset/1` to clear fabrics, sessions, subscriptions, and
  fabric-scoped cluster state and return to commissioning.
- Push-based subscription reporting with polling fallback and registration recovery.

### Changed

- Subscription polling uses cluster DataVersion to avoid unnecessary reads, and
  idle subscriptions receive keep-alive reports within the negotiated interval.
- Report data is chunked by encoded size, including ongoing subscription reports.
- TCP acceptors are supervised independently of the node.
- mDNS announcements recover after reboot and address changes, retry with backoff,
  and support selecting multiple network interfaces.

### Fixed

- Serialize subscription reports across priming reports and chunk continuations;
  release in-flight guards correctly and clean up report tracking.
- Reject malformed fabric-scoped writes and skip malformed ACL entries during
  evaluation so one fabric's invalid entry cannot disrupt another fabric.
- Propagate storage wipe failures from factory reset, sync file contents before
  renaming persisted state, and derive reset values from cluster initialization.
- Return current status from device invokes and avoid generating unreachable
  ambiguous-command clauses.
- Resolve compilation warnings under Erlang/OTP 29 and Elixir 1.20.

### Upgrade notes

- Persistence is opt-in through the node's `:storage` option; the default remains
  in-memory operation.
- Handle `{:error, reason}` from `MatterEx.Node.factory_reset/1`: in-memory state
  is reset, but persisted credentials may remain if storage cannot be cleared.
- MatterEx remains experimental; controller and hardware validation is recommended
  for the devices you deploy.
