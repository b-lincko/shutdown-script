# Hypervisor VM Shutdown Script

Production-grade Windows batch script that gracefully shuts down all running guest VMs across multiple hypervisors, then shuts down the Windows host. Designed for unattended lab setups, UPS-triggered shutdowns, and data center maintenance.

## Supported Hypervisors

- **Hyper-V** (Windows Server built-in)
- **Oracle VirtualBox**
- **VMware Workstation / VMware Player**

## Quick Start

1. **Download** `hypervisor-vm-shutdown.cmd`
2. **Run as Administrator** — the script auto-elevates if you forget
3. That's it. It finds your VMs, shuts them down gracefully, then shuts down the host.

```cmd
hypervisor-vm-shutdown.cmd
```

## Configuration

Edit the variables at the top of the script:

| Variable | Default | Description |
|---|---|---|
| `CFG_SHUTDOWN_TIMEOUT` | `300` | Seconds to wait per VM before timing out |
| `CFG_FORCE_SHUTDOWN` | `YES` | Force power-off VMs that don't shut down in time |
| `CFG_LOG_DIR` | `C:\HypervisorShutdownLogs` | Where timestamped logs are stored |
| `CFG_LOG_RETENTION_DAYS` | `30` | Auto-delete logs older than this |
| `CFG_HOST_SHUTDOWN_DELAY` | `10` | Countdown before host shutdown |
| `CFG_CHECK_INTERVAL` | `5` | How often to poll VM state (seconds) |
| `CFG_COLOR_OUTPUT` | `YES` | ANSI-coloured console output |

## How It Works

1. **Auto-elevates** to Administrator via VBScript UAC prompt
2. **Discovers** available hypervisors (Hyper-V, VirtualBox, VMware)
3. **Builds inventory** of all running VMs across every detected hypervisor
4. **Shuts down each VM** gracefully:
   - Hyper-V: `Stop-VM -TurnOff:$false` (Integration Services)
   - VirtualBox: `VBoxManage controlvm <name> acpipowerbutton`
   - VMware: `vmrun stop <vmx> soft`
5. **Polls** each VM until it powers off (or timeout + force-off)
6. **Verifies** no VMs remain running
7. **Prints summary** and shuts down the host

## Error Resilience

- One VM failing doesn't block others from shutting down
- Race-condition safe: detects if a VM was already shut down externally
- All failures are logged with timestamps
- Summary report shows per-VM outcome (success/forced/failed/timed out)

## Requirements

- Windows Server 2016 / 2019 / 2022 / 2025 (also works on Windows 10/11)
- Administrator privileges
- At least one supported hypervisor installed

## License

MIT
