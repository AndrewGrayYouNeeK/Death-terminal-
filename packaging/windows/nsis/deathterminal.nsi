; DeathTerminal per-user NSIS installer.
; Built from a staged `zig build release -Dtarget=x86_64-windows` tree:
;   makensis -DVERSION=0.1.0 -DVER_QUAD=0.1.0.0 -DSTAGE=... -DOUT=... -DICON=... deathterminal.nsi
; The exe already carries the icon resource. This installer adds a Start
; Menu shortcut that launches `--gui`.
;
; TODO(signing): Authenticode-sign deathterminal.exe and this setup exe.
; No certificate is available in CI. See packaging/SIGNING.md.

Unicode true
!include "MUI2.nsh"

!ifndef VERSION
  !error "VERSION is required"
!endif
!ifndef VER_QUAD
  !error "VER_QUAD (a.b.c.d) is required"
!endif
!ifndef STAGE
  !error "STAGE is required"
!endif
!ifndef OUT
  !error "OUT is required"
!endif
!ifndef ICON
  !error "ICON is required"
!endif

Name "DeathTerminal ${VERSION}"
OutFile "${OUT}"
InstallDir "$LOCALAPPDATA\DeathTerminal"
InstallDirRegKey HKCU "Software\DeathTerminal" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

VIProductVersion "${VER_QUAD}"
VIAddVersionKey "ProductName" "DeathTerminal"
VIAddVersionKey "FileDescription" "DeathTerminal installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "Public domain (The Unlicense)"
VIAddVersionKey "CompanyName" "DeathTerminal"

Section "DeathTerminal" SecMain
  SectionIn RO
  SetOutPath "$INSTDIR"
  File "${STAGE}/deathterminal.exe"
  File "${STAGE}/README.md"
  File "${STAGE}/LICENSE"
  File "${STAGE}/CHANGELOG.md"
  File "${STAGE}/config.example.lua"
  File /r "${STAGE}/docs"
  File /r "${STAGE}/examples"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\DeathTerminal" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\DeathTerminal" "Version" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeathTerminal" "DisplayName" "DeathTerminal"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeathTerminal" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeathTerminal" "Publisher" "DeathTerminal"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeathTerminal" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeathTerminal" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeathTerminal" "DisplayIcon" "$INSTDIR\deathterminal.exe"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeathTerminal" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeathTerminal" "NoRepair" 1

  CreateDirectory "$SMPROGRAMS\DeathTerminal"
  CreateShortcut "$SMPROGRAMS\DeathTerminal\DeathTerminal.lnk" "$INSTDIR\deathterminal.exe" "--gui" "$INSTDIR\deathterminal.exe" 0
  CreateShortcut "$SMPROGRAMS\DeathTerminal\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\deathterminal.exe"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\CHANGELOG.md"
  Delete "$INSTDIR\config.example.lua"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir /r "$INSTDIR\docs"
  RMDir /r "$INSTDIR\examples"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\DeathTerminal\DeathTerminal.lnk"
  Delete "$SMPROGRAMS\DeathTerminal\Uninstall.lnk"
  RMDir "$SMPROGRAMS\DeathTerminal"
  DeleteRegKey HKCU "Software\DeathTerminal"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeathTerminal"
SectionEnd
