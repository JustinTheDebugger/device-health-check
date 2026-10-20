@echo off
cd /d "%~dp0"

set "DEVICE_HEALTH_API_URL=https://device-health-api.onrender.com/api/ingest"
set "DEVICE_HEALTH_API_TOKEN=VPzu+PcVwFB/LzZda6GYcxAWSrhaEfu5bkD6nxUOh+o="

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Collect-DeviceHealth.ps1"

echo.
pause