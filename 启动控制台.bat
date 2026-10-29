@echo off
chcp 65001 >nul
cd /d "%~dp0"

rem Find real Python installation (avoid WindowsApps stub)
set "PYDIR="
for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*") do if exist "%%D\python.exe" set "PYDIR=%%D"
if defined PYDIR goto :rungui
where py >nul 2>nul
if %errorlevel%==0 goto :runpy
where python >nul 2>nul
if %errorlevel%==0 goto :run
goto :nopython

:rungui
rem Launch GUI panel without console window (double-click friendly)
start "" "%PYDIR%\pythonw.exe" sicn_gui.py
goto :end

:runpy
start "" pyw sicn_gui.py
goto :end

:run
start "" pythonw sicn_gui.py
goto :end

:nopython
echo [ERROR] Python is not found. Please install Python 3.10+ and check "Add Python to PATH":
echo   https://www.python.org/downloads/
echo Then double-click this file again.
echo.

:end