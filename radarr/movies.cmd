@echo off
rem Run "movies setup", "movies organize D:\Downloads", "movies search" or "movies status".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0movies.ps1" %*
