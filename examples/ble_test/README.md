# BleTest

Minimal Nerves + BlueHeron BLE test for Raspberry Pi Zero 2W.

Tests whether the BlueHeron `rpi-zero-2w-bluetooth-support` branch can
initialize the onboard Broadcom BCM43430 Bluetooth chip, register GATT
services, and advertise over BLE.

**This is NOT a Matter example** — it's a bare-bones BLE test.

## Hardware

- Raspberry Pi Zero 2W (BCM2710 SoC, BCM43430 WiFi/BT combo chip)
- Bluetooth HCI via mini UART (`/dev/ttyS0` at 115200 baud)

## Build & Burn

```bash
export MIX_TARGET=rpi0_2
mix deps.get
mix firmware
mix burn
```

## Test Results (Pi Zero 2W Rev 1.0)

All tested and confirmed working:

| Feature | Status | Notes |
|---------|--------|-------|
| UART HCI transport | OK | `/dev/ttyS0` at 115200 opens successfully |
| Broadcom firmware init | OK | BCM43430/1 firmware loads, LMP subversion 0x2209 |
| BLE advertising | OK | Device visible as "BleTest" in nRF Connect |
| GATT connection | OK | Phone connects and discovers services |
| GATT service discovery | OK | GAP (0x1800), GATT (0x1801), test service (0xFFE0) |
| Characteristic read | OK | 0xFFE1 returns "Hello from BleTest!" (hex: 4865 6C6C...) |
| Start/stop advertising | OK | `BlueHeron.Broadcaster` start/stop works |

### Known Issues

- **HCI deserialize warnings**: The Broadcom chip periodically sends vendor-specific
  HCI events (opcode `0x56`) that BlueHeron doesn't recognize. These are logged as
  errors but do not affect functionality. The last byte fluctuates and likely
  represents RSSI or link quality telemetry. These should be silently ignored in
  a future BlueHeron update.

- **"No firmware mapping for LMP subversion 0x2209"**: Logged during init. The chip
  still functions correctly despite this warning.

- **First start_advertising after boot**: May return `{:error, :command_disallowed}`
  if called while BlueHeron is still processing the auto-start. Stop first, then
  start again.

## Verify

### From your phone (nRF Connect recommended)

1. Open nRF Connect and scan — "BleTest" should appear
2. Tap Connect — GATT services should be discovered:
   - **0x1800** — GAP (device name, appearance)
   - **0x1801** — GATT (auto-added by BlueHeron)
   - **0xFFE0** — Test service
3. Read characteristic **0xFFE1** — should return "Hello from BleTest!"

### From the device IEx console

```elixir
BleTest.status()            # Show BLE state and registered GATT services
BleTest.start_advertising() # Start BLE advertising
BleTest.stop_advertising()  # Stop BLE advertising
RingLogger.next()           # Check logs
```

### Example boot log (abbreviated)

```
[info] Opened UART for HCI transport: /dev/ttyS0 [device: "/dev/ttyS0", speed: 115200, ...]
[info] No firmware mapping for LMP subversion 0x2209
[info] [BleTest] Setting up BLE services...
[info] [BleTest] GAP service registered
[info] [BleTest] Test service registered (0xFFE0)
[info] [BleTest] Advertising data set
[info] [BleTest] BLE advertising started! Device should be visible as 'BleTest'
```
