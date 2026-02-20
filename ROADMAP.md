# Matterlix Roadmap

Pure Elixir Matter protocol stack — zero external dependencies.

## Completed Phases (1-30)

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
| 27 | Global Attributes (AttributeList, AcceptedCommandList, GeneratedCommandList, FeatureMap) | - |
| 28 | DataVersion Tracking (per-cluster version, DataVersionFilter in ReadRequest) | - |
| 29 | Event Reporting (EventStore, event macro, BasicInformation.StartUp, IM codec) | - |
| 30 | Multi-Fabric Support (per-fabric CASE, NOC, ACL, mDNS) | - |
| 31 | TCP Transport (length-prefixed framing, MRP bypass, per-session transport) | - |

**Current: 778 tests, 0 failures**

---

## P2 — Spec compliance

---

## P3 — Production hardening

### Phase 32: Group Messaging

Implement group key derivation, multicast receive, and no-reply semantics. Required for scenes/groups clusters.

### Phase 33: Per-Peer Addressing

Track peer addresses per session instead of a single `peer` field. Allows concurrent controllers without response misdirection.
