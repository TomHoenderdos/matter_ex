# Matterlix Roadmap

Pure Elixir Matter protocol stack — zero external dependencies.

## Completed Phases (1-26)

| Phase | Description | Tests |
|-------|-------------|-------|
| 1-5 | TLV codec, Message codec, Secure channel, IM codec/router | - |
| 6 | Data Model Framework (Device macro, Cluster macro) | - |
| 7 | PASE (SPAKE2+ commissioning) | - |
| 8 | Session Encryption (AES-CCM Secure Channel) | - |
| 9 | Exchange Manager | - |
| 10 | Message Handler (full protocol orchestration) | - |
| 11 | UDP Node Server | - |
| 12 | mDNS/DNS-SD Discovery (commissionable) | - |
| 13 | Subscription Manager | - |
| 14 | CASE (Certificate-Authenticated Session Establishment) | - |
| 15 | Additional Clusters (LevelControl, ColorControl, Thermostat, etc.) | - |
| 16 | Commissioning Flow (GeneralCommissioning, OperationalCredentials) | - |
| 17 | Access Control (ACL engine, AccessControl cluster) | - |
| 18 | Wildcard Path Expansion | - |
| 19 | Network Commissioning + Group Key Management clusters | - |
| 20 | TimedRequest Handling | - |
| 21 | Standalone ACK | - |
| 22 | Real NOC Parsing (X.509 DER with Matter OIDs) | - |
| 23 | Operational mDNS (`_matter._tcp`) | - |
| 24 | CASE Session Resumption (graceful fallback to full CASE) | - |
| 25 | Subscription Lifecycle (min_interval throttle, give_up cleanup, session close) | - |
| 26 | suppress_response Handling | - |

**Current: 723 tests, 0 failures**

---

## P2 — Spec compliance

### Phase 27: Global Attributes

Auto-generate `AttributeList` (0xFFFB), `AcceptedCommandList` (0xFFF9), `GeneratedCommandList` (0xFFF8), and `FeatureMap` (0xFFFC) on every cluster from the declared `attribute_defs()` and `command_defs()`.

- `lib/matterlix/cluster.ex` — macro enhancement

### Phase 28: DataVersion Tracking

Track a monotonically increasing `DataVersion` per cluster that increments on attribute writes. Include in `ReportData`. Support `DataVersionFilter` in `ReadRequest` to skip unchanged clusters.

### Phase 29: Event Reporting

Add `EventRequest`, `EventReport`, event storage, and cluster event emission. Required by some mandatory clusters (e.g. `BasicInformation.StartUp`).

---

## P3 — Production hardening

### Phase 30: Multi-Fabric Support

Remove hardcoded `fabric_index: 1`. Track multiple fabrics with independent ACL, NOC, and IPK storage. Required for multi-admin scenarios.

### Phase 31: TCP Transport

Add `:gen_tcp` listener alongside UDP. Required for large payloads (>1280 bytes) and `T=1` mDNS advertisement.

### Phase 32: Group Messaging

Implement group key derivation, multicast receive, and no-reply semantics. Required for scenes/groups clusters.

### Phase 33: Per-Peer Addressing

Track peer addresses per session instead of a single `peer` field. Allows concurrent controllers without response misdirection.
