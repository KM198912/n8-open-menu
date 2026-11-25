@echo off
rem Build the n8-open menu -> menu\build\OS.BIN (+ the hello.nes test ROM)
rem cc65: ca65/ld65 on PATH, or set CC65 to the cc65 bin folder
cd /d "%~dp0"
if "%CC65%"=="" (
    set CA65=ca65
    set LD65=ld65
) else (
    set CA65=%CC65%\ca65
    set LD65=%CC65%\ld65
)
where "%CA65%" >nul 2>nul || if not exist "%CA65%.exe" goto :nocc65
if not exist build mkdir build
if not exist font.chr python tools\mk_font.py || goto :fail
"%CA65%" -g -o build\main.o src\main.s || goto :fail
"%LD65%" -C os.cfg -o build\OS.BIN -m build\OS.map -Ln build\OS.lbl build\main.o || goto :fail
"%CA65%" -o build\hello.o tests\hello.s || goto :fail
"%LD65%" -C tests\nrom.cfg -o build\hello.nes build\hello.o || goto :fail
echo OK: build\OS.BIN build\hello.nes
exit /b 0
:nocc65
echo cc65 not found: put ca65/ld65 on PATH or set CC65=^<cc65 bin folder^>
exit /b 1
:fail
echo BUILD FAILED
exit /b 1
