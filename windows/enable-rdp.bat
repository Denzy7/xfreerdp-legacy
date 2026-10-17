@echo off
rem Enable Remote Desktop on this machine. Run as Administrator.

net session >nul 2>&1
if errorlevel 1 (
  echo Run this as Administrator: right-click, Run as administrator.
  pause
  exit /b 1
)

echo == Allow Remote Desktop connections
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f

echo == Services
sc config TermService start= auto
sc config SessionEnv start= demand
sc config UmRdpService start= demand

echo == Firewall: allow TCP 3389, then turn the firewall back on
netsh advfirewall firewall delete rule name="RDP 3389" >nul 2>&1
netsh advfirewall firewall add rule name="RDP 3389" dir=in action=allow protocol=TCP localport=3389 profile=any
netsh advfirewall set allprofiles state on

echo == Restart Remote Desktop service
net stop TermService /y
net start TermService

echo == Listening on 3389?
netstat -an | find ":3389"
if errorlevel 1 (echo NOT listening on 3389) else (echo OK: Remote Desktop is listening)
pause
