# Windows VM — how to build and test the Windows app

`Sources/PomoppiWindows/` only builds inside this VM (Swift can't
cross-compile from macOS to Windows). The porting history lived in
`WINDOWS_PORT_PLAN.md`, removed once the port was done; it's in git
history if needed.

## Access and toolchain

- UTM VM `pomoppi-windows` on the Mac: Apple Virtualization backend, ARM64,
  Windows 11 Pro 25H2.
- `ssh pomoppi-win` from the Mac (alias in the Mac's `~/.ssh/config`: host
  `192.168.64.2`, user `bubvm`, key `~/.ssh/pomoppi_win_vm`). `bubvm` is a
  local admin; ask for its password if it's ever needed.
- Visual Studio Build Tools 2022 (MSVC 14.44, ARM64) + Windows 11 SDK,
  Swift 6.4 (`aarch64-unknown-windows-msvc`), Git, Node.js LTS.
- Load MSVC before a manual `swift build`:
  `call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" arm64`.
  `Scripts/make-windows-app.js` finds and loads it on its own (via
  `vswhere -products *`, which a Build-Tools-only install needs).

## Syncing code into the VM

The VM clone (`C:\Users\bubvm\pomoppi`) has no GitHub remote; it takes
committed history from a bundle. Uncommitted Mac changes never transfer.

On the Mac, after `git pull`:
```sh
git bundle create /tmp/pomoppi.bundle main
scp /tmp/pomoppi.bundle pomoppi-win:'C:/Users/bubvm/pomoppi.bundle'
```
In the VM:
```bat
cd C:\Users\bubvm\pomoppi
git fetch C:\Users\bubvm\pomoppi.bundle main
git reset --hard FETCH_HEAD
node Scripts\make-windows-app.js
```
The app lands in `dist\Pomoppi-win\Pomoppi.exe` (quit the running copy
from the tray first). If a release build hangs mid-way, `rmdir /s /q
.build` and rerun: a stale `.build` has caused that before.

## Testing tray, hotkeys and windows

SSH sessions run in Windows Session 0: `Shell_NotifyIcon` and
`RegisterHotKey` fail there (`E_FAIL` / error 1459), and windows can't be
brought to the foreground. Compiling and headless tests are fine over
SSH; anything interactive runs in the logged-in desktop session, either by
hand in the VM's window or through Task Scheduler's `/it`:
```bat
schtasks /create /tn PomoppiTest /tr "C:\Users\bubvm\pomoppi\dist\Pomoppi-win\Pomoppi.exe" /sc once /st 23:59 /it /ru bubvm /f
schtasks /run /tn PomoppiTest
```
stdout isn't captured that way; log to a file and read it back over SSH.

## WinSDK / Swift interop gotchas

- Win32 flag constants (`MOD_ALT`, `NIF_ICON`, `WM_APP`, `SS_*`, `SB_*`)
  import as plain `Int32`, not `OptionSet`: cast (`UINT(MOD_ALT)`), no
  `.rawValue`.
- `BOOL`-returning calls (`GetMessageW`, `IsWindowVisible`, ...) import as
  Swift `Bool`: `while GetMessageW(&msg, nil, 0, 0) { ... }`.
- Reconstruct pointers/handles from `WPARAM`/`LPARAM` with
  `Int(bitPattern:)`/`UInt(bitPattern:)`; a range-checked `Int(wParam)`
  traps on real HDC/HWND values.
- `STATIC` text treats `&` as a mnemonic unless `SS_NOPREFIX` is set.
- `FileManager.replaceItemAt` isn't implemented in swift-corelibs-foundation
  on Windows; `Settings.swift` falls back to remove + move there.
- `SetWindowTheme` (uxtheme) isn't in the default link set, so
  `SettingsWindow.swift` loads it with `LoadLibraryW`/`GetProcAddress`.

## Recreating the VM (only if it's lost)

- Use the UTM wizard, not AppleScript (it can't attach ISOs reliably), and
  confirm the backend is Apple Virtualization, not QEMU.
- Install interactively: a second removable drive for an unattended answer
  file breaks the Apple Virtualization backend.
- If boot drops to the UEFI shell: `FS0:`, `cd efi\boot`, `bootaa64.efi`,
  then press a key at "Press any key to boot from CD".
- Skip OOBE's network step with Shift+F10 (plus Fn on a Mac keyboard),
  `start ms-cxh:localonly`.
- Don't install UTM's Windows Guest Tools: its display driver renders black
  on this combination (recover via Safe Mode, uninstall the display driver).
- SSH server: elevated prompt, `Add-WindowsCapability -Online -Name
  OpenSSH.Server~~~~0.0.1.0`, `Start-Service sshd`, firewall rule for port
  22. An admin account's key goes in
  `C:\ProgramData\ssh\administrators_authorized_keys`, restricted with
  `icacls` to Administrators + SYSTEM.
