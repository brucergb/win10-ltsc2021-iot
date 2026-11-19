#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Genera un ISO actualizado de Windows 10 IoT Enterprise LTSC 2021 con instalación semi-desatendida.

.DESCRIPTION
  1. Descarga las actualizaciones de updates.txt (Microsoft Update Catalog) + Defender offline,
     y las apps offline (Edge MSI, ImageGlass, winget) a apps\.
  2. Copia el ISO original a work\dvd y deja en install.wim SOLO la edición IoT Enterprise LTSC.
  3. Agrega autounattend.xml, los scripts $OEM$ y las apps offline.
  4. Integra las actualizaciones con W10UI (tools\W10UI) y crea el ISO final en out\.

  Con -SkipIntegration reutiliza work\dvd (ya actualizado) y solo refresca desatendido/scripts/apps
  y vuelve a crear el ISO: minutos en vez de ~1 hora.

.EXAMPLE
  # PowerShell como administrador, desde la carpeta del repo:
  powershell -ExecutionPolicy Bypass -File .\build.ps1
  powershell -ExecutionPolicy Bypass -File .\build.ps1 -SkipIntegration   # solo cambios en unattend/apps
#>
param(
    [string]$Iso = (Get-ChildItem "$PSScriptRoot\*.iso" | Select-Object -First 1).FullName,
    [string]$Edition = 'Windows 10 IoT Enterprise LTSC',
    [switch]$SkipDownload,
    [switch]$SkipIntegration
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest es lentísimo con su barra en PS 5.1
$root    = $PSScriptRoot
$work    = Join-Path $root 'work'
$dvd     = Join-Path $work 'dvd'
$updates = Join-Path $root 'updates'
$appsDir = Join-Path $root 'apps'
$out     = Join-Path $root 'out'
$w10ui   = Join-Path $root 'tools\W10UI'
$isoName = 'Win10_IoT_Enterprise_LTSC_2021_x64_es-MX_actualizado.iso'

# Progreso global aproximado por etapa (el peso refleja el tiempo típico de cada una).
# Dentro de W10UI, DISM muestra además su propia barra [==== 45.0% ] por paquete.
$script:stepPct = if ($SkipIntegration) { @{ dl = 0; apps = 5; unattend = 30; iso = 35; verify = 95 } }
                  else { @{ dl = 0; apps = 6; copy = 8; export = 12; unattend = 18; ini = 19; w10ui = 20; iso = 96; verify = 99 } }
$script:t0 = Get-Date
function Step($key, $m) {
    $p = $script:stepPct[$key]
    $el = (Get-Date) - $script:t0
    Write-Host ("`n==> [{0,3}%] {1}  (transcurrido {2:hh\:mm\:ss})" -f $p, $m, $el) -ForegroundColor Cyan
    Write-Progress -Activity 'Build ISO LTSC 2021 IoT' -Status $m -PercentComplete $p
}
function Get-File($url, $dest) {
    if (Test-Path $dest) { Write-Host "  ya existe: $(Split-Path $dest -Leaf)"; return }
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Write-Host "  descargando $(Split-Path $dest -Leaf)"
    # curl escribe su barra de progreso en stderr; con 'Stop' PS 5.1 la trataría como error
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    curl.exe -fL --progress-bar -o "$dest.part" $url 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match '100\.0%|curl:' } | Write-Host
    $ErrorActionPreference = $eap
    if ($LASTEXITCODE) { Remove-Item "$dest.part" -ErrorAction SilentlyContinue; throw "Falló la descarga de $url" }
    Move-Item "$dest.part" $dest -Force
}
function Get-GithubAsset($repo, $pattern) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'build-script' }
    $rel.assets | Where-Object name -match $pattern | Select-Object -First 1
}

New-Item -ItemType Directory -Force $work, $updates, $out, $appsDir | Out-Null
if ($SkipIntegration) {
    if (-not (Test-Path "$dvd\sources\install.wim")) { throw "No existe $dvd\sources\install.wim: corre primero el build completo." }
} elseif (-not $Iso -or -not (Test-Path $Iso)) { throw 'No encontré el ISO original (parámetro -Iso).' }

# --- 1. Descargas ---------------------------------------------------------
if (-not $SkipDownload) {
    if (-not $SkipIntegration) {
        Step dl 'Descargando actualizaciones del Microsoft Update Catalog'
        $ids = Get-Content "$root\updates.txt" | Where-Object { $_ -match '^\s*([0-9a-f-]{36})' } | ForEach-Object { $Matches[1] }
        foreach ($id in $ids) { python "$root\tools\catalog.py" get $id $updates; if ($LASTEXITCODE) { throw "Falló la descarga de $id" } }
        Step dl 'Descargando actualización offline de Microsoft Defender'
        Get-File 'https://go.microsoft.com/fwlink/?linkid=2144531' (Join-Path $updates 'defender-update-kit-x64.zip')
    }

    Step apps 'Descargando apps offline (Edge, ImageGlass, winget)'
    # Edge: última Stable x64 (MSI empresarial)
    # (asignar a variable antes del pipe: en PS 5.1 el arreglo JSON llega como UN objeto y no se enumera)
    $products = Invoke-RestMethod 'https://edgeupdates.microsoft.com/api/products'
    $edgeRel = $products | Where-Object Product -eq 'Stable' | ForEach-Object { $_.Releases } |
        Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64' -and ($_.Artifacts | Where-Object ArtifactName -eq 'msi') } |
        Sort-Object { [version]$_.ProductVersion } | Select-Object -Last 1
    $edgeUrl = ($edgeRel.Artifacts | Where-Object ArtifactName -eq 'msi' | Select-Object -First 1).Location
    if (-not $edgeUrl) { throw 'No encontré la URL del MSI de Edge en la API de Microsoft.' }
    $edgeVerFile = "$appsDir\edge\version.txt"
    if (-not (Test-Path $edgeVerFile) -or (Get-Content $edgeVerFile) -ne $edgeRel.ProductVersion) {
        Remove-Item "$appsDir\edge" -Recurse -Force -ErrorAction SilentlyContinue
        Get-File $edgeUrl "$appsDir\edge\MicrosoftEdgeEnterpriseX64.msi"
        Set-Content $edgeVerFile $edgeRel.ProductVersion
    }
    Write-Host "  Edge $($edgeRel.ProductVersion)"
    # ImageGlass: último MSI x64
    $a = Get-GithubAsset 'd2phap/ImageGlass' '_win-x64\.msi$'
    if (-not $a) { throw 'No encontré el MSI x64 de ImageGlass en GitHub.' }
    if (-not (Test-Path "$appsDir\imageglass\$($a.name)")) { Remove-Item "$appsDir\imageglass" -Recurse -Force -ErrorAction SilentlyContinue }
    Get-File $a.browser_download_url "$appsDir\imageglass\$($a.name)"
    # winget (App Installer) + licencia + dependencias x64
    $rel = Invoke-RestMethod 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{ 'User-Agent' = 'build-script' }
    $wgVerFile = "$appsDir\winget\version.txt"
    if (-not $rel.tag_name) { throw 'No pude consultar el release de winget en GitHub.' }
    if (-not (Test-Path $wgVerFile) -or (Get-Content $wgVerFile) -ne $rel.tag_name) {
        Remove-Item "$appsDir\winget" -Recurse -Force -ErrorAction SilentlyContinue
        $get = { param($pat, $name) $x = $rel.assets | Where-Object name -match $pat | Select-Object -First 1; Get-File $x.browser_download_url "$appsDir\winget\$name" }
        & $get '\.msixbundle$' 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
        & $get 'License1\.xml$' 'License1.xml'
        & $get 'Dependencies\.zip$' 'deps.zip'
        7z e -y "-o$appsDir\winget" "$appsDir\winget\deps.zip" 'x64\*' | Out-Null
        if ($LASTEXITCODE) { throw 'No pude extraer las dependencias de winget (¿7z en el PATH?)' }
        Remove-Item "$appsDir\winget\deps.zip"
        Set-Content $wgVerFile $rel.tag_name
    }
    Write-Host "  winget $($rel.tag_name)"
    # Verificar firmas digitales de todo lo que va dentro del ISO
    Get-ChildItem $appsDir -Recurse -File -Include *.msi, *.msixbundle, *.appx | ForEach-Object {
        $s = Get-AuthenticodeSignature $_.FullName
        if ($s.Status -ne 'Valid') { throw "Firma inválida en $($_.Name): $($s.Status)" }
    }
}

if (-not $SkipIntegration) {
    $zip = Join-Path $updates 'defender-update-kit-x64.zip'
    if ((Test-Path $zip) -and -not (Test-Path "$updates\defender-dism-x64.cab")) {
        $tmp = Join-Path $work 'defender'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive $zip $tmp
        Get-ChildItem $tmp -Recurse -Filter 'defender-dism-x64.cab' | Copy-Item -Destination $updates
        Remove-Item $tmp -Recurse -Force
    }

    # --- 2. Copia del ISO y selección de edición --------------------------
    Step copy "Copiando el contenido del ISO a $dvd"
    if (Test-Path $dvd) { Remove-Item $dvd -Recurse -Force }
    $img = Mount-DiskImage -ImagePath $Iso -PassThru
    try {
        $drive = ($img | Get-Volume).DriveLetter + ':\'
        robocopy $drive $dvd /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy falló ($LASTEXITCODE)" }
    } finally { Dismount-DiskImage -ImagePath $Iso | Out-Null }
    attrib -r "$dvd\*" /s /d

    Step export "Dejando solo la edición '$Edition' en install.wim"
    $wim = "$dvd\sources\install.wim"
    $index = (Get-WindowsImage -ImagePath $wim | Where-Object ImageName -eq $Edition).ImageIndex
    if (-not $index) { throw "No encontré la edición '$Edition' en install.wim" }
    $tmpWim = Join-Path $work 'install.wim'
    Remove-Item $tmpWim -Force -ErrorAction SilentlyContinue
    Export-WindowsImage -SourceImagePath $wim -SourceIndex $index -DestinationImagePath $tmpWim -CompressionType max -CheckIntegrity | Out-Null
    Move-Item $tmpWim $wim -Force
}

# --- 3. Desatendido + scripts + apps offline ------------------------------
Step unattend 'Agregando autounattend.xml, $OEM$ y apps offline'
Copy-Item "$root\unattend\autounattend.xml" $dvd -Force
$oem = "$dvd\sources\`$OEM`$"
if (Test-Path -LiteralPath $oem) { Remove-Item -LiteralPath $oem -Recurse -Force }
Copy-Item -LiteralPath "$root\unattend\`$OEM`$" -Destination "$dvd\sources\" -Recurse -Force
$appsDest = "$oem\`$`$\Setup\Apps"   # -> C:\Windows\Setup\Apps (install-defaults.ps1 lo borra al terminar)
New-Item -ItemType Directory -Force -Path $appsDest | Out-Null
Get-ChildItem $appsDir -Recurse -File -Include *.msi, *.msixbundle, *.appx, License1.xml | Copy-Item -Destination $appsDest -Force
Write-Host ("  apps offline: {0:N0} MiB" -f ((Get-ChildItem $appsDest | Measure-Object Length -Sum).Sum / 1MB))

if (-not $SkipIntegration) {
    # --- 4. Configuración de W10UI e integración ---------------------------
    Step ini 'Configurando W10UI'
    $opts = [ordered]@{
        Target = $dvd; Repo = $updates
        Net35 = 0            # .NET 3.5 no se habilita (menos superficie; Windows lo instala bajo demanda)
        Cleanup = 1; ResetBase = 0   # limpia componentes reemplazados sin romper "Restablecer este PC"
        WinRE = 1            # actualiza winre.wim (Safe OS DU)
        _CabDir = "$work\W10UItemp"; MountDir = "$work\W10UImount"; WinreMount = "$work\W10UImountre"
        ISO = 0; Delete_Source = 0   # el ISO lo crea New-IsoImage.ps1 (el DIR2ISO de W10UI falla con "Acceso denegado")
        AutoStart = 1        # sin menú interactivo
    }
    $iniPath = Join-Path $w10ui 'W10UI.ini'
    $ini = Get-Content $iniPath
    foreach ($k in $opts.Keys) { $ini = $ini -replace "^($([regex]::Escape($k))\s*=).*$", "`${1}$($opts[$k])" }
    Set-Content -Path $iniPath -Value $ini -Encoding ASCII

    Step w10ui 'Integrando actualizaciones con W10UI (tarda 30-60 min)'
    # Ruta completa + quitar NoDefaultCurrentDirectoryInExePath: si está definida, cmd no busca en el directorio actual
    $env:NoDefaultCurrentDirectoryInExePath = $null
    Push-Location $w10ui
    try { & cmd.exe /c "$w10ui\W10UI.cmd" } finally { Pop-Location }
    $ver = (Get-WindowsImage -ImagePath "$dvd\sources\install.wim" -Index 1).Version
    Write-Host "  install.wim quedó en $ver"
}

# --- 5. Crear el ISO ---------------------------------------------------------
Step iso 'Creando el ISO (IMAPI2, BIOS + UEFI)'
Remove-Item "$out\*.iso" -Force -ErrorAction SilentlyContinue
& "$root\tools\New-IsoImage.ps1" -Source $dvd -Iso (Join-Path $out $isoName) -Label 'LTSC2021_IOT' | Out-Null

# --- 6. Verificación -------------------------------------------------------
Step verify 'Verificando el ISO generado'
$newIso = Get-Item (Join-Path $out $isoName) -ErrorAction SilentlyContinue
if (-not $newIso) { throw 'No se generó el ISO. Revisa la salida de arriba.' }
$img = Mount-DiskImage -ImagePath $newIso.FullName -PassThru
try {
    $drive = ($img | Get-Volume).DriveLetter + ':\'
    $info = Get-WindowsImage -ImagePath "$drive\sources\install.wim" -Index 1
    $scripts = "$drive\sources\`$OEM`$\`$`$\Setup\Scripts"
    [pscustomobject]@{
        ISO = $newIso.Name; TamanoGB = [math]::Round($newIso.Length / 1GB, 2)
        Edicion = $info.ImageName; Version = $info.Version
        Ediciones = @(Get-WindowsImage -ImagePath "$drive\sources\install.wim").Count
        InstallWimGB = [math]::Round((Get-Item "$drive\sources\install.wim").Length / 1GB, 2)
        Autounattend = Test-Path "$drive\autounattend.xml"
        Scripts = (Get-ChildItem -LiteralPath $scripts -Name) -join ', '
        AppsOffline = (Get-ChildItem -LiteralPath "$drive\sources\`$OEM`$\`$`$\Setup\Apps" -Name) -join ', '
        ArranqueBIOS = Test-Path "$drive\boot\etfsboot.com"
        ArranqueUEFI = Test-Path "$drive\efi\microsoft\boot\efisys.bin"
    } | Format-List
} finally { Dismount-DiskImage -ImagePath $newIso.FullName | Out-Null }
Write-Progress -Activity 'Build ISO LTSC 2021 IoT' -Completed
Write-Host ("[100%] Listo en {0:hh\:mm\:ss}" -f ((Get-Date) - $script:t0)) -ForegroundColor Green
