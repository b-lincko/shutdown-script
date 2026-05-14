@echo off
setlocal enabledelayedexpansion
:: ============================================================================
::  Hypervisor VM Graceful Shutdown & Host Shutdown Script
::  Platform:       Windows Server 2022 (also 2016/2019/2025)
::  Compatibility:  Hyper-V + Oracle VirtualBox + VMware Workstation/Player
::  Purpose:        Gracefully shut down all running guest VMs, then the host
::  Usage:          Run as Administrator (auto-elevates if not elevated)
::  Version:        2.2.1
::  License:        MIT
:: ============================================================================

:: ---------------------------------------------------------------------------
:: CONFIGURATION -- Adjust these to match your environment
:: ---------------------------------------------------------------------------

    set "CFG_SHUTDOWN_TIMEOUT=300"
    :: Seconds to wait per VM for graceful guest-OS shutdown before timing out

    set "CFG_FORCE_SHUTDOWN=YES"
    :: YES = attempt force power-off after timeout expires
    :: NO  = log timeout and move on (leave the VM running)

    set "CFG_LOG_DIR=C:\HypervisorShutdownLogs"
    :: Directory for timestamped log files (created automatically)

    set "CFG_LOG_RETENTION_DAYS=30"
    :: Auto-delete log files older than this many days

    set "CFG_HOST_SHUTDOWN_DELAY=10"
    :: Countdown in seconds before issuing the host shutdown command

    set "CFG_CHECK_INTERVAL=5"
    :: Interval (seconds) between "is the VM still running?" polls

    set "CFG_COLOR_OUTPUT=YES"
    :: YES = ANSI-coloured console text   NO = plain white

:: ---------------------------------------------------------------------------
:: INTERNAL SETUP -- Do not edit below unless you understand the consequences
:: ---------------------------------------------------------------------------

set "SCRIPT_NAME=%~nx0"
set "SCRIPT_DIR=%~dp0"

REM Generate a locale-independent timestamp via PowerShell
REM (wmic is deprecated and locale-sensitive; this is bulletproof)
powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd_HHmmss'" > "%TEMP%\hyperv_ts.tmp" 2>nul
set "TIMESTAMP="
for /f "usebackq tokens=*" %%T in ("%TEMP%\hyperv_ts.tmp") do set "TIMESTAMP=%%T"
del /f /q "%TEMP%\hyperv_ts.tmp" >nul 2>&1
if "!TIMESTAMP!"=="" (
    REM Last-resort fallback (may be locale-dependent)
    set "TIMESTAMP=%DATE:~-4%%DATE:~3,2%%DATE:~0,2%_%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%"
    set "TIMESTAMP=!TIMESTAMP: =0!"
)
set "LOG_FILE=%CFG_LOG_DIR%\shutdown_!TIMESTAMP!.log"

REM Obtain the ESC character (0x1B) for ANSI colour sequences
REM Method: spawn a child cmd, set its prompt to ESC+space, echo something so
REM the prompt text is emitted, then capture the first token (the ESC byte).
for /f %%E in ('"prompt $E$S & for %%X in (1) do echo off"') do set "ESC=%%E"
if "!ESC!"=="" (
    echo [WARN] Could not obtain ESC character -- colours disabled.
    set "CFG_COLOR_OUTPUT=NO"
)

set "C_RESET=!ESC![0m"
set "C_RED=!ESC![91m"
set "C_GREEN=!ESC![92m"
set "C_YELLOW=!ESC![93m"
set "C_CYAN=!ESC![96m"
set "C_WHITE=!ESC![97m"

REM Summary counters
set "VM_TOTAL=0"
set "VM_SUCCESS=0"
set "VM_FAILED=0"
set "VM_TIMEDOUT=0"
set "VM_FORCED=0"
set "VM_SKIPPED=0"

:: ============================================================================
::  MAIN EXECUTION starts here
:: ============================================================================

call :Init

call :Log "===== HYPERVISOR VM SHUTDOWN SCRIPT STARTED ====="
call :Log "Script : !SCRIPT_NAME!"
call :Log "Host   : %COMPUTERNAME%"
call :Log "User   : %USERDOMAIN%\%USERNAME%"
call :Log "Log    : !LOG_FILE!"
call :Log ""

:: ---------------------------------------------------------------------------
::  SECTION 1 -- Administrator Privilege Check & Auto-Elevation
:: ---------------------------------------------------------------------------

REM Preferred check: High Mandatory Level SID (S-1-16-12288)
whoami /groups 2>nul | find "S-1-16-12288" >nul 2>&1
if !errorlevel! neq 0 (
    REM Fallback check for older systems: net session
    net session >nul 2>&1
    if !errorlevel! neq 0 (
        call :Warn "Not running as Administrator -- attempting auto-elevation..."

        REM Construct a temporary VBScript to relaunch elevated.
        REM This is the ONLY reliable pure-CMD approach on all Windows versions.
        set "VBS_FILE=%TEMP%\~elevate_!RANDOM!.vbs"
        (
            echo Set UAC = CreateObject^("Shell.Application"^)
            echo UAC.ShellExecute "%~dpnx0", "", "%~dp0", "runas", 1
        ) > "!VBS_FILE!"

        cscript //nologo "!VBS_FILE!" >nul 2>&1
        del /f /q "!VBS_FILE!" >nul 2>&1

        REM If we reach this point, the user cancelled UAC prompt or it failed
        call :Error "Administrator privileges are REQUIRED. Cannot continue."
        call :Log ""
        pause
        exit /b 1
    )
)

call :OK "Confirmed: running with Administrator privileges."
call :Log ""

:: ---------------------------------------------------------------------------
::  SECTION 2 -- Hypervisor Tool Discovery
:: ---------------------------------------------------------------------------

call :Log "----- TOOL DISCOVERY -----"

:: --- VirtualBox VBoxManage ---

set "VBOX_MANAGE="
set "VBOX_FOUND=NO"

REM Search common install directories
for %%D in (
    "C:\Program Files\Oracle\VirtualBox"
    "C:\Program Files (x86)\Oracle\VirtualBox"
    "%ProgramFiles%\Oracle\VirtualBox"
    "%ProgramFiles(x86)%\Oracle\VirtualBox"
) do (
    if exist "%%~D\VBoxManage.exe" (
        set "VBOX_MANAGE=%%~D\VBoxManage.exe"
        set "VBOX_FOUND=YES"
    )
)

REM Check PATH as a last resort
if "!VBOX_FOUND!"=="NO" (
    where VBoxManage.exe >nul 2>&1
    if !errorlevel! equ 0 (
        for /f "delims=" %%P in ('where VBoxManage.exe 2^>nul') do (
            set "VBOX_MANAGE=%%P"
            set "VBOX_FOUND=YES"
        )
    )
)

if "!VBOX_FOUND!"=="YES" (
    call :OK "VirtualBox VBoxManage found: !VBOX_MANAGE!"
) else (
    call :Info "VirtualBox VBoxManage not found -- VirtualBox detection skipped."
)

:: --- VMware vmrun ---

set "VMWARE_RUN="
set "VMWARE_FOUND=NO"

REM Common install locations for Workstation and Player
for %%D in (
    "C:\Program Files (x86)\VMware\VMware Workstation"
    "C:\Program Files (x86)\VMware\VMware Player"
    "C:\Program Files\VMware\VMware Workstation"
    "C:\Program Files\VMware\VMware Player"
    "%ProgramFiles(x86)%\VMware\VMware Workstation"
    "%ProgramFiles(x86)%\VMware\VMware Player"
    "%ProgramFiles%\VMware\VMware Workstation"
    "%ProgramFiles%\VMware\VMware Player"
) do (
    if exist "%%~D\vmrun.exe" (
        set "VMWARE_RUN=%%~D\vmrun.exe"
        set "VMWARE_FOUND=YES"
    )
)

REM Check PATH as fallback
if "!VMWARE_FOUND!"=="NO" (
    where vmrun.exe >nul 2>&1
    if !errorlevel! equ 0 (
        for /f "delims=" %%P in ('where vmrun.exe 2^>nul') do (
            set "VMWARE_RUN=%%P"
            set "VMWARE_FOUND=YES"
        )
    )
)

if "!VMWARE_FOUND!"=="YES" (
    call :OK "VMware vmrun found: !VMWARE_RUN!"
) else (
    call :Info "VMware vmrun not found -- VMware detection skipped."
)

:: --- Hyper-V PowerShell module ---

set "HYPERV_FOUND=NO"

REM Detect Hyper-V via PowerShell.
REM Uses a fixed temp filename (no !RANDOM!) to avoid delayed-expansion bugs.
REM try/catch handles systems where Get-WindowsOptionalFeature is unavailable.
powershell -NoProfile -Command "try { $f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop; if ($f.State -eq 'Enabled') { $m = Get-Module -ListAvailable Hyper-V -ErrorAction SilentlyContinue; if ($m) { 'YES' } else { 'SVC' } } else { 'NO' } } catch { 'NO' }" > "%TEMP%\hyperv_detect.tmp" 2>nul

REM Read back the result using for /f (safer than set /p with redirects)
set "HYPERV_DETECT="
for /f "usebackq tokens=*" %%R in ("%TEMP%\hyperv_detect.tmp") do set "HYPERV_DETECT=%%R"
del /f /q "%TEMP%\hyperv_detect.tmp" >nul 2>&1

if /i "!HYPERV_DETECT!"=="YES" (
    set "HYPERV_FOUND=YES"
    call :OK "Hyper-V detected (role installed + PowerShell module available)."
) else if /i "!HYPERV_DETECT!"=="SVC" (
    call :Info "Hyper-V role installed but PowerShell Hyper-V module not available."
    call :Info "Hyper-V detection skipped."
) else (
    call :Info "Hyper-V role not installed -- Hyper-V detection skipped."
)

REM --- Neither found? ---

if "!VBOX_FOUND!"=="NO" if "!VMWARE_FOUND!"=="NO" if "!HYPERV_FOUND!"=="NO" (
    call :Warn "No supported hypervisors were detected."
    call :Warn "Checked: Hyper-V, VirtualBox, VMware."
    call :Warn "No VM management is possible. Proceeding directly to host shutdown..."
    goto :PreShutdown
)

call :Log ""

:: ---------------------------------------------------------------------------
::  SECTION 3 -- Build VM Inventory
:: ---------------------------------------------------------------------------

call :Log "----- BUILDING VM INVENTORY -----"

set "VM_LIST_FILE=%TEMP%\~vm_list_!RANDOM!.txt"
type nul > "!VM_LIST_FILE!"

:: --- VirtualBox: discover running VMs ---

if "!VBOX_FOUND!"=="YES" (
    call :Info "Scanning for running VirtualBox VMs..."

    set "VBOX_TMP=%TEMP%\~vbox_running_!RANDOM!.tmp"
    "!VBOX_MANAGE!" list runningvms > "!VBOX_TMP!" 2>&1

    if !errorlevel! neq 0 (
        call :Warn "VBoxManage returned an error while listing running VMs."
        call :Warn "Ensure VirtualBox services are running."
        type "!VBOX_TMP!" >> "!LOG_FILE!"
    ) else (
        REM Output format: "VM Name" {aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}
        REM We split on { } to get name and UUID separately
        for /f "usebackq tokens=*" %%L in ("!VBOX_TMP!") do (
            set "VM_LINE=%%L"

            REM Extract name: everything before first '{', strip quotes
            for /f "delims={" %%N in ("!VM_LINE!") do set "VM_NAME=%%~N"
            REM VBoxManage output always has a space between name and { -- trim last char
            if not "!VM_NAME!"=="" if "!VM_NAME:~-1!"==" " set "VM_NAME=!VM_NAME:~0,-1!"
            REM Also trim any remaining leading/trailing spaces (for edge cases)
            for /f "tokens=*" %%T in ("!VM_NAME!") do set "VM_NAME=%%T"

            REM Extract UUID: everything between '{' and '}'
            for /f "tokens=2 delims={}" %%U in ("!VM_LINE!") do set "VM_UUID=%%U"

            if not "!VM_NAME!"=="" (
                echo VBOX^|!VM_NAME!^|!VM_UUID!>> "!VM_LIST_FILE!"
                call :Info "  Found VirtualBox VM: !VM_NAME!"
                set /a VM_TOTAL+=1
            )
        )
    )
    del /f /q "!VBOX_TMP!" >nul 2>&1
)

:: --- Hyper-V: discover running VMs ---

if "!HYPERV_FOUND!"=="YES" (
    call :Info "Scanning for running Hyper-V VMs..."

    REM Use PowerShell to enumerate running Hyper-V VMs.
    REM Output: one VM name per line (no header, no decoration).
    powershell -NoProfile -Command "Get-VM | Where-Object { $_.State -eq 'Running' } | ForEach-Object { Write-Output $_.VMName }" > "%TEMP%\hyperv_list.tmp" 2>nul

    if !errorlevel! neq 0 (
        call :Warn "PowerShell Get-VM returned an error while listing Hyper-V VMs."
        call :Warn "Ensure Hyper-V Virtual Machine Management service is running."
        type "%TEMP%\hyperv_list.tmp" >> "!LOG_FILE!"
    ) else (
        set "PARSE_COUNT=0"
        for /f "usebackq tokens=*" %%L in ("%TEMP%\hyperv_list.tmp") do (
            set "VM_NAME=%%L"
            REM Skip empty lines and PowerShell error lines that may leak
            if not "!VM_NAME!"=="" (
                echo !VM_NAME! | findstr /v /i /c:"error" /c:"warning" /c:"exception" >nul 2>&1
                if !errorlevel! equ 0 (
                    echo HYPERV^|!VM_NAME!^|!VM_NAME!>> "!VM_LIST_FILE!"
                    call :Info "  Found Hyper-V VM: !VM_NAME!"
                    set /a VM_TOTAL+=1
                    set /a PARSE_COUNT+=1
                )
            )
        )
        if !PARSE_COUNT! equ 0 (
            call :Info "  No running Hyper-V VMs detected."
        )
    )
    del /f /q "%TEMP%\hyperv_list.tmp" >nul 2>&1
)

:: --- VMware: discover running VMs ---

if "!VMWARE_FOUND!"=="YES" (
    call :Info "Scanning for running VMware VMs..."

    set "VMWARE_TMP=%TEMP%\~vmware_list_!RANDOM!.tmp"
    "!VMWARE_RUN!" list > "!VMWARE_TMP!" 2>&1

    if !errorlevel! neq 0 (
        call :Warn "vmrun returned an error while listing running VMs."
        call :Warn "Ensure VMware services are running."
        type "!VMWARE_TMP!" >> "!LOG_FILE!"
    ) else (
        REM Output format:
        REM   Total running VMs: 2
        REM   C:\VMs\MyVM.vmx
        REM   D:\OtherVM\OtherVM.vmx
        REM
        REM Strategy: skip lines starting with "Total", everything else is a .vmx path.
        set "PARSE_COUNT=0"
        for /f "usebackq tokens=*" %%L in ("!VMWARE_TMP!") do (
            set "VM_LINE=%%L"

            REM Only process lines that contain a .vmx path (skip summary header)
            echo !VM_LINE! | findstr /i /c:".vmx" >nul 2>&1
            if !errorlevel! equ 0 (
                set "VM_PATH=!VM_LINE!"
                REM Extract VM name from the .vmx filename
                for %%P in ("!VM_PATH!") do set "VM_NAME=%%~nP"

                echo VMWARE^|!VM_NAME!^|!VM_PATH!>> "!VM_LIST_FILE!"
                call :Info "  Found VMware VM: !VM_NAME!"
                set /a VM_TOTAL+=1
                set /a PARSE_COUNT+=1
            )
        )
        if !PARSE_COUNT! equ 0 (
            call :Info "  No running VMware VMs detected."
        )
    )
    del /f /q "!VMWARE_TMP!" >nul 2>&1
)

call :Log "Total running VMs detected: !VM_TOTAL!"
call :Log ""

:: --- No VMs? Skip to shutdown ---

if !VM_TOTAL! equ 0 (
    call :OK "No running VMs found. Proceeding to host shutdown..."
    goto :PreShutdown
)

:: ---------------------------------------------------------------------------
::  SECTION 4 -- Shut Down Each VM
:: ---------------------------------------------------------------------------

call :Log "===== VM SHUTDOWN PHASE ====="
call :Log ""

REM The inventory file has format: TYPE|NAME|ID
REM   TYPE = VBOX or VMWARE or HYPERV
REM   NAME = human-readable VM name
REM   ID   = UUID (VBox) or full .vmx path (VMware) or VM name (HyperV)
for /f "usebackq tokens=1,2,3 delims=|" %%A in ("!VM_LIST_FILE!") do (
    set "VM_TYPE=%%A"
    set "VM_NAME=%%B"
    set "VM_ID=%%C"

    REM Skip blank or malformed lines
    if not "!VM_TYPE!"=="" (
        call :Log "--- Processing: !VM_NAME!  [!VM_TYPE!] ---"
        call :Info "  Sending graceful shutdown command..."

        if "!VM_TYPE!"=="VBOX" (
            call :ShutdownVBox "!VM_NAME!"
        ) else if "!VM_TYPE!"=="VMWARE" (
            call :ShutdownVMware "!VM_ID!" "!VM_NAME!"
        ) else if "!VM_TYPE!"=="HYPERV" (
            call :ShutdownHyperV "!VM_NAME!"
        ) else (
            call :Warn "  Unknown VM type '!VM_TYPE!' -- skipping."
            set /a VM_SKIPPED+=1
        )
        call :Log ""
    )
)

:: ---------------------------------------------------------------------------
::  SECTION 5 -- Final Verification
:: ---------------------------------------------------------------------------

call :Log "===== FINAL VERIFICATION ====="

set "REMAINING=0"

if "!VBOX_FOUND!"=="YES" (
    set "VBOX_VERIFY=%TEMP%\~vbox_verify_!RANDOM!.tmp"
    "!VBOX_MANAGE!" list runningvms > "!VBOX_VERIFY!" 2>&1
    for /f "usebackq tokens=*" %%L in ("!VBOX_VERIFY!") do (
        if not "%%L"=="" set /a REMAINING+=1
    )
    del /f /q "!VBOX_VERIFY!" >nul 2>&1
)

if "!HYPERV_FOUND!"=="YES" (
    powershell -NoProfile -Command "(Get-VM | Where-Object { $_.State -eq 'Running' }).Count" > "%TEMP%\hyperv_verify.tmp" 2>nul
    set "HYPERV_RUNNING="
    for /f "usebackq tokens=*" %%R in ("%TEMP%\hyperv_verify.tmp") do set "HYPERV_RUNNING=%%R"
    del /f /q "%TEMP%\hyperv_verify.tmp" >nul 2>&1
    REM Sanitise: if the output isn't purely numeric, treat as 0
    echo !HYPERV_RUNNING! | findstr /r "^[0-9][0-9]*$" >nul 2>&1
    if !errorlevel! equ 0 set /a REMAINING+=!HYPERV_RUNNING!
)

if "!VMWARE_FOUND!"=="YES" (
    set "VMWARE_VERIFY=%TEMP%\~vmware_verify_!RANDOM!.tmp"
    "!VMWARE_RUN!" list > "!VMWARE_VERIFY!" 2>&1
    for /f "usebackq tokens=*" %%L in ("!VMWARE_VERIFY!") do (
        echo %%L | findstr /i /c:".vmx" >nul 2>&1
        if !errorlevel! equ 0 set /a REMAINING+=1
    )
    del /f /q "!VMWARE_VERIFY!" >nul 2>&1
)

if !REMAINING! gtr 0 (
    call :Warn "!REMAINING! VM(s) still appear to be running after all shutdown attempts!"
) else (
    call :OK "All VMs confirmed powered off."
)

:: ---------------------------------------------------------------------------
::  SECTION 6 -- Summary Report
:: ---------------------------------------------------------------------------

call :SummaryReport

:: ---------------------------------------------------------------------------
::  SECTION 7 -- Host Shutdown
:: ---------------------------------------------------------------------------

:PreShutdown

call :Log "===== HOST SHUTDOWN ====="

REM Copy countdown value before potential endlocal issues
set "SHUTDOWN_DELAY=%CFG_HOST_SHUTDOWN_DELAY%"

call :Log "Host shutdown will begin in %SHUTDOWN_DELAY% seconds..."
call :Log "Press Ctrl+C now to abort."
call :Log ""

for /l %%I in (%SHUTDOWN_DELAY%,-1,1) do (
    call :WarnNoLog "  Shutting down host in %%I second(s) ..."
    timeout /t 1 /nobreak >nul
)
call :Log ""

call :Log ">>> Issuing graceful Windows host shutdown command <<<"
call :Log ""

REM Options breakdown:
REM   /s    = shutdown
REM   /t N  = delay N seconds before shutdown
REM   /f    = force running applications to close (they get a chance to save)
REM   /d p:0:0 = planned shutdown, reason: other
REM   /c    = comment shown to interactive users
shutdown /s /t %SHUTDOWN_DELAY% /f /d p:0:0 /c "Hypervisor VM Shutdown Script -- all VMs processed."

call :Info "Host shutdown command issued successfully."
call :Log ""
call :Log "===== SCRIPT COMPLETE ====="
call :Log ""

REM Clean up temporary files
del /f /q "!VM_LIST_FILE!" >nul 2>&1

endlocal
exit /b 0


:: ############################################################################
::  SHUTDOWN FUNCTIONS
:: ############################################################################


:: ---------------------------------------------------------------------------
:: ShutdownVBox -- Graceful ACPI shutdown of a VirtualBox guest VM
::
::   %1 = VM name (or UUID -- VBoxManage accepts either)
::
:: Process:
::   1. Send ACPI power button press (simulates user pressing power button)
::   2. Poll VBoxManage list runningvms every CFG_CHECK_INTERVAL seconds
::   3. If VM disappears from the list → SUCCESS
::   4. If CFG_SHUTDOWN_TIMEOUT exceeded → attempt force-off (if enabled)
:: ---------------------------------------------------------------------------
:ShutdownVBox
    set "VB_NAME=%~1"
    set "VB_ELAPSED=0"

    REM Send ACPI soft-off signal
    "!VBOX_MANAGE!" controlvm "!VB_NAME!" acpipowerbutton >> "!LOG_FILE!" 2>&1

    if !errorlevel! neq 0 (
        REM Check if the VM is already off (race condition with external shutdown)
        set "VB_PRE_CHECK=%TEMP%\~vbox_pre_!RANDOM!.tmp"
        "!VBOX_MANAGE!" list runningvms 2>nul | findstr /c:"!VB_NAME!" > "!VB_PRE_CHECK!" 2>&1
        set "VB_STILL_RUN=NO"
        for /f "usebackq tokens=*" %%S in ("!VB_PRE_CHECK!") do (
            if not "%%S"=="" set "VB_STILL_RUN=YES"
        )
        del /f /q "!VB_PRE_CHECK!" >nul 2>&1
        if "!VB_STILL_RUN!"=="NO" (
            call :OK "  VM '!VB_NAME!' is already powered off (no action needed)."
            set /a VM_SUCCESS+=1
        ) else (
            call :Error "  FAILED to send ACPI shutdown signal to '!VB_NAME!'."
            call :Error "  Check VM name and VirtualBox service state."
            set /a VM_FAILED+=1
        )
        exit /b
    )

    call :Info "  ACPI shutdown signal sent. Polling for power-off..."

    :_VBoxPollLoop
        timeout /t %CFG_CHECK_INTERVAL% /nobreak >nul
        set /a VB_ELAPSED+=%CFG_CHECK_INTERVAL%

        REM Check if the VM is still in the running list
        set "VB_STILL_RUNNING=NO"
        set "VB_STATE_TMP=%TEMP%\~vbox_state_!RANDOM!.tmp"
        "!VBOX_MANAGE!" list runningvms 2>nul | findstr /c:"!VB_NAME!" > "!VB_STATE_TMP!" 2>&1
        for /f "usebackq tokens=*" %%S in ("!VB_STATE_TMP!") do (
            if not "%%S"=="" set "VB_STILL_RUNNING=YES"
        )
        del /f /q "!VB_STATE_TMP!" >nul 2>&1

        if "!VB_STILL_RUNNING!"=="NO" (
            call :OK "  VM '!VB_NAME!' powered off successfully. (!VB_ELAPSED!s)"
            set /a VM_SUCCESS+=1
            exit /b
        )

        call :Info "  VM '!VB_NAME!' still running ... (!VB_ELAPSED!s / %CFG_SHUTDOWN_TIMEOUT%s)"

        REM Timeout check
        if !VB_ELAPSED! geq %CFG_SHUTDOWN_TIMEOUT% (
            call :Warn "  TIMEOUT reached (!VB_ELAPSED!s) for VM '!VB_NAME!'."

            if /i "%CFG_FORCE_SHUTDOWN%"=="YES" (
                call :Warn "  Force power-off ENABLED -- sending poweroff command..."
                "!VBOX_MANAGE!" controlvm "!VB_NAME!" poweroff >> "!LOG_FILE!" 2>&1
                if !errorlevel! equ 0 (
                    call :OK "  VM '!VB_NAME!' forcefully powered off."
                    set /a VM_FORCED+=1
                    set /a VM_SUCCESS+=1
                ) else (
                    call :Error "  Force power-off FAILED for VM '!VB_NAME!'."
                    set /a VM_FAILED+=1
                )
            ) else (
                call :Warn "  Force shutdown is DISABLED in config."
                call :Warn "  VM '!VB_NAME!' will be left running."
                set /a VM_TIMEDOUT+=1
            )
            exit /b
        )
    goto :_VBoxPollLoop
exit /b


:: ---------------------------------------------------------------------------
:: ShutdownHyperV -- Graceful shutdown of a Hyper-V guest VM
::
::   %1 = VM name
::
:: Process:
::   1. Stop-VM with -TurnOff:$false (graceful guest OS shutdown via
::      Hyper-V Integration Services)
::   2. Poll Get-VM state every CFG_CHECK_INTERVAL seconds
::   3. If VM state is Off → SUCCESS
::   4. If CFG_SHUTDOWN_TIMEOUT exceeded → attempt -TurnOff:$true (hard stop)
:: ---------------------------------------------------------------------------
:ShutdownHyperV
    set "HV_NAME=%~1"
    set "HV_ELAPSED=0"

    REM Pre-check: is the VM actually running?
    powershell -NoProfile -Command "if ((Get-VM -Name '%HV_NAME%').State -eq 'Running') { 'YES' } else { 'NO' }" > "%TEMP%\hyperv_pre.tmp" 2>nul
    set "HV_PRE_STATE="
    for /f "usebackq tokens=*" %%R in ("%TEMP%\hyperv_pre.tmp") do set "HV_PRE_STATE=%%R"
    del /f /q "%TEMP%\hyperv_pre.tmp" >nul 2>&1

    if /i "!HV_PRE_STATE!"=="NO" (
        call :OK "  Hyper-V VM '%HV_NAME%' is already powered off."
        set /a VM_SUCCESS+=1
        exit /b
    )

    REM Send graceful shutdown via Hyper-V Integration Services
    powershell -NoProfile -Command "Stop-VM -Name '%HV_NAME%' -TurnOff:$false -Confirm:$false" >> "!LOG_FILE!" 2>&1

    if !errorlevel! neq 0 (
        call :Error "  FAILED to send graceful shutdown to Hyper-V VM '%HV_NAME%'."
        call :Error "  Check that Hyper-V Integration Services are enabled in the guest."
        set /a VM_FAILED+=1
        exit /b
    )

    call :Info "  Graceful shutdown command sent via Integration Services. Polling..."

    :_HyperVPollLoop
        timeout /t %CFG_CHECK_INTERVAL% /nobreak >nul
        set /a HV_ELAPSED+=%CFG_CHECK_INTERVAL%

        powershell -NoProfile -Command "(Get-VM -Name '%HV_NAME%').State" > "%TEMP%\hyperv_state.tmp" 2>nul
        set "HV_STATE="
        for /f "usebackq tokens=*" %%R in ("%TEMP%\hyperv_state.tmp") do set "HV_STATE=%%R"
        del /f /q "%TEMP%\hyperv_state.tmp" >nul 2>&1

        if /i "!HV_STATE!"=="Off" (
            call :OK "  Hyper-V VM '%HV_NAME%' powered off successfully. (!HV_ELAPSED!s)"
            set /a VM_SUCCESS+=1
            exit /b
        )

        call :Info "  Hyper-V VM '%HV_NAME%' state: !HV_STATE! ... (!HV_ELAPSED!s / %CFG_SHUTDOWN_TIMEOUT%s)"

        REM Timeout check
        if !HV_ELAPSED! geq %CFG_SHUTDOWN_TIMEOUT% (
            call :Warn "  TIMEOUT reached (!HV_ELAPSED!s) for Hyper-V VM '%HV_NAME%'."

            if /i "%CFG_FORCE_SHUTDOWN%"=="YES" (
                call :Warn "  Force power-off ENABLED -- sending hard stop..."
                powershell -NoProfile -Command "Stop-VM -Name '%HV_NAME%' -TurnOff:$true -Confirm:$false" >> "!LOG_FILE!" 2>&1
                if !errorlevel! equ 0 (
                    call :OK "  Hyper-V VM '%HV_NAME%' forcefully powered off."
                    set /a VM_FORCED+=1
                    set /a VM_SUCCESS+=1
                ) else (
                    call :Error "  Force power-off FAILED for Hyper-V VM '%HV_NAME%'."
                    set /a VM_FAILED+=1
                )
            ) else (
                call :Warn "  Force shutdown is DISABLED in config."
                call :Warn "  Hyper-V VM '%HV_NAME%' will be left running."
                set /a VM_TIMEDOUT+=1
            )
            exit /b
        )
    goto :_HyperVPollLoop
exit /b


:: ---------------------------------------------------------------------------
:: ShutdownVMware -- Graceful shutdown of a VMware guest VM via vmrun
::
::   %1 = Full path to .vmx file
::   %2 = VM name (for logging)
::
:: Process:
::   1. vmrun stop with "soft" mode (graceful guest OS shutdown)
::   2. Poll vmrun list every CFG_CHECK_INTERVAL seconds
::   3. If .vmx path disappears from list → SUCCESS
::   4. If CFG_SHUTDOWN_TIMEOUT exceeded → attempt "hard" stop (if enabled)
:: ---------------------------------------------------------------------------
:ShutdownVMware
    set "VR_VMX=%~1"
    set "VR_NAME=%~2"
    set "VR_ELAPSED=0"

    REM Determine VMware product type: workstation (ws) or player
    set "VR_TYPE=ws"
    echo !VMWARE_RUN! | findstr /i /c:"VMware Player" >nul 2>&1
    if !errorlevel! equ 0 set "VR_TYPE=player"

    REM Send graceful shutdown via vmrun
    "!VMWARE_RUN!" -T !VR_TYPE! stop "!VR_VMX!" soft >> "!LOG_FILE!" 2>&1

    if !errorlevel! neq 0 (
        REM Check if the VMX path still exists -- maybe the VM was already shut down
        if not exist "!VR_VMX!" (
            call :OK "  VMware VM '!VR_NAME!' appears to already be shut down (VMX not accessible)."
            set /a VM_SUCCESS+=1
        ) else (
            call :Error "  FAILED to send graceful shutdown to VMware VM '!VR_NAME!'."
            call :Error "  VMX: !VR_VMX!"
            call :Error "  Check VMware services."
            set /a VM_FAILED+=1
        )
        exit /b
    )

    call :Info "  Graceful shutdown command sent. Polling for power-off..."

    :_VMwarePollLoop
        timeout /t %CFG_CHECK_INTERVAL% /nobreak >nul
        set /a VR_ELAPSED+=%CFG_CHECK_INTERVAL%

        REM Check if the VMX path still appears in the running list
        set "VR_STILL_RUNNING=NO"
        set "VR_STATE_TMP=%TEMP%\~vmware_state_!RANDOM!.tmp"
        "!VMWARE_RUN!" -T !VR_TYPE! list > "!VR_STATE_TMP!" 2>&1
        findstr /c:"!VR_VMX!" "!VR_STATE_TMP!" >nul 2>&1
        if !errorlevel! equ 0 set "VR_STILL_RUNNING=YES"
        del /f /q "!VR_STATE_TMP!" >nul 2>&1

        if "!VR_STILL_RUNNING!"=="NO" (
            call :OK "  VMware VM '!VR_NAME!' powered off successfully. (!VR_ELAPSED!s)"
            set /a VM_SUCCESS+=1
            exit /b
        )

        call :Info "  VMware VM '!VR_NAME!' still running ... (!VR_ELAPSED!s / %CFG_SHUTDOWN_TIMEOUT%s)"

        REM Timeout check
        if !VR_ELAPSED! geq %CFG_SHUTDOWN_TIMEOUT% (
            call :Warn "  TIMEOUT reached (!VR_ELAPSED!s) for VMware VM '!VR_NAME!'."

            if /i "%CFG_FORCE_SHUTDOWN%"=="YES" (
                call :Warn "  Force power-off ENABLED -- sending hard stop..."
                "!VMWARE_RUN!" -T !VR_TYPE! stop "!VR_VMX!" hard >> "!LOG_FILE!" 2>&1
                if !errorlevel! equ 0 (
                    call :OK "  VMware VM '!VR_NAME!' forcefully powered off."
                    set /a VM_FORCED+=1
                    set /a VM_SUCCESS+=1
                ) else (
                    call :Error "  Force power-off FAILED for VMware VM '!VR_NAME!'."
                    set /a VM_FAILED+=1
                )
            ) else (
                call :Warn "  Force shutdown is DISABLED in config."
                call :Warn "  VMware VM '!VR_NAME!' will be left running."
                set /a VM_TIMEDOUT+=1
            )
            exit /b
        )
    goto :_VMwarePollLoop
exit /b


:: ############################################################################
::  REPORTING & LOGGING FUNCTIONS
:: ############################################################################


:: ---------------------------------------------------------------------------
:: SummaryReport -- Display and log a final shutdown summary
:: ---------------------------------------------------------------------------
:SummaryReport
    call :Log ""
    call :Log "============================================"
    call :Log "         SHUTDOWN SUMMARY REPORT"
    call :Log "============================================"
    call :Log "  Date / Time      : !TIMESTAMP!"
    call :Log "  Hostname          : %COMPUTERNAME%"
    call :Log "  Log file          : !LOG_FILE!"
    call :Log "  ----------------------------------------"
    call :Log "  Shutdown timeout  : %CFG_SHUTDOWN_TIMEOUT%s per VM"
    call :Log "  Force shutdown    : %CFG_FORCE_SHUTDOWN%"
    call :Log "  Host shutdown in  : %CFG_HOST_SHUTDOWN_DELAY%s"
    call :Log "  ----------------------------------------"
    call :Log "  Total VMs detected  : !VM_TOTAL!"
    call :Log "  Graceful success    : !VM_SUCCESS!"
    call :Log "  Force-shutdown used : !VM_FORCED!"
    call :Log "  Failed              : !VM_FAILED!"
    call :Log "  Timed out (no force): !VM_TIMEDOUT!"
    call :Log "  Skipped (unknown)   : !VM_SKIPPED!"
    call :Log "============================================"
    call :Log ""
exit /b


:: ---------------------------------------------------------------------------
:: Log  -- Plain white text, goes to both console and log file
:: ---------------------------------------------------------------------------
:Log
    if /i "%CFG_COLOR_OUTPUT%"=="YES" (
        echo !C_WHITE!%~1!C_RESET!
    ) else (
        echo %~1
    )
    echo [%DATE% %TIME%] %~1 >> "!LOG_FILE!"
exit /b

:: ---------------------------------------------------------------------------
:: OK   -- Green success message
:: ---------------------------------------------------------------------------
:OK
    if /i "%CFG_COLOR_OUTPUT%"=="YES" (
        echo !C_GREEN![  OK  ]!C_RESET! %~1
    ) else (
        echo [  OK  ] %~1
    )
    echo [%DATE% %TIME%] [  OK  ] %~1 >> "!LOG_FILE!"
exit /b

:: ---------------------------------------------------------------------------
:: Warn -- Yellow warning message
:: ---------------------------------------------------------------------------
:Warn
    if /i "%CFG_COLOR_OUTPUT%"=="YES" (
        echo !C_YELLOW![ WARN ]!C_RESET! %~1
    ) else (
        echo [ WARN ] %~1
    )
    echo [%DATE% %TIME%] [ WARN ] %~1 >> "!LOG_FILE!"
exit /b

:: ---------------------------------------------------------------------------
:: Error -- Red error message
:: ---------------------------------------------------------------------------
:Error
    if /i "%CFG_COLOR_OUTPUT%"=="YES" (
        echo !C_RED![ ERROR]!C_RESET! %~1
    ) else (
        echo [ ERROR] %~1
    )
    echo [%DATE% %TIME%] [ ERROR] %~1 >> "!LOG_FILE!"
exit /b

:: ---------------------------------------------------------------------------
:: Info  -- Cyan informational message
:: ---------------------------------------------------------------------------
:Info
    if /i "%CFG_COLOR_OUTPUT%"=="YES" (
        echo !C_CYAN![ INFO ]!C_RESET! %~1
    ) else (
        echo [ INFO ] %~1
    )
    echo [%DATE% %TIME%] [ INFO ] %~1 >> "!LOG_FILE!"
exit /b

:: ---------------------------------------------------------------------------
:: WarnNoLog -- Yellow warning to console ONLY (no log entry)
::              Used for countdown timers and transient UI
:: ---------------------------------------------------------------------------
:WarnNoLog
    if /i "%CFG_COLOR_OUTPUT%"=="YES" (
        echo !C_YELLOW![ WARN ]!C_RESET! %~1
    ) else (
        echo [ WARN ] %~1
    )
exit /b


:: ---------------------------------------------------------------------------
:: Init -- One-time setup: log directory, cleanup, terminal config
:: ---------------------------------------------------------------------------
:Init
    REM Create log directory
    if not exist "%CFG_LOG_DIR%" (
        mkdir "%CFG_LOG_DIR%" >nul 2>&1
        if not exist "%CFG_LOG_DIR%" (
            echo [ERROR] Cannot create log directory: "%CFG_LOG_DIR%"
            echo         Check permissions or change CFG_LOG_DIR at the top of the script.
            pause
            exit /b 1
        )
    )

    REM Purge logs older than CFG_LOG_RETENTION_DAYS
    if exist "%CFG_LOG_DIR%\*.log" (
        forfiles /p "%CFG_LOG_DIR%" /m "*.log" /d -%CFG_LOG_RETENTION_DAYS% /c "cmd /c del /f /q @path" >nul 2>&1
    )

    REM Enable ANSI/VT processing in the console (Windows 10+ / Server 2016+)
    REM This lets escape sequences produce coloured output natively.
    if /i "%CFG_COLOR_OUTPUT%"=="YES" (
        reg add "HKCU\Console" /v VirtualTerminalLevel /t REG_DWORD /d 1 /f >nul 2>&1
    )
exit /b
