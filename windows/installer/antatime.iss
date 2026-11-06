; Inno-Setup-Skript für den Windows-Installer. Wird von
; scripts/build_windows.sh aufgerufen (Version/Pfade per /D-Parameter).
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
AppId={{7C1B5E1E-4F0B-4C4B-9C61-2B8E3F6A9D41}
AppName=AnTaTime
AppVersion={#AppVersion}
AppPublisher=lotterfriends
AppPublisherURL=https://github.com/lotterfriends/antatime
DefaultDirName={autopf}\AnTaTime
DefaultGroupName=AnTaTime
DisableProgramGroupPage=yes
; Installation ohne Administratorrechte möglich (Benutzer kann wählen)
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=AnTaTime-{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\antatime.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\AnTaTime"; Filename: "{app}\antatime.exe"
Name: "{autodesktop}\AnTaTime"; Filename: "{app}\antatime.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\antatime.exe"; Description: "{cm:LaunchProgram,AnTaTime}"; Flags: nowait postinstall skipifsilent
