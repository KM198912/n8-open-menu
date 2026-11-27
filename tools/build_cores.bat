@echo off
rem n8-open: build all FPGA cores - double-click, or with the same options
rem as tools/build_cores.py (e.g. build_cores.bat --only n8_mmc2)
cd /d "%~dp0.."
python tools\build_cores.py %*
pause
