; Scripts/pomoppi.iss — Inno Setup script for Pomoppi's Windows installer.
; Compiled by ISCC.exe (Scripts/make-windows-app.js's --installer path,
; after the existing release build/dist-assembly step — this script
; packages dist/Pomoppi-win/'s already-assembled contents, it doesn't
; rebuild anything itself). MyAppVersion/MySourceDir/MyOutputDir are
; passed in from the command line (/DMyAppVersion=... /DMySourceDir=...
; /DMyOutputDir=...) by make-windows-app.js, which reads pomoppiVersion
; via Scripts/version.js — the same single source of truth every other
; packaging script already reads, nothing hardcoded here. The #ifndef
; fallbacks below only matter for a bare manual `ISCC.exe pomoppi.iss` run.
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef MySourceDir
  #define MySourceDir "..\dist\Pomoppi-win"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "..\dist"
#endif
#define MyAppName "Pomoppi"
#define MyAppExeName "Pomoppi.exe"
#define MyAppPublisher "Luca Bessi Aristei"

[Setup]
; Fixed AppId (not the app name) — Inno uses this, not AppName/AppVersion,
; to recognize "this is the same product" across versions, which is what
; lets an upgrade install over a previous one instead of side-by-side.
; Never change this for an ordinary version bump.
AppId={{EC3E39B4-1C22-4A15-A54C-769ACA07A1C8}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
; Per-user install, no UAC prompt: {autopf} resolves to {pf} only in an
; admin install; with PrivilegesRequired=lowest the only install mode
; available is non-admin, so this always lands at
; %LOCALAPPDATA%\Programs\Pomoppi.
DefaultDirName={autopf}\Pomoppi
DefaultGroupName=Pomoppi
PrivilegesRequired=lowest
OutputDir={#MyOutputDir}
OutputBaseFilename=Pomoppi-Setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
#if FileExists(SourcePath + "..\assets\pomoppi.ico")
SetupIconFile={#SourcePath}..\assets\pomoppi.ico
#endif
; Deliberately no AppMutex directive here, even though main.swift's
; single-instance guard is a named mutex Setup could check for — verified
; live in the VM that AppMutex has no auto-close ability of its own: per
; Inno's own docs it only ever shows a blocking "please close it now,
; then click OK" message box, checked at Setup startup, before
; CloseApplications' own [Files]-driven RestartManager scan ever runs —
; and that message box has no silent/automatic "yes, go ahead" answer
; (/SUPPRESSMSGBOXES defaults it to Cancel, aborting the install). Setting
; it would only get in CloseApplications' way. CloseApplications=yes alone
; is what actually does the job: Setup finds Pomoppi.exe holding the DLLs
; it needs to replace via RestartManager and closes it automatically —
; confirmed end-to-end in the VM (log line "Can use RestartManager to
; avoid reboot? Yes", "Shutting down applications using our files.",
; process gone from tasklist, install completes) with no AppMutex set at
; all. RestartApplications stays no: main.swift never calls
; RegisterApplicationRestart, so Windows couldn't restart it after anyway
; (see RestartApplications' own doc) — the finish-page Launch checkbox
; below is how a normal (non-upgrade) install offers to relaunch instead.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"

[Registry]
; The app itself (LoginItem.swift) owns writing this value while running —
; this entry does nothing at install time (ValueType: none means "don't
; write a value," just ensure the key exists, which it already does as a
; standard Windows key) and only ever deletes it, at uninstall, so a
; user's launch-at-login registration doesn't outlive the app it points at.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Pomoppi"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Pomoppi now"; Flags: nowait postinstall skipifsilent
