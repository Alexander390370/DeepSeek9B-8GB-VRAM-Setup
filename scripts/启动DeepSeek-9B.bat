@echo off
title DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic (Q4_K_M, vision)
echo.
echo ============================================================
echo   DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic
echo   Q4_K_M - 5.24 GiB - distilled from DeepSeek-V4-Pro
echo ============================================================
echo.
echo   Context: 32768 (32K)  ^|  Port: 8440  ^|  Alias: deepseek9b
echo   Vision : mmproj-f16 loaded (text + image + video)
echo   VRAM   : ~7449 MiB of 8188 MiB on an 8GB laptop GPU
echo.
echo   NOTE: 32K is used because mmproj costs ~0.9 GB VRAM.
echo         For 48K context, disable vision (edit the .sh).
echo.
echo   [1/3] Checking WSL ...
wsl.exe -d Ubuntu -e bash -c "true" >nul 2>&1
if errorlevel 1 (
    echo         WSL not ready, starting Ubuntu ...
    wsl.exe -d Ubuntu -e bash -c "true" >nul 2>&1
    timeout /t 6 >nul
)
echo         ok
echo.
echo   [2/3] Stopping any running local model ...
wsl.exe -d Ubuntu -e bash -c "pkill -f 'llama-server' 2>/dev/null; sleep 3"
echo         done
echo.
echo   [3/3] Starting DeepSeek 9B ...
echo.
wsl.exe -d Ubuntu -e bash -c "bash ~/bonsai/start-deepseek9b.sh start 32768"
if errorlevel 1 (
    echo.
    echo   [ERROR] start failed. Log:
    echo     wsl -d Ubuntu -e bash -c "tail -30 ~/bonsai/deepseek9b.log"
    echo.
    pause
    exit /b 1
)
echo.
echo ============================================================
echo   Ready.  text + image + video
echo ============================================================
echo.
echo   Endpoint:  http://127.0.0.1:8440/v1
echo   Model id:  deepseek9b
echo.
echo   Test:
echo     wsl -d Ubuntu -e bash -c "bash ~/bonsai/start-deepseek9b.sh test"
echo   Status:
echo     wsl -d Ubuntu -e bash -c "bash ~/bonsai/start-deepseek9b.sh status"
echo   Stop:
echo     wsl -d Ubuntu -e bash -c "bash ~/bonsai/start-deepseek9b.sh stop"
echo.
echo   Keep this window open OR let the daemon mode handle restarts:
echo     wsl -d Ubuntu -e bash -c "bash ~/bonsai/start-deepseek9b.sh daemon"
echo.
timeout /t 12
