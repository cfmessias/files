<#
.SYNOPSIS
  Instala o Chrome Remote Desktop Host e ativa acesso não assistido pedindo AuthCode/PIN em tempo de execução.

.DESCRIPTION
  - Descarrega e instala silenciosamente o CRD Host (MSI oficial).
  - (Opcional) instala o Google Chrome (MSI enterprise).
  - Solicita AuthCode e PIN de forma segura (sem eco) e regista o host headless.
  - Não guarda o PIN; usa-o apenas para o registo no processo.

.PARAMETER InstallChrome
  Também instala Google Chrome (opcional).

.PARAMETER RegisterUnattended
  Pede AuthCode e PIN e regista o host (acesso não assistido).

.PARAMETER DeviceName
  Nome que aparecerá no CRD (por defeito, nome do computador).

.EXAMPLES
  # Só instalar CRD Host
  .\Install-CRD.ps1

  # Instalar Chrome + CRD Host
  .\Install-CRD.ps1 -InstallChrome

  # Instalar e registar host (pede AuthCode/PIN)
  .\Install-CRD.ps1 -RegisterUnattended

.NOTES
  Executar em PowerShell "Como Administrador".
#>

[CmdletBinding()]
param(
  [switch]$InstallChrome,
  [switch]$RegisterUnattended,
  [string]$DeviceName = $env:COMPUTERNAME
)

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "Executa este script em PowerShell **como Administrador**."
  }
}

function Download-File($Url, $OutPath) {
  Write-Host "↓ $Url" -ForegroundColor Cyan
  try {
    Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing -ErrorAction Stop
  } catch {
    throw "Falha a descarregar: $Url"
  }
}

function Install-MSI($Path) {
  Write-Host "🧩 A instalar: $Path" -ForegroundColor Cyan
  $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$Path`" /qn /norestart" -PassThru -Wait
  if ($p.ExitCode -ne 0) { throw "Falha MSI ($($p.ExitCode)) em $Path" }
}

function Get-CRDStartHostPath {
  $base = ${env:ProgramFiles(x86)}
  $root = Join-Path $base "Google\Chrome Remote Desktop"
  if (-not (Test-Path $root)) { return $null }
  $exe = Get-ChildItem -Path $root -Recurse -Filter "remoting_start_host.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  return $exe?.FullName
}

function Read-PlainFromSecure([securestring]$sec) {
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Prompt-AuthCode {
  Write-Host "`nPara obter o AuthCode: https://remotedesktop.google.com/headless (escolhe Windows)." -ForegroundColor Yellow
  $Auth1 = Read-Host "Cole o AuthCode (não será mostrado)" -AsSecureString
  $Auth2 = Read-Host "Confirme o AuthCode" -AsSecureString
  $a1 = Read-PlainFromSecure $Auth1
  $a2 = Read-PlainFromSecure $Auth2
  if ($a1 -ne $a2 -or [string]::IsNullOrWhiteSpace($a1)) { throw "AuthCode vazio ou não coincide." }
  return $a1
}

function Prompt-Pin {
  do {
    $p1s = Read-Host "Defina o PIN (mín. 6 dígitos; não será mostrado)" -AsSecureString
    $p2s = Read-Host "Confirme o PIN" -AsSecureString
    $p1  = Read-PlainFromSecure $p1s
    $p2  = Read-PlainFromSecure $p2s
    if ($p1 -ne $p2)         { Write-Host "Os PINs não coincidem." -ForegroundColor Yellow; $ok=$false }
    elseif ($p1 -notmatch '^\d{6,}$') { Write-Host "PIN inválido (apenas dígitos, ≥6)." -ForegroundColor Yellow; $ok=$false }
    else { $ok=$true }
  } while (-not $ok)
  return $p1
}

try {
  Assert-Admin

  $tmp = Join-Path $env:TEMP "crd_setup"
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null

  # (Opcional) Chrome
  if ($InstallChrome) {
    $chromeMsi = Join-Path $tmp "googlechromestandaloneenterprise64.msi"
    Download-File "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi" $chromeMsi
    Install-MSI $chromeMsi
  }

  # CRD Host (MSI oficial)
  $crdMsi = Join-Path $tmp "chromeremotedesktophost.msi"
  Download-File "https://dl.google.com/dl/edgedl/chrome-remote-desktop/chromeremotedesktophost.msi" $crdMsi
  Install-MSI $crdMsi

  if ($RegisterUnattended) {
    $startHost = Get-CRDStartHostPath
    if (-not $startHost) { throw "Não encontrei remoting_start_host.exe (instalação falhou?)." }

    $auth = Prompt-AuthCode
    $pin  = Prompt-Pin
    $redirect = "https://remotedesktop.google.com/_/oauthredirect"

    $args = @(
      "--code=""$auth""",
      "--redirect-url=""$redirect""",
      "--name=""$DeviceName""",
      "--pin=$pin"
    )

    Write-Host "`n🔐 A registar o host no CRD para '$DeviceName'..." -ForegroundColor Yellow
    $proc = Start-Process -FilePath $startHost -ArgumentList ($args -join " ") -PassThru -Wait
    if ($proc.ExitCode -ne 0) { throw "Registo falhou (exit $($proc.ExitCode)). Gera novo AuthCode e tenta." }
    Write-Host "✅ Acesso não assistido ativo. Ver em https://remotedesktop.google.com/access" -ForegroundColor Green
  }
  else {
    Write-Host "`nℹ️ Host instalado. Para ativar o acesso não assistido, corre:" -ForegroundColor Yellow
    Write-Host "   .\Install-CRD.ps1 -RegisterUnattended" -ForegroundColor Cyan
  }

  Write-Host "`nConcluído." -ForegroundColor Green
}
catch {
  Write-Error $_.Exception.Message
  exit 1
}
