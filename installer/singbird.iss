; singbird Windows 安装包脚本 (Inno Setup 6)
; 编译: ISCC.exe singbird.iss /DAppVer=<版本> /DOutName=<输出文件名>
; dev.sh 的 installer 命令负责传参 (版本取自 pubspec.yaml)
; 相对路径均以本 .iss 所在目录 (installer/) 为基准

#define AppName "singbird"
#ifndef AppVer
  #define AppVer "0.0.0"
#endif
#ifndef OutName
  #define OutName "singbird-setup-" + AppVer + "-x64"
#endif

[Setup]
AppId={{a2a97840-5348-4088-b216-813f5c9217d0}
AppName={#AppName}
AppVersion={#AppVer}
AppPublisher=singbird
AppPublisherURL=https://github.com/SagerNet/sing-box
DefaultDirName={autopf}\singbird
DefaultGroupName=singbird
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename={#OutName}
Compression=lzma2/max
SolidCompression=yes
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\singbird.exe
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
WizardStyle=modern

[Languages]
; ChineseSimplified.isl 是社区翻译, Inno 安装器不捆绑 — 已 vendor 到 installer/languages/
Name: "chinesesimplified"; MessagesFile: "languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

; 排除运行时产物 (日志/数据库会随程序运行重新生成, 不该进安装包)
[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "singbox.log,monitor.db,*.log"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\singbird"; Filename: "{app}\singbird.exe"
Name: "{autodesktop}\singbird"; Filename: "{app}\singbird.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\singbird.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
