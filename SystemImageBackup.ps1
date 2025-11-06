<# 
.SYNOPSIS
  Cria imagem do sistema com wbadmin e (opcionalmente) agenda execução semanal.

.PARAMETER Target
  Destino do backup (ex.: E: ou \\NAS\Backups). O wbadmin criará WindowsImageBackup no raiz.

.PARAMETER Include
  Unidades a incluir (por defeito apenas C:). -AllCritical garante partições de arranque/recuperação.

.PARAMETER RunBackup
  Executa o backup imediatamente.

.PARAMETER RegisterTask
  Cria tarefa semanal no Agendador de Tarefas para correr este script.

.PARAMETER TaskName
  Nome da tarefa (por defeito: SystemImageWeekly).

.PARAMETER DayOfWeek
  Dia da semana para o agendamento (Sunday, Monday, ...). Por defeito: Sunday.

.PARAMETER Time
  Hora local (HH:mm) para o agendamento. Por defeito: 03:00.

.PARAMETER LogPath
  Pasta para logs. Por defeito: %ProgramData%\SystemImageBackup\logs

.EXAMPLES
  # Executar já, destino E:
  .\SystemImageBackup.ps1 -RunBackup -Target E:

  # Agendar semanalmente, domingo às 03h, destino E:
  .\SystemImageBackup.ps1 -RegisterTask -Target E: -DayOfWeek Sunday -Time "03:00"

  # Fazer já e agendar
  .\SystemImageBackup.ps1 -RunBackup -RegisterTask -Target E:
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$Target,

  [string[]]$Include = @("C:"),

  [switch]$RunBackup,

  [switch]$RegisterTask,

  [string]$TaskName = "SystemImageWeekly",

  [ValidateSet("Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday")]
  [string]$DayOfWeek = "Sunday",

  [ValidatePattern('^\d{2}:\d{2}$')]
  [string]$Time = "03:00",

  [string]$LogPath = "$env:ProgramData\SystemImageBackup\logs"
)

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "Este script requer privilégios de Administrador. Abre o PowerShell como Administrador."
  }
}

function Ensure-Tools {
  if (-not (Get-Command wbadmin -ErrorAction SilentlyContinue)) {
    throw "wbadmin não encontrado. Disponível nativamente no Windows 10/11 Pro/Enterprise. Em Home pode estar desativado."
  }
}

function Resolve-Target {
  param([string]$T)
  if ($T -match '^[A-Za-z]:\\?$') {
    # Normalizar drive para 'E:' (sem barra)
    return ($T.Substring(0,2).ToUpper())
  }
  return $T
}

function Test-Target {
  param([string]$T)
  # Drive local?
  if ($T -match '^[A-Z]:$') {
    # Verificar se está montada
    if (-not (Test-Path "$T\")) {
      throw "Destino $T não está acessível. Liga o disco e tenta novamente."
    }
  } else {
    # UNC
    if (-not (Test-Path $T)) {
      throw "Destino $T (UNC) não acessível. Verifica a rede/credenciais."
    }
  }
}

function Ensure-Log {
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Start-SystemImageBackup {
  param([string]$Target, [string[]]$Include, [string]$LogPath)

  $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
  Ensure-Log -Path $LogPath
  $logFile = Join-Path $LogPath "wbadmin_$timestamp.log"

  $inc = ($Include | ForEach-Object { $_.TrimEnd('\') }) -join ','

  Write-Host "➡️  A iniciar wbadmin (destino: $Target ; include: $inc ; allCritical: ON)..." -ForegroundColor Cyan
  $args = @(
    'start','backup',
    "-backupTarget:$Target",
    "-include:$inc",
    "-allCritical",
    "-quiet"
  )

  # Executa e envia saída para log
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "wbadmin"
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.Arguments = ($args -join ' ')
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi

  [void]$proc.Start()
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  $stdout | Tee-Object -FilePath $logFile -Append | Out-Null
  if ($stderr) { 
    "`n[stderr]`n$stderr" | Tee-Object -FilePath $logFile -Append | Out-Null 
  }

  if ($proc.ExitCode -ne 0) {
    throw "wbadmin terminou com código $($proc.ExitCode). Ver log: $logFile"
  } else {
    Write-Host "✅ Backup concluído. Log: $logFile" -ForegroundColor Green
  }
}

function Register-WeeklyTask {
  param(
    [string]$TaskName, [string]$DayOfWeek, [string]$Time, 
    [string]$Target, [string[]]$Include
  )

  # Caminho absoluto do script para a ação agendada
  $scriptPath = $MyInvocation.MyCommand.Path
  if (-not $scriptPath) {
    throw "Não foi possível detetar o caminho do script. Guarda-o como .ps1 e executa-o novamente."
  }

  # Argumentos para chamar o próprio script com -RunBackup
  $inc = ($Include | ForEach-Object { $_.TrimEnd('\') }) -join ','
  $psArgs = @(
    '-NoProfile','-ExecutionPolicy','Bypass',
    '-File', ('"' + $scriptPath + '"'),
    '-RunBackup',
    '-Target', ('"' + $Target + '"'),
    '-Include', ('"' + $inc + '"')
  ) -join ' '

  $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs
  $timeObj = [DateTime]::ParseExact($Time,'HH:mm',$null)
  $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $timeObj.TimeOfDay
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

  # Cria ou atualiza
  $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable)

  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  }
  Register-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null

  Write-Host ("🗓️  Tarefa '{0}' registada: {1} às {2}" -f $TaskName,$DayOfWeek,$Time) -ForegroundColor Yellow
  Write-Host "   • Irá correr como SYSTEM, com privilégios elevados."
  Write-Host "   • Certifica-te de que o destino ($Target) está acessível nessa altura."
}

try {
  Assert-Admin
  Ensure-Tools
  $Target = Resolve-Target -T $Target
  Test-Target -T $Target

  if ($RunBackup) {
    Start-SystemImageBackup -Target $Target -Include $Include -LogPath $LogPath
  }

  if ($RegisterTask) {
    Register-WeeklyTask -TaskName $TaskName -DayOfWeek $DayOfWeek -Time $Time -Target $Target -Include $Include
  }

  if (-not $RunBackup -and -not $RegisterTask) {
    Write-Host "Nenhuma ação pedida. Usa -RunBackup e/ou -RegisterTask. Vê .SYNOPSIS para exemplos." -ForegroundColor Yellow
  }
}
catch {
  Write-Error $_.Exception.Message
  exit 1
}
