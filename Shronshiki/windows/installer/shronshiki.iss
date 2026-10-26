; Shronshiki installer for Windows (Inno Setup 6).
; Built by .github/workflows/shronshiki-windows.yml after `flutter build windows`.
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

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Shronshiki"; Filename: "{app}\shronshiki.exe"
Name: "{autodesktop}\Shronshiki"; Filename: "{app}\shronshiki.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\shronshiki"; ValueType: string; ValueData: "URL:Shronshiki"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\shronshiki"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\shronshiki\DefaultIcon"; ValueType: string; ValueData: """{app}\shronshiki.exe"",0"
Root: HKCU; Subkey: "Software\Classes\shronshiki\shell\open\command"; ValueType: string; ValueData: """{app}\shronshiki.exe"" ""%1"""

[Run]
Filename: "{app}\shronshiki.exe"; Description: "{cm:LaunchProgram,Shronshiki}"; Flags: nowait postinstall skipifsilent
