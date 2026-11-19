# Ajustes de seguridad/privacidad para Windows 10 IoT Enterprise LTSC 2021.
# Lo ejecuta SetupComplete.cmd como SYSTEM. Cada ajuste es independiente: si uno falla, sigue con el resto.
# Todos son reversibles (ver README, sección "Revertir ajustes").

$ErrorActionPreference = 'Continue'
function Set-Reg($Path, $Name, $Value, $Type = 'DWord') {
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Output "OK   $Path\$Name = $Value"
    } catch { Write-Output "FAIL $Path\$Name : $_" }
}
function Disable-Feature($Name) {
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
        if ($f.State -ne 'Disabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop | Out-Null
            Write-Output "OK   feature $Name deshabilitada"
        } else { Write-Output "OK   feature $Name ya estaba deshabilitada" }
    } catch { Write-Output "SKIP feature $Name : $_" }
}

Write-Output "=== hardening $(Get-Date -Format s) ==="
$P = 'HKLM:\SOFTWARE\Policies\Microsoft'

# --- 1. Componentes heredados con historial de ataques ---
Disable-Feature 'SMB1Protocol'                       # SMBv1 (WannaCry/EternalBlue)
Disable-Feature 'MicrosoftWindowsPowerShellV2Root'   # PowerShell 2.0 (evade AMSI y el logging)
Disable-Feature 'Internet-Explorer-Optional-amd64'   # Internet Explorer 11 (motor obsoleto; Edge lo reemplaza)

# --- 2. Red ---
Set-Reg "$P\Windows NT\DNSClient" 'EnableMulticast' 0                 # LLMNR off (envenenamiento tipo Responder)
Set-Reg "$P\Windows\LanmanWorkstation" 'AllowInsecureGuestAuth' 0      # no conectarse a shares SMB como invitado
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 0   # Asistencia remota off
# Firewall activo en todos los perfiles (ya es el default; se fuerza por si acaso)
try { Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True; Write-Output 'OK   firewall habilitado' } catch { Write-Output "FAIL firewall: $_" }

# --- 3. Medios extraíbles ---
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255   # AutoRun off en todas las unidades
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoAutorun' 1

# --- 4. Protección de credenciales y del kernel ---
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL' 1     # LSA como proceso protegido (dificulta volcar credenciales tipo mimikatz)
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'DisableExceptionChainValidation' 0   # SEHOP on
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential' 0          # no guardar contraseñas en claro en memoria

# --- 5. Microsoft Defender ---
Set-Reg "$P\Windows Defender" 'PUAProtection' 1                         # bloquear aplicaciones potencialmente no deseadas
try { Set-MpPreference -PUAProtection Enabled -ErrorAction Stop; Write-Output 'OK   Defender PUA on' } catch { Write-Output "SKIP Set-MpPreference: $_" }

# --- 6. Privacidad / telemetría (Enterprise permite nivel 0 = Seguridad) ---
Set-Reg "$P\Windows\DataCollection" 'AllowTelemetry' 0
Set-Reg "$P\Windows\AdvertisingInfo" 'DisabledByGroupPolicy' 1         # ID de publicidad
Set-Reg "$P\Windows\System" 'EnableActivityFeed' 0                     # historial de actividad / Timeline
Set-Reg "$P\Windows\System" 'PublishUserActivities' 0
Set-Reg "$P\Windows\System" 'UploadUserActivities' 0
Set-Reg "$P\Windows\CloudContent" 'DisableWindowsConsumerFeatures' 1   # sin apps/sugerencias "patrocinadas"
Set-Reg "$P\Windows\CloudContent" 'DisableTailoredExperiencesWithDiagnosticData' 1
Set-Reg "$P\Windows\Windows Error Reporting" 'Disabled' 1             # no enviar reportes de errores

# --- 7. Perfil por defecto (aplica a las cuentas nuevas, incluida la que se crea en el OOBE) ---
$hive = 'HKU\DefaultUser'
reg.exe load $hive "$env:SystemDrive\Users\Default\NTUSER.DAT" | Out-Null
if ($LASTEXITCODE -eq 0) {
    $D = 'Registry::HKEY_USERS\DefaultUser'
    Set-Reg "$D\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'HideFileExt' 0   # mostrar extensiones (evita "factura.pdf.exe")
    Set-Reg "$D\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" 'Enabled' 0
    Set-Reg "$D\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SilentInstalledAppsEnabled' 0
    Set-Reg "$D\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SystemPaneSuggestionsEnabled' 0
    [gc]::Collect(); Start-Sleep -Seconds 1
    reg.exe unload $hive | Out-Null
    Write-Output "OK   perfil por defecto actualizado"
} else { Write-Output "FAIL no se pudo cargar el NTUSER.DAT por defecto" }

Write-Output "=== fin $(Get-Date -Format s) ==="
