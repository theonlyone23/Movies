@echo off
rem Run "library scan D: E:", "library dedupe D: E:", "library consolidate D: E: -To G:", "library purge D: E:" or "library undo".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0library.ps1" %*
