# MatterEx

A [Matter](https://csa-iot.org/all-solutions/matter/) smart home protocol stack written in pure Elixir.

MatterEx implements the Matter application protocol from the ground up — TLV encoding,
secure sessions (PASE and CASE), the Interaction Model, mDNS discovery, and 60 clusters —
with zero external dependencies beyond OTP. It interoperates with
[chip-tool](https://github.com/project-chip/connectedhomeip/tree/master/examples/chip-tool),
the Matter reference controller, across 28 end-to-end integration tests covering
commissioning, read/write/invoke, subscriptions, and wildcard reads.

> **Status**: Experimental. The protocol core works and passes chip-tool interop, but
> this is not yet production-ready. APIs may change.

## Features

- **Pure Elixir** — no C/C++ dependencies; all protocol logic in Elixir
- **Zero external deps** — only OTP's `:crypto` and `:public_key`
- **chip-tool interop** — commission, establish CASE sessions, read/write attributes, invoke commands, subscribe
- **Pure functional core** — PASE, CASE, and MessageHandler are stateless; GenServers are thin wrappers
- **1000+ unit tests** and 28 chip-tool integration tests
- **60 cluster implementations** covering lighting, HVAC, sensors, locks, media, and more

## Quick Start

```elixir
# Define a device
defmodule MyApp.Light do
  use MatterEx.Device,
    vendor_name: "Acme",
    product_name: "Smart Light",
    vendor_id: 0xFFF1,
    product_id: 0x8001

  endpoint 1, device_type: 0x0100 do
    cluster MatterEx.Cluster.OnOff
    cluster MatterEx.Cluster.LevelControl
  end
end
```

```elixir
# Start a Matter node
{:ok, _} = MyApp.Light.start_link()

MatterEx.Node.start_link(
  device: MyApp.Light,
  port: 5540,
  passcode: 20202021,
  discriminator: 3840
)
```

The node will advertise via mDNS and accept commissioning from any Matter controller.

Endpoint 0 is auto-generated with Descriptor, BasicInformation, GeneralCommissioning,
OperationalCredentials, AccessControl, NetworkCommissioning, and GroupKeyManagement.

## Architecture

```
                         UDP / TCP
                            |
                         Node (GenServer)
                            |
                     MessageHandler (pure)
                       /          \
                 PASE (SPAKE2+)   CASE (Sigma)
                       \          /
                    ExchangeManager (MRP)
                            |
                      IM Router (pure)
                            |
                   Cluster GenServers
           (OnOff, Thermostat, DoorLock, ...)
```

- **Node** — binds UDP/TCP sockets, dispatches raw bytes
- **MessageHandler** — pure functional message orchestration; decrypts, routes to PASE/CASE/IM
- **PASE** — SPAKE2+ commissioning (passcode-based)
- **CASE** — certificate-authenticated session establishment (Sigma protocol)
- **ExchangeManager** — MRP reliability, retransmission, exchange tracking
- **IM Router** — dispatches Interaction Model operations to cluster GenServers
- **Clusters** — GenServers holding attribute state, handling commands

## Clusters

60 clusters organized by function:

**Lighting & Control** —
OnOff, LevelControl, ColorControl, FanControl, WindowCovering, PumpConfigurationAndControl

**Smart Home** —
DoorLock, Thermostat, Switch, ModeSelect, ValveConfigurationAndControl

**Sensors** —
TemperatureMeasurement, IlluminanceMeasurement, RelativeHumidityMeasurement,
PressureMeasurement, FlowMeasurement, OccupancySensing, ElectricalMeasurement

**Air Quality** —
AirQuality, ConcentrationMeasurement (CO2, PM2.5, PM10, TVOC), SmokeCOAlarm

**Infrastructure** —
Descriptor, BasicInformation, AccessControl, Binding, Groups, Scenes, Identify,
GeneralCommissioning, OperationalCredentials, NetworkCommissioning, GroupKeyManagement,
AdminCommissioning, PowerSource, BooleanState, BooleanStateConfiguration

**Diagnostics** —
GeneralDiagnostics, SoftwareDiagnostics, WiFiNetworkDiagnostics, EthernetNetworkDiagnostics

**Localization & Time** —
LocalizationConfiguration, TimeFormatLocalization, UnitLocalization, TimeSynchronization

**Labels** — FixedLabel, UserLabel

**OTA** — OTASoftwareUpdateProvider, OTASoftwareUpdateRequestor

**Energy** — DeviceEnergyManagement, EnergyPreference, PowerTopology

**Media** — MediaPlayback, ContentLauncher, AudioOutput

**Appliances** — LaundryWasherControls, DishwasherAlarm, RefrigeratorAlarm

**ICD** — ICDManagement

## Testing

Unit tests:

```bash
mix test
```

chip-tool integration tests (requires `chip-tool` in PATH):

```bash
mix run test_chip_tool.exs
```

The integration test commissions a device, then runs 28 steps: OnOff toggle/on/off,
BasicInformation reads, Descriptor validation, ACL reads, Identify invoke, Groups,
Scenes, timed interactions, wildcard reads, error paths, and subscriptions.

Re-run only previously failed tests:

```bash
mix run test_chip_tool.exs -- --retest
```

## Requirements

- Elixir ~> 1.17
- Erlang/OTP 26+
- No external dependencies

## License

Apache License 2.0 — see [LICENSE](LICENSE).
