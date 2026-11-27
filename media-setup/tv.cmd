@echo off
rem Run "tv setup", "tv organize D:\Downloads", "tv search" or "tv status".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tv.ps1" %*
