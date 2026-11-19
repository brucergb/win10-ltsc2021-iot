# Apps por defecto (offline, desde C:\Windows\Setup\Apps). Lo ejecuta SetupComplete.cmd como SYSTEM.
#  - Microsoft Edge actualizado (MSI empresarial)
#  - ImageGlass como visor de imágenes predeterminado + Visor de fotos clásico como alternativa
#  - winget (App Installer) aprovisionado para todos los usuarios
#  - Acceso directo "Instalar apps opcionales" en el menú Inicio

$ErrorActionPreference = 'Continue'
$apps = Join-Path $env:WINDIR 'Setup\Apps'
$scripts = Join-Path $env:WINDIR 'Setup\Scripts'
function Log($m) { Write-Output "$(Get-Date -Format HH:mm:ss) $m" }
function Install-Msi($path, $extra = '') {
    if (-not (Test-Path $path)) { Log "SKIP no existe $path"; return }
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$path`" /qn /norestart $extra" -Wait -PassThru
    Log "msiexec $(Split-Path $path -Leaf) -> $($p.ExitCode)"   # 0 = ok, 3010 = ok (requiere reinicio)
}

Log '=== install-defaults ==='

# --- 1. Microsoft Edge ---
Install-Msi "$apps\MicrosoftEdgeEnterpriseX64.msi"

# --- 2. ImageGlass (para todos los usuarios) ---
$ig = Get-ChildItem "$apps\ImageGlass_*_win-x64.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ig) { Install-Msi $ig.FullName 'ALLUSERS=1' }
$igExe = "$env:ProgramFiles\ImageGlass\ImageGlass.exe"

# Extensiones que abrirá ImageGlass por defecto
$exts = '.jpg', '.jpeg', '.jpe', '.jfif', '.png', '.gif', '.bmp', '.dib', '.tif', '.tiff', '.webp', '.heic', '.heif', '.avif', '.jxl', '.ico'

if (Test-Path $igExe) {
    # ProgID propio en HKLM (no depende de cómo ImageGlass registre los suyos)
    $cls = 'HKLM:\SOFTWARE\Classes'
    New-Item "$cls\ImageGlass.Image\shell\open\command" -Force | Out-Null
    Set-ItemProperty "$cls\ImageGlass.Image" '(default)' 'Imagen (ImageGlass)'
    New-Item "$cls\ImageGlass.Image\DefaultIcon" -Force | Out-Null
    Set-ItemProperty "$cls\ImageGlass.Image\DefaultIcon" '(default)' "`"$igExe`",0"
    Set-ItemProperty "$cls\ImageGlass.Image\shell\open\command" '(default)' "`"$igExe`" `"%1`""
    # Capabilities -> aparece en "Aplicaciones predeterminadas" y en "Abrir con"
    $cap = 'HKLM:\SOFTWARE\ImageGlassLTSC\Capabilities'
    New-Item "$cap\FileAssociations" -Force | Out-Null
    Set-ItemProperty $cap 'ApplicationName' 'ImageGlass'
    Set-ItemProperty $cap 'ApplicationDescription' 'Visor de imágenes rápido'
    foreach ($e in $exts) {
        Set-ItemProperty "$cap\FileAssociations" $e 'ImageGlass.Image'
        New-Item "$cls\$e\OpenWithProgids" -Force | Out-Null
        New-ItemProperty "$cls\$e\OpenWithProgids" 'ImageGlass.Image' -Value '' -PropertyType String -Force | Out-Null
    }
    New-ItemProperty 'HKLM:\SOFTWARE\RegisteredApplications' 'ImageGlass' -Value 'SOFTWARE\ImageGlassLTSC\Capabilities' -Force | Out-Null

    # Asociaciones predeterminadas para las cuentas nuevas (incluida la del OOBE)
    $xml = Join-Path $env:TEMP 'DefaultAssoc.xml'
    $lines = @('<?xml version="1.0" encoding="UTF-8"?>', '<DefaultAssociations>')
    $lines += $exts | ForEach-Object { "  <Association Identifier=`"$_`" ProgId=`"ImageGlass.Image`" ApplicationName=`"ImageGlass`" />" }
    $lines += '</DefaultAssociations>'
    Set-Content $xml $lines -Encoding UTF8
    dism.exe /Online /Import-DefaultAppAssociations:"$xml" | Out-Null
    Log "ImageGlass predeterminado (dism -> $LASTEXITCODE)"
} else { Log 'FAIL ImageGlass no quedó instalado' }

# --- 3. Visor de fotos clásico de Windows (alternativa en "Abrir con") ---
$pv = 'HKLM:\SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations'
New-Item $pv -Force | Out-Null
foreach ($e in '.jpg', '.jpeg', '.jpe', '.jfif', '.png', '.gif', '.bmp', '.dib', '.tif', '.tiff', '.ico') {
    Set-ItemProperty $pv $e 'PhotoViewer.FileAssoc.Tiff'
}
Log 'Visor de fotos clásico habilitado'

# --- 4. winget (App Installer) para todos los usuarios ---
$bundle = Get-ChildItem "$apps\Microsoft.DesktopAppInstaller_*.msixbundle" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($bundle) {
    try {
        $deps = (Get-ChildItem "$apps\*.appx").FullName
        Add-AppxProvisionedPackage -Online -PackagePath $bundle.FullName -DependencyPackagePath $deps -LicensePath "$apps\License1.xml" -ErrorAction Stop | Out-Null
        Log 'winget aprovisionado'
    } catch { Log "FAIL winget: $_" }
}

# --- 5. Acceso directo al menú de apps opcionales ---
try {
    $lnk = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Instalar apps opcionales.lnk"
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scripts\apps-opcionales.ps1`""
    $s.IconLocation = "$env:WINDIR\System32\imageres.dll,-5338"
    $s.Save()
    Log 'acceso directo creado'
} catch { Log "FAIL acceso directo: $_" }

# --- 6. Liberar espacio: los instaladores ya no hacen falta ---
Remove-Item $apps -Recurse -Force -ErrorAction SilentlyContinue
Log '=== fin install-defaults ==='
