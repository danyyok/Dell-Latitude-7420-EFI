@echo off
setlocal DisableDelayedExpansion

echo Generate one SMBIOS set for MacBookPro16,2 in GenSMBIOS.
echo Record Serial, Board Serial, SmUUID, and ROM, then quit GenSMBIOS.
echo Do not select or modify a plist in GenSMBIOS; this helper writes both build profiles.
echo.
call "%~dp0GenSMBIOS\GenSMBIOS.bat"
if errorlevel 1 goto failed

echo.
echo Paste the four values printed by GenSMBIOS.
set /p "SERIAL=Serial: "
set /p "MLB=Board Serial / MLB: "
set /p "UUID=SmUUID: "
set /p "ROM=ROM (12 hex characters): "

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare-efi.ps1" -Serial "%SERIAL%" -MLB "%MLB%" -UUID "%UUID%" -ROM "%ROM%"
if errorlevel 1 goto failed
exit /b 0

:failed
echo.
echo EFI preparation failed. The checked-in EFI templates were not modified.
pause
exit /b 1
