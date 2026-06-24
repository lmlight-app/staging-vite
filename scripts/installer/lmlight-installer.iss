; AI Server Windows installer (Inno Setup 6+).
;
; User-facing branding is "AI Server" — matches the legacy
; `irm | iex` flow's display ("AI Server インストーラー for Windows")
; so existing users see continuity on upgrade. Internal binary,
; install directory ("db"), CI artefact names retain `lmlight` to
; avoid breaking existing release URLs and PyInstaller bundle naming.
;
; Compile via ISCC on Windows or via the GitHub Actions
; build-installer-windows job. Output: ai-server-installer-windows.exe
;
; Bundles the prebuilt backend binary. PostgreSQL, pgvector, and
; Ollama are installed (via winget) by post-install.ps1 — keeping the
; installer compact rather than embedding gigabytes of dependencies.

#define AppName "AI Server"
#define AppVersion "1.0.0"
#define AppPublisher "AI Server"
; CI artefact filename. Once installed it gets renamed to api.exe so
; the legacy `irm | iex` flow's post-install logic + Start scripts
; (`db start` etc) work without the EXE installer needing parallel
; codepaths.
#define BackendArtefact "lmlight-vite-windows-amd64.exe"
#define AppExeName "api.exe"
#define InstallerOutput "ai-server-installer-windows"

[Setup]
; Stable random GUID — keep across releases so updates upgrade in place.
AppId={{6E7B1F2C-4A8D-4F1E-B5C7-8D9E0A1B2C3D}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
; Install location matches the legacy `irm | iex` flow ($env:LOCALAPPDATA\db)
; so existing PowerShell-installed users can upgrade in place by re-running
; the EXE — same .env, same DB credentials.
DefaultDirName={localappdata}\db
DefaultGroupName={#AppName}
AllowNoIcons=yes
OutputDir=output
OutputBaseFilename={#InstallerOutput}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; PostgreSQL setup requires admin: winget installs PG to Program Files,
; pgvector.dll has to be dropped into PG's lib/extension dirs (also under
; Program Files), and Start-Service for `postgresql-x64-NN` is an
; SCM-privileged operation. Run-as-current-user fails silently on all
; three. Force a single UAC prompt up front instead.
PrivilegesRequired=admin
UninstallDisplayIcon={app}\{#AppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DefaultDialogFontName=Yu Gothic UI

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; The CI job places the prebuilt backend EXE next to the .iss file
; before invoking ISCC. Relative path keeps the script reusable for
; local Windows builds too.
Source: "{#BackendArtefact}"; DestDir: "{app}"; DestName: "{#AppExeName}"; Flags: ignoreversion
Source: "post-install.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion

[Icons]
; Shortcuts run start.ps1 instead of api.exe directly so the
; PG service + ollama serve are brought up too. api.exe alone
; would 502 on chat if Ollama wasn't already running.
Name: "{group}\{#AppName}"; \
  Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\start.ps1"""; \
  WorkingDir: "{app}"; \
  IconFilename: "{app}\{#AppExeName}"
Name: "{group}\{#AppName} を停止"; \
  Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\stop.ps1"""; \
  WorkingDir: "{app}"; \
  IconFilename: "{app}\{#AppExeName}"
Name: "{group}\{#AppName} をアンインストール"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; \
  Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\start.ps1"""; \
  WorkingDir: "{app}"; \
  IconFilename: "{app}\{#AppExeName}"; \
  Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "デスクトップショートカットを作成"; GroupDescription: "追加タスク:"; Flags: unchecked

[Run]
; Stage 1: dependency setup (PostgreSQL + pgvector + Ollama).
; -InstallDir tells the script where the backend EXE landed so it
; can write the .env there. waituntilterminated so the wizard's
; progress page reflects real PG/Ollama install time (1-3 min on
; first run).
;
; NOT runhidden: the script may need to prompt for the postgres
; super-user password (PG installer forces the user to set one and
; we cannot guess it), and the user should see PG/Ollama install
; progress + any failures rather than silently hanging on a hidden
; window. A non-zero exit aborts the wizard so the user knows
; something failed.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\post-install.ps1"" -InstallDir ""{app}"""; \
  StatusMsg: "依存パッケージをインストール中 (PostgreSQL / Ollama)..."; \
  Flags: waituntilterminated

; Stage 2: optional auto-launch on first install (skipped on /silent).
; Goes through start.ps1 to ensure PG / Ollama come up too —
; api.exe alone would chat-fail if Ollama wasn't running.
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\start.ps1"""; \
  Description: "{#AppName} を起動する"; \
  Flags: postinstall nowait skipifsilent

[UninstallDelete]
; Generated artefacts that Inno's built-in uninstall doesn't track.
; The user's actual files (under %LOCALAPPDATA%\db\files) are kept —
; users delete that manually if they want a clean wipe.
Type: filesandordirs; Name: "{app}\static"
Type: filesandordirs; Name: "{app}\scripts"

[Code]
function InitializeSetup(): Boolean;
var
  Version: TWindowsVersion;
begin
  GetWindowsVersionEx(Version);
  if (Version.Major < 10) or
     ((Version.Major = 10) and (Version.Build < 17763)) then
  begin
    MsgBox(
      'Windows 10 1809 (build 17763) 以降を推奨します。' + #13#10 +
      '古いバージョンでは PostgreSQL と Ollama を手動でインストールする必要があります。',
      mbInformation, MB_OK
    );
  end;
  Result := True;
end;
