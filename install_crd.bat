@echo off
setlocal enableextensions enabledelayedexpansion

rem ============================================================
rem  Chrome Remote Desktop - Instalação e registo headless (BAT)
rem  - Sem PowerShell
rem  - Pede AuthCode e PIN via HTA (PIN mascarado)
rem  - Opcional: instalar Google Chrome com parâmetro -with-chrome
rem  Execução: botão direito > Executar como administrador
rem ============================================================

rem --- Verificar Admin ---
whoami /groups | find /i "S-1-16-12288" >nul
if errorlevel 1 (
  echo [ERRO] Corre este .BAT como Administrador.
  pause
  exit /b 1
)

set "TMPDIR=%TEMP%\crd_setup"
if not exist "%TMPDIR%" mkdir "%TMPDIR%"

set "CRD_MSI_URL=https://dl.google.com/dl/edgedl/chrome-remote-desktop/chromeremotedesktophost.msi"
set "CRD_MSI=%TMPDIR%\chromeremotedesktophost.msi"

set "CHROME_MSI_URL=https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"
set "CHROME_MSI=%TMPDIR%\googlechromestandaloneenterprise64.msi"

set "CURL=curl.exe"
where %CURL% >nul 2>&1
if errorlevel 1 ( set "USEBITS=1" ) else ( set "USEBITS=0" )

echo.
echo === Descarregar CRD Host ===
if "%USEBITS%"=="1" (
  bitsadmin /transfer dlcrd /download /priority normal "%CRD_MSI_URL%" "%CRD_MSI%" || (
    echo [ERRO] Falha no download do CRD (bitsadmin).
    exit /b 1
  )
) else (
  "%CURL%" -f -L "%CRD_MSI_URL%" -o "%CRD_MSI%"
  if errorlevel 1 (
    echo [ERRO] Falha no download do CRD (curl).
    exit /b 1
  )
)

if "%~1"=="-with-chrome" (
  echo.
  echo === Descarregar Google Chrome (opcional) ===
  if "%USEBITS%"=="1" (
    bitsadmin /transfer dlchrome /download /priority normal "%CHROME_MSI_URL%" "%CHROME_MSI%" || (
      echo [ERRO] Falha no download do Chrome (bitsadmin).
      exit /b 1
    )
  ) else (
    "%CURL%" -f -L "%CHROME_MSI_URL%" -o "%CHROME_MSI%"
    if errorlevel 1 (
      echo [ERRO] Falha no download do Chrome (curl).
      exit /b 1
    )
  )
)

echo.
echo === Instalar ===
if "%~1"=="-with-chrome" (
  echo [INFO] A instalar Google Chrome...
  msiexec /i "%CHROME_MSI%" /qn /norestart
  if errorlevel 1 (
    echo [ERRO] Falha na instalacao do Chrome.
    exit /b 1
  )
)

echo [INFO] A instalar Chrome Remote Desktop Host...
msiexec /i "%CRD_MSI%" /qn /norestart
if errorlevel 1 (
  echo [ERRO] Falha na instalacao do CRD Host.
  exit /b 1
)

rem --- Localizar remoting_start_host.exe ---
set "CRD_BASE=%ProgramFiles(x86)%\Google\Chrome Remote Desktop"
set "START_HOST="
for /r "%CRD_BASE%" %%F in (remoting_start_host.exe) do (
  set "START_HOST=%%~fF"
  goto :foundhost
)
:foundhost
if "%START_HOST%"=="" (
  echo [ERRO] Nao encontrei remoting_start_host.exe em "%CRD_BASE%".
  exit /b 1
)

rem --- Prompt HTA para AuthCode/PIN/DeviceName ---
set "HTA=%TMPDIR%\prompt.hta"
set "OUT=%TMPDIR%\crd_inputs.txt"
if exist "%OUT%" del /q "%OUT%"

>%HTA% echo ^<html^>
>>%HTA% echo ^<head^>^<title^>CRD Setup^</title^>^</head^>
>>%HTA% echo ^<body style='font-family:Segoe UI;margin:16px'^>
>>%HTA% echo ^<h3^>Chrome Remote Desktop – Registo Headless^</h3^>
>>%HTA% echo ^<p^>1) Abra ^<a href='https://remotedesktop.google.com/headless'^>https://remotedesktop.google.com/headless^</a^>, escolha **Windows**.^</p^>
>>%HTA% echo ^<p^>2) Copie o ^<b^>AuthCode^</b^> indicado e cole abaixo.^</p^>
>>%HTA% echo ^<div^>Nome do dispositivo: ^<input id='name' style='width:360px' value='%COMPUTERNAME%' /^>^</div^>^<br^>
>>%HTA% echo ^<div^>AuthCode:^ ^<textarea id='auth' style='width:360px;height:90px'^>^</textarea^>^</div^>^<br^>
>>%HTA% echo ^<div^>PIN (>=6 digitos): ^<input id='pin' type='password' style='width:180px' /^>^</div^>^<br^>
>>%HTA% echo ^<button onclick='ok()'^>OK^</button^> ^<button onclick='window.close()'^>Cancelar^</button^>
>>%HTA% echo ^<script^>
>>%HTA% echo function ok(){var a=document.getElementById('auth').value.trim();var p=document.getElementById('pin').value.trim();var n=document.getElementById('name').value.trim();if(a.length^<10){alert("AuthCode em falta.");return;}if(!/^\d{6,}$/.test(p)){alert("PIN invalido. Use apenas digitos e minimo 6.");return;}var fso=new ActiveXObject("Scripting.FileSystemObject");var f=fso.CreateTextFile("%OUT% ",true);f.WriteLine("AUTH="+a);f.WriteLine("PIN="+p);f.WriteLine("NAME="+n);f.Close();window.close();}
>>%HTA% echo ^</script^>
>>%HTA% echo ^</body^>^</html^>

echo [INFO] A pedir AuthCode e PIN...
mshta.exe "%HTA%"

if not exist "%OUT%" (
  echo [INFO] Operacao cancelada pelo utilizador.
  exit /b 1
)

for /f "usebackq tokens=1,* delims==" %%A in ("%OUT%") do (
  if /i "%%A"=="AUTH" set "AUTH=%%B"
  if /i "%%A"=="PIN"  set "PIN=%%B"
  if /i "%%A"=="NAME" set "DEVNAME=%%B"
)

if "%DEVNAME%"=="" set "DEVNAME=%COMPUTERNAME%"
set "REDIRECT=https://remotedesktop.google.com/_/oauthredirect"

echo.
echo === Registar host no CRD ===
echo Dispositivo: %DEVNAME%
"%START_HOST%" --code="%AUTH%" --redirect-url="%REDIRECT%" --name="%DEVNAME%" --pin=%PIN%
if errorlevel 1 (
  echo [ERRO] Registo falhou. O AuthCode e de uso unico; gere outro e tente novamente.
  exit /b 1
)

echo [OK] Acesso nao assistido ativado. Ver em https://remotedesktop.google.com/access
del /q "%OUT%" >nul 2>&1
del /q "%HTA%" >nul 2>&1
exit /b 0
