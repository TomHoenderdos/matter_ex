# Matterlix Roadmap

Pure Elixir Matter protocol stack — zero external dependencies.

## Completed Phases (1-47)

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
| 32 | Group Messaging (group key derivation, group receive, no-reply semantics) | - |
| 33 | Per-Peer Addressing (dynamic transport update per session) | - |
| 34 | Additional Clusters: Identify, Binding, PowerSource | - |
| 35 | Fabric-Scoped Attributes (per-fabric read filtering, write merging) | - |
| 36 | Attribute Constraints (min/max range, enum validation, constraint_error) | - |
| 37 | Groups + Scenes Clusters (group membership, scene store/recall) | - |
| 38 | Additional Clusters: DoorLock, WindowCovering | - |
| 39 | Additional Clusters: FanControl, OccupancySensing, IlluminanceMeasurement, RelativeHumidityMeasurement | - |
| 40 | Additional Clusters: PressureMeasurement, FlowMeasurement, PumpConfigurationAndControl | - |
| 41 | Fabric Removal (RemoveFabric, UpdateFabricLabel on OperationalCredentials) | - |
| 42 | Diagnostics Clusters: GeneralDiagnostics, SoftwareDiagnostics, WiFiNetworkDiagnostics | - |
| 43 | EthernetNetworkDiagnostics, AdminCommissioning clusters | - |
| 44 | Localization + Time clusters (LocalizationConfiguration, TimeFormatLocalization, UnitLocalization, TimeSynchronization) | - |
| 45 | Switch, ModeSelect, FixedLabel, UserLabel clusters | - |
| 46 | OTA Software Update (Provider + Requestor clusters) | - |
| 47 | ElectricalMeasurement, PowerTopology, AirQuality, ConcentrationMeasurement (PM2.5, PM10, CO2, TVOC) | - |

**Current: 935 tests, 0 failures**

---

## P2 — Spec compliance

---

## P3 — Production hardening
