#ifndef PackageVersion
  #error PackageVersion must match the Windows project version.
#endif
#ifndef PublishDir
  #error PublishDir must point at the self-contained publish output.
#endif
[Setup]
AppId={{81C1F6F7-60EE-47E3-A95B-EB9AF10135F6}
AppName=WordMath
AppVersion={#PackageVersion}
AppPublisher=EdinsHu
AppPublisherURL=https://github.com/EdinsHu/LLM-in-Word
DefaultDirName={localappdata}\Programs\WordMath
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=WordMath-{#PackageVersion}-windows-x64-setup
UninstallDisplayIcon={app}\WordMath.exe
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\WordMath\WordMath"; Filename: "{app}\WordMath.exe"
Name: "{userprograms}\WordMath\Test Word integration"; Filename: "{app}\WordMath.exe"; Parameters: "--verify-word"

[Run]
Filename: "{app}\WordMath.exe"; Description: "Start WordMath"; Flags: nowait postinstall skipifsilent
