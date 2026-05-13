# Hypervisor VM Graceful Shutdown Script

A production-grade Windows CMD/BAT script for Windows Server 2022 that gracefully shuts down all running virtual machines on both Oracle VirtualBox and VMware Workstation/Player, then cleanly shuts down the Windows host.

## What It Does

1. **Auto-elevates** to Administrator (via VBScript if not already elevated)
2. **Discovers** VBoxManage and vmrun executables automatically
3. **Builds inventory** of all running VMs across both hypervisors
4. **Gracefully shuts down** each VM via ACPI (VirtualBox) or `vmrun stop soft` (VMware)
5. **Polls** every 5 seconds until VM is confirmed off (configurable)
6. **Force power-off** on timeout (optional, configurable)
7. **Final verification** that nothing is still running
8. **Summary report** with success/fail/timeout counts
9. **Gracefully shuts down** the Windows host

## Usage

```cmd
hypervisor-vm-shutdown.cmd
```

Run as Administrator — the script auto-elevates if needed.

## Configuration

All settings are at the top of the script:

| Variable | Default | Purpose |
|---|---|---|
| `CFG_SHUTDOWN_TIMEOUT` | `300` | Seconds to wait per VM before timeout |
| `CFG_FORCE_SHUTDOWN` | `YES` | Hard power-off on timeout? (`YES`/`NO`) |
| `CFG_LOG_DIR` | `C:\HypervisorShutdownLogs` | Where timestamped logs go |
| `CFG_LOG_RETENTION_DAYS` | `30` | Auto-purge old logs |
| `CFG_HOST_SHUTDOWN_DELAY` | `10` | Countdown seconds before host power-off |
| `CFG_CHECK_INTERVAL` | `5` | Polling interval for VM status checks |
| `CFG_COLOR_OUTPUT` | `YES` | ANSI-coloured console output |

## Platform Support

- Windows Server 2022 (primary target)
- Windows Server 2016 / 2019 / 2025
- Windows 10 / 11 with VirtualBox and/or VMware

## Hypervisor Support

- **Oracle VirtualBox** — detected via VBoxManage.exe
- **VMware Workstation** — detected via vmrun.exe
- **VMware Player** — detected via vmrun.exe (auto-selects `-T player`)

## Logs

Timestamped logs are written to `CFG_LOG_DIR` with the format:
`shutdown_YYYY-MM-DD_HH-MM-SS.log`

Logs older than `CFG_LOG_RETENTION_DAYS` are automatically purged on each run.

## License

MIT
