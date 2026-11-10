; Shronshiki installer for Windows (Inno Setup 6).
; Built by .github/workflows/shronshiki-release.yml after `flutter build windows`.
; Installs per user (no admin rights), adds shortcuts and registers the
; shronshiki:// link scheme so room invites open in the app.

#define AppVersion GetEnv("APP_VERSION")
#if AppVersion == ""
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{8F2B6C1E-5A7D-4E3B-9C21-6D4A0B7F1E35}
AppName=Shronshiki
AppVersion={#AppVersion}
AppPublisher=Shronshiki
DefaultDirName={localappdata}\Programs\Shronshiki
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\build\installer
OutputBaseFilename=Shronshiki-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\shronshiki.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Flutter's Dart code lives in app.so, which must also be unlocked for updates.
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll,*.so
; [Run] starts exactly the installed copy, without Restart Manager relaunches.
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Shronshiki"; Filename: "{app}\shronshiki.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Shronshiki"; Filename: "{app}\shronshiki.exe"; WorkingDir: "{app}"; Check: DesktopShortcutRequired

[Registry]
Root: HKCU; Subkey: "Software\Classes\shronshiki"; ValueType: string; ValueData: "URL:Shronshiki"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\shronshiki"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\shronshiki\DefaultIcon"; ValueType: string; ValueData: """{app}\shronshiki.exe"",0"
Root: HKCU; Subkey: "Software\Classes\shronshiki\shell\open\command"; ValueType: string; ValueData: """{app}\shronshiki.exe"" ""%1"""

[Run]
Filename: "{app}\shronshiki.exe"; Description: "{cm:LaunchProgram,Shronshiki}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
; Update from inside the app runs silently: start the new version afterwards.
Filename: "{app}\shronshiki.exe"; WorkingDir: "{app}"; Flags: nowait; Check: WizardSilent

[Code]
function DesktopShortcutRequired: Boolean;
begin
  { Repair an existing desktop shortcut even if the task was not selected in
    the original installation. }
  Result := WizardIsTaskSelected('desktopicon') or
    FileExists(ExpandConstant('{autodesktop}\Shronshiki.lnk'));
end;
