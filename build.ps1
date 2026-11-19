#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Genera un ISO actualizado de Windows 10 IoT Enterprise LTSC 2021 con instalación semi-desatendida.

.DESCRIPTION
  1. Descarga las actualizaciones de updates.txt (Microsoft Update Catalog) + Defender offline,
     las apps offline (Edge MSI, ImageGlass, winget) y, si -Language no es en-US, el paquete de idioma.
  2. Copia el ISO original y deja en install.wim SOLO la edición IoT Enterprise LTSC.
  3. Integra:
       en-US -> actualizaciones con W10UI (tools\W10UI)
       otro  -> paquete de idioma + OnDemand + actualizaciones con W10MUI (tools\W10MUI),
                con ese idioma como predeterminado (el orden idioma -> updates lo resuelve W10MUI)
  4. Agrega autounattend.xml (con el idioma elegido), los scripts $OEM$ y las apps offline.
  5. Crea el ISO (BIOS + UEFI) en out\ y lo verifica.

  Cada idioma tiene su propia carpeta de trabajo (work\dvd = en-US, work\dvd-es-MX, ...) y su propio ISO:
  construir uno no borra el del otro.

  Con -SkipIntegration reutiliza la carpeta de trabajo de ese idioma (ya actualizada) y solo refresca
  desatendido/scripts/apps y vuelve a crear el ISO: segundos en vez de ~1 hora.

.EXAMPLE
  # PowerShell como administrador, desde la carpeta del repo:
  powershell -ExecutionPolicy Bypass -File .\build.ps1                       # inglés (en-US)
  powershell -ExecutionPolicy Bypass -File .\build.ps1 -Language es-MX       # español de México
  powershell -ExecutionPolicy Bypass -File .\build.ps1 -Language es-MX -SkipIntegration
#>
param(
    [string]$Iso = (Get-ChildItem "$PSScriptRoot\*.iso" | Select-Object -First 1).FullName,
    [string]$Edition = 'Windows 10 IoT Enterprise LTSC',
    [ValidatePattern('^[a-z]{2}-[A-Z]{2}$')][string]$Language = 'en-US',
    [switch]$SkipDownload,
    [switch]$SkipIntegration
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest es lentísimo con su barra en PS 5.1
$root    = $PSScriptRoot
$work    = Join-Path $root 'work'
$baseLang = $Language -eq 'en-US'           # el ISO original es en-US
$dvd     = if ($baseLang) { Join-Path $work 'dvd' } else { Join-Path $work "dvd-$Language" }
$prep    = if ($baseLang) { $dvd } else { Join-Path $work "src-$Language" }   # origen para W10MUI
$updates = Join-Path $root 'updates'
$appsDir = Join-Path $root 'apps'
$langDir = Join-Path $root "langs\$Language"
$out     = Join-Path $root 'out'
$w10ui   = Join-Path $root 'tools\W10UI'
$w10mui  = Join-Path $root 'tools\W10MUI'
$isoName = "Win10_IoT_Enterprise_LTSC_2021_x64_${Language}_actualizado.iso"

# Progreso global aproximado por etapa (el peso refleja el tiempo típico de cada una).
$script:stepPct = if ($SkipIntegration) { @{ dl = 0; apps = 5; unattend = 30; iso = 35; verify = 95 } }
                  else { @{ dl = 0; langs = 3; apps = 6; copy = 8; export = 12; ini = 18; integ = 20; unattend = 95; iso = 96; verify = 99 } }
$script:t0 = Get-Date
function Step($key, $m) {
    $p = $script:stepPct[$key]
    $el = (Get-Date) - $script:t0
    Write-Host ("`n==> [{0,3}%] {1}  (transcurrido {2:hh\:mm\:ss})" -f $p, $m, $el) -ForegroundColor Cyan
    Write-Progress -Activity "Build ISO LTSC 2021 IoT ($Language)" -Status $m -PercentComplete $p
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
function Set-IniValues($path, $opts) {
    $ini = Get-Content $path
    foreach ($k in $opts.Keys) { $ini = $ini -replace "^($([regex]::Escape($k))\s*=).*$", "`${1}$($opts[$k])" }
    Set-Content -Path $path -Value $ini -Encoding ASCII
}
# Opciones de W10UI comunes a ambos flujos
$w10uiOpts = [ordered]@{
    Net35 = 0                    # .NET 3.5 no se habilita (menos superficie; Windows lo instala bajo demanda)
    Cleanup = 1; ResetBase = 0   # limpia componentes reemplazados sin romper "Restablecer este PC"
    WinRE = 1                    # actualiza winre.wim (Safe OS DU)
    ISO = 0; Delete_Source = 0   # el ISO lo crea New-IsoImage.ps1 (el DIR2ISO de W10UI falla con "Acceso denegado")
}

New-Item -ItemType Directory -Force $work, $updates, $out, $appsDir | Out-Null
if ($SkipIntegration) {
    if (-not (Test-Path "$dvd\sources\install.wim")) { throw "No existe $dvd\sources\install.wim: corre primero el build completo de $Language." }
} elseif (-not $Iso -or -not (Test-Path $Iso)) { throw 'No encontré el ISO original (parámetro -Iso).' }

# --- 1. Descargas ---------------------------------------------------------
if (-not $SkipDownload) {
    if (-not $SkipIntegration) {
        Step dl 'Descargando actualizaciones del Microsoft Update Catalog'
        $ids = Get-Content "$root\updates.txt" | Where-Object { $_ -match '^\s*([0-9a-f-]{36})' } | ForEach-Object { $Matches[1] }
        foreach ($id in $ids) { python "$root\tools\catalog.py" get $id $updates; if ($LASTEXITCODE) { throw "Falló la descarga de $id" } }
        Step dl 'Descargando actualización offline de Microsoft Defender'
        Get-File 'https://go.microsoft.com/fwlink/?linkid=2144531' (Join-Path $updates 'defender-update-kit-x64.zip')
        if (-not $baseLang) {
            Step langs "Descargando paquete de idioma $Language (UUP, verificado con SHA-1)"
            python -I "$root\tools\get-langpack.py" $Language $langDir
            if ($LASTEXITCODE) { throw "Falló la descarga del paquete de idioma $Language" }
        }
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
    if (-not $baseLang) {
        if (-not (Get-ChildItem "$langDir\Langs\*.esd", "$langDir\Langs\*.cab" -ErrorAction SilentlyContinue)) { throw "No hay paquete de idioma en $langDir\Langs" }
        Get-ChildItem "$langDir\OnDemand\x64\*.cab" | ForEach-Object {
            if ((Get-AuthenticodeSignature $_.FullName).Status -ne 'Valid') { throw "Firma inválida en $($_.Name)" }
        }
    }

    # --- 2. Copia del ISO y selección de edición --------------------------
    Step copy "Copiando el contenido del ISO a $prep"
    if (Test-Path $prep) { Remove-Item $prep -Recurse -Force }
    $img = Mount-DiskImage -ImagePath $Iso -PassThru
    try {
        $drive = ($img | Get-Volume).DriveLetter + ':\'
        robocopy $drive $prep /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy falló ($LASTEXITCODE)" }
    } finally { Dismount-DiskImage -ImagePath $Iso | Out-Null }
    attrib -r "$prep\*" /s /d

    Step export "Dejando solo la edición '$Edition' en install.wim"
    $wim = "$prep\sources\install.wim"
    $index = (Get-WindowsImage -ImagePath $wim | Where-Object ImageName -eq $Edition).ImageIndex
    if (-not $index) { throw "No encontré la edición '$Edition' en install.wim" }
    $tmpWim = Join-Path $work 'install.wim'
    Remove-Item $tmpWim -Force -ErrorAction SilentlyContinue
    Export-WindowsImage -SourceImagePath $wim -SourceIndex $index -DestinationImagePath $tmpWim -CompressionType max -CheckIntegrity | Out-Null
    Move-Item $tmpWim $wim -Force

    # cmd no busca en el directorio actual si esta variable está definida (rompe W10UI/W10MUI)
    $env:NoDefaultCurrentDirectoryInExePath = $null

    if ($baseLang) {
        # --- 3a. en-US: solo actualizaciones con W10UI ------------------------
        Step ini 'Configurando W10UI'
        $o = [ordered]@{ Target = $dvd; Repo = $updates; _CabDir = "$work\W10UItemp"; MountDir = "$work\W10UImount"; WinreMount = "$work\W10UImountre"; AutoStart = 1 }
        foreach ($k in $w10uiOpts.Keys) { $o[$k] = $w10uiOpts[$k] }
        Set-IniValues (Join-Path $w10ui 'W10UI.ini') $o

        Step integ 'Integrando actualizaciones con W10UI (tarda 30-60 min)'
        Push-Location $w10ui
        try { & cmd.exe /c "$w10ui\W10UI.cmd" } finally { Pop-Location }
    } else {
        # --- 3b. Otro idioma: paquete de idioma + updates con W10MUI ---------
        Step ini "Preparando W10MUI para $Language"
        $mui = Join-Path $work "W10MUI-$Language"
        if (Test-Path $mui) { Remove-Item $mui -Recurse -Force }
        Copy-Item $w10mui $mui -Recurse
        if (-not (Test-Path "$w10mui\dism\dism.exe")) {
            # Binarios auxiliares de W10MUI (no se versionan en git): se bajan del repo de abbodi1406
            Write-Host '  descargando tools\W10MUI\dism desde GitHub (abbodi1406/BatUtil)'
            $tree = Invoke-RestMethod 'https://api.github.com/repos/abbodi1406/BatUtil/git/trees/master?recursive=1' -Headers @{ 'User-Agent' = 'build-script' }
            foreach ($t in ($tree.tree | Where-Object { $_.type -eq 'blob' -and $_.path -like 'W10MUI/dism/*' })) {
                $dest = Join-Path $root ('tools\' + ($t.path -replace '/', '\'))
                New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
                Invoke-WebRequest "https://raw.githubusercontent.com/abbodi1406/BatUtil/master/$($t.path)" -OutFile $dest -UseBasicParsing
            }
            Copy-Item "$w10mui\dism" "$mui\" -Recurse -Force
        }
        Copy-Item "$langDir\Langs\*" "$mui\Langs\" -Force
        New-Item -ItemType Directory -Force "$mui\OnDemand\x64" | Out-Null
        Copy-Item "$langDir\OnDemand\x64\*.cab" "$mui\OnDemand\x64\" -Force
        # W10UI parcheado (sin el supresor ESU) + updates como hardlinks (mismo disco, sin copiar 1.6 GB)
        Copy-Item "$w10ui\W10UI.cmd" "$mui\Updates\W10UI.cmd" -Force
        Set-IniValues "$mui\Updates\W10UI.ini" $w10uiOpts
        Get-ChildItem $updates -File -Include *.msu, *.cab -Recurse | Where-Object { $_.Name -notlike 'defender-update-kit*' } |
            ForEach-Object { New-Item -ItemType HardLink -Path "$mui\Updates\$($_.Name)" -Target $_.FullName | Out-Null }
        # Variables de W10MUI (no tiene .ini): modo debug = sin preguntas y log en W10MUI_tmp.log
        $cfg = @{ DVDPATH = $prep; ISO = 0; WINPE = 0; SLIM = 0; NET35 = 0; DEFAULTLANGUAGE = $Language; MOUNTDIR = "$work\W10MUImount"; _Debug = 1 }
        $cmd = Get-Content "$mui\W10MUI.cmd"
        foreach ($k in $cfg.Keys) { $cmd = $cmd -replace "^set $([regex]::Escape($k))=.*$", "set $k=$($cfg[$k])" }
        Set-Content "$mui\W10MUI.cmd" $cmd -Encoding ASCII

        Step integ "Integrando $Language + actualizaciones con W10MUI (tarda 60-90 min)"
        $log = "$mui\W10MUI_tmp.log"
        $p = Start-Process cmd.exe -ArgumentList '/c', "`"$mui\W10MUI.cmd`"" -WorkingDirectory $mui -WindowStyle Hidden -PassThru
        $est = 80.0; $t1 = Get-Date; $last = ''
        while (-not $p.HasExited) {
            Start-Sleep 30
            $line = ''
            if (Test-Path $log) {
                try {
                    $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
                    $txt = $sr.ReadToEnd(); $sr.Close()
                    $line = ($txt -split "`r?`n" | Where-Object { $_ -match '\S' -and $_ -notmatch '^=+$|^\[=' } | Select-Object -Last 1)
                } catch { }
            }
            $min = ((Get-Date) - $t1).TotalMinutes
            $pct = 20 + [int][math]::Min(74, 74 * $min / $est)   # aproximado por tiempo (20 -> 94 %)
            if ($line -ne $last) { Write-Host ("  [{0,3}%] {1:N0} min  {2}" -f $pct, $min, $line.Trim()); $last = $line }
            Write-Progress -Activity "Build ISO LTSC 2021 IoT ($Language)" -Status "W10MUI: $($line.Trim())" -PercentComplete $pct
        }
        $dbg = Get-ChildItem "$mui\W10MUI_Debug.log" -ErrorAction SilentlyContinue
        # Al terminar, W10MUI renombra _DVD10 con la etiqueta de la build (p. ej. 19044.7850...X64FRE_ES-MX_EN-US)
        $outDir = Get-ChildItem $mui -Directory | Where-Object { Test-Path "$($_.FullName)\sources\install.wim" } | Select-Object -First 1
        if (-not $outDir) { throw "W10MUI no generó la distribución. Revisa $($dbg.FullName)" }
        if (Test-Path $dvd) { Remove-Item $dvd -Recurse -Force }
        Move-Item $outDir.FullName $dvd
        Copy-Item $dbg.FullName "$work\W10MUI-$Language.log" -ErrorAction SilentlyContinue
        Remove-Item $mui, $prep -Recurse -Force -ErrorAction SilentlyContinue
    }
    $info = Get-WindowsImage -ImagePath "$dvd\sources\install.wim" -Index 1
    Write-Host "  install.wim: $($info.Version) | idiomas: $($info.Languages -join ', ') | predeterminado: $($info.Languages[$info.DefaultLanguageIndex])"
}

# --- 4. Desatendido + scripts + apps offline ------------------------------
Step unattend 'Agregando autounattend.xml, $OEM$ y apps offline'
[xml]$ua = Get-Content "$root\unattend\autounattend.xml" -Raw -Encoding UTF8
if (-not $baseLang) {
    # Windows instalado en $Language (UILanguage de windowsPE y oobeSystem). El instalador también,
    # porque W10MUI agrega los recursos de setup del idioma a boot.wim.
    foreach ($n in $ua.SelectNodes("//*[local-name()='UILanguage']")) { $n.InnerText = $Language }
}
$ua.Save("$dvd\autounattend.xml")
$oem = "$dvd\sources\`$OEM`$"
if (Test-Path -LiteralPath $oem) { Remove-Item -LiteralPath $oem -Recurse -Force }
Copy-Item -LiteralPath "$root\unattend\`$OEM`$" -Destination "$dvd\sources\" -Recurse -Force
$appsDest = "$oem\`$`$\Setup\Apps"   # -> C:\Windows\Setup\Apps (install-defaults.ps1 lo borra al terminar)
New-Item -ItemType Directory -Force -Path $appsDest | Out-Null
Get-ChildItem $appsDir -Recurse -File -Include *.msi, *.msixbundle, *.appx, License1.xml | Copy-Item -Destination $appsDest -Force
Write-Host ("  apps offline: {0:N0} MiB" -f ((Get-ChildItem $appsDest | Measure-Object Length -Sum).Sum / 1MB))

# --- 5. Crear el ISO (solo reemplaza el de este idioma) -------------------
Step iso 'Creando el ISO (IMAPI2, BIOS + UEFI)'
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
    [xml]$u = Get-Content "$drive\autounattend.xml" -Raw
    [pscustomobject]@{
        ISO = $newIso.Name; TamanoGB = [math]::Round($newIso.Length / 1GB, 2)
        Edicion = $info.ImageName; Version = $info.Version
        Ediciones = @(Get-WindowsImage -ImagePath "$drive\sources\install.wim").Count
        Idiomas = $info.Languages -join ', '
        IdiomaPredeterminado = $info.Languages[$info.DefaultLanguageIndex]
        UnattendUILanguage = ($u.SelectNodes("//*[local-name()='UILanguage']") | ForEach-Object InnerText | Select-Object -Unique) -join ', '
        InstallWimGB = [math]::Round((Get-Item "$drive\sources\install.wim").Length / 1GB, 2)
        Scripts = (Get-ChildItem -LiteralPath $scripts -Name) -join ', '
        AppsOffline = (Get-ChildItem -LiteralPath "$drive\sources\`$OEM`$\`$`$\Setup\Apps" -Name) -join ', '
        ArranqueBIOS = Test-Path "$drive\boot\etfsboot.com"
        ArranqueUEFI = Test-Path "$drive\efi\microsoft\boot\efisys.bin"
    } | Format-List
} finally { Dismount-DiskImage -ImagePath $newIso.FullName | Out-Null }
Write-Progress -Activity "Build ISO LTSC 2021 IoT ($Language)" -Completed
Write-Host ("[100%] Listo en {0:hh\:mm\:ss}" -f ((Get-Date) - $script:t0)) -ForegroundColor Green
