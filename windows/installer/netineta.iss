; netineta — Windows installer (Inno Setup)
; Packages the Flutter release bundle plus the AmneziaWG tunnel host
; (awgtunnel.exe), Wintun, and the app-local VC++ runtime, so the app runs on a
; clean PC with no manual file copying.

#define MyAppName "netineta"
#define MyAppVersion "0.2.13"
#define MyAppPublisher "netineta"
#define MyAppExeName "netineta.exe"
; Paths are relative to this .iss file (windows\installer\).
#define SourceDir "..\..\build\windows\x64\runner\Release"
; x64 VC++ runtime DLLs staged here (ISCC is 32-bit, so it can't read the real
; System32 directly without WOW64 redirection).
#define VendorDir "vendor"

[Setup]
AppId={{F9D542AC-E215-43B5-AE22-7CD01BE155BA}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=..\..\build\installer
OutputBaseFilename=netineta-setup-{#MyAppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Installing into Program Files and creating the tunnel service needs admin.
; The app itself also self-elevates on every launch (requireAdministrator).
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; During auto-update the app launches this installer; close any running copy so
; its files can be replaced, but don't relaunch it automatically (the [Run]
; section already offers to start the app at the end).
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
; The complete Flutter release bundle: netineta.exe, data\ (app.so, assets,
; icudtl.dat), plugin DLLs, awgtunnel.exe and wintun.dll.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; Visual C++ runtime, app-local, so no separate redistributable is required.
Source: "{#VendorDir}\msvcp140.dll";      DestDir: "{app}"; Flags: ignoreversion
Source: "{#VendorDir}\vcruntime140.dll";  DestDir: "{app}"; Flags: ignoreversion
Source: "{#VendorDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}";           Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Удалить {#MyAppName}";   Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}";     Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Remove any leftover AmneziaWG tunnel service before files are deleted.
Filename: "{app}\awgtunnel.exe"; Parameters: "/uninstalltunnelservice netineta-awg"; Flags: runhidden; RunOnceId: "RemoveAwgTunnel"
