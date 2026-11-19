# Menú de apps opcionales: casillas -> instalación con winget (siempre la última versión).
# Se abre solo en el primer inicio de sesión (FirstLogonCommands) y desde el acceso directo
# "Instalar apps opcionales" del menú Inicio. Lista editable: apps-opcionales.json (misma carpeta).

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $env:ProgramData 'apps-opcionales.log'

# --- Autoelevación (el acceso directo lo abre sin privilegios) ---
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    exit
}

$apps = Get-Content (Join-Path $here 'apps-opcionales.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# --- Ventana de selección ---
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form -Property @{
    Text = 'Apps opcionales'; Size = New-Object Drawing.Size(560, 520); StartPosition = 'CenterScreen'
    FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; TopMost = $true
    Font = New-Object Drawing.Font('Segoe UI', 10)
}
$lbl = New-Object Windows.Forms.Label -Property @{
    Text = "Marca lo que quieras instalar (necesita internet).`nPuedes volver a abrir este menú desde Inicio > 'Instalar apps opcionales'."
    Location = New-Object Drawing.Point(12, 10); Size = New-Object Drawing.Size(520, 44)
}
$list = New-Object Windows.Forms.CheckedListBox -Property @{
    Location = New-Object Drawing.Point(12, 60); Size = New-Object Drawing.Size(520, 330); CheckOnClick = $true
}
foreach ($a in $apps) { [void]$list.Items.Add("$($a.name)  —  $($a.desc)") }
$all = New-Object Windows.Forms.Button -Property @{ Text = 'Marcar todo'; Location = New-Object Drawing.Point(12, 405); Size = New-Object Drawing.Size(120, 34) }
$all.Add_Click({ $on = $list.CheckedItems.Count -lt $list.Items.Count; for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $on) } })
$ok = New-Object Windows.Forms.Button -Property @{ Text = 'Instalar'; Location = New-Object Drawing.Point(312, 405); Size = New-Object Drawing.Size(105, 34); DialogResult = 'OK' }
$cancel = New-Object Windows.Forms.Button -Property @{ Text = 'Ahora no'; Location = New-Object Drawing.Point(427, 405); Size = New-Object Drawing.Size(105, 34); DialogResult = 'Cancel' }
$form.Controls.AddRange(@($lbl, $list, $all, $ok, $cancel))
$form.AcceptButton = $ok; $form.CancelButton = $cancel
if ($form.ShowDialog() -ne 'OK' -or $list.CheckedIndices.Count -eq 0) { exit }
$selected = @($list.CheckedIndices | ForEach-Object { $apps[$_] })

# --- Preparar winget ---
$host.UI.RawUI.WindowTitle = 'Instalando apps opcionales'
function Find-Winget {
    $w = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    $p = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
    if ($p) { return $p.FullName }
    return $null
}
$winget = Find-Winget
if (-not $winget -and ($selected | Where-Object { $_.ids })) {
    Write-Host 'Registrando winget (App Installer)...'
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { Write-Host "  $_" }
    for ($i = 0; $i -lt 30 -and -not $winget; $i++) { Start-Sleep 2; $winget = Find-Winget }
    if (-not $winget) { Write-Host 'No encontré winget. Revisa que App Installer esté instalado.' -ForegroundColor Red }
}
Write-Host 'Esperando conexión a internet...'
for ($i = 0; $i -lt 60; $i++) { if (Test-Connection -ComputerName cdn.winget.microsoft.com -Count 1 -Quiet) { break }; Start-Sleep 5 }

# --- Instalación con progreso ---
$steps = @(); foreach ($a in $selected) { if ($a.store) { $steps += [pscustomobject]@{ name = $a.name; id = $null } } else { foreach ($id in $a.ids) { $steps += [pscustomobject]@{ name = $a.name; id = $id } } } }
$results = @(); $n = $steps.Count; $k = 0
"=== $(Get-Date -Format s) ===" | Add-Content $log
foreach ($s in $steps) {
    $k++
    $pct = [int](($k - 1) * 100 / $n)
    Write-Host ("`n[{0,3}%] {1}/{2}  {3} {4}" -f $pct, $k, $n, $s.name, $(if ($s.id) { "($($s.id))" })) -ForegroundColor Cyan
    Write-Progress -Activity 'Apps opcionales' -Status "$k/$n  $($s.name)" -PercentComplete $pct
    if ($s.id) {
        if (-not $winget) { $code = -1 } else {
            & $winget install --id $s.id -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
            $code = $LASTEXITCODE
        }
        # -1978335189 = ya instalado / sin actualización disponible
        $okk = ($code -eq 0 -or $code -eq -1978335189)
    } else {
        # Microsoft Store: wsreset -i la descarga e instala en segundo plano
        Start-Process wsreset.exe -ArgumentList '-i' -WindowStyle Hidden
        Write-Host '  Instalando Store en segundo plano (hasta 5 min)...'
        $okk = $false
        for ($i = 0; $i -lt 60; $i++) { Start-Sleep 5; if (Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue) { $okk = $true; break } }
        $code = if ($okk) { 0 } else { 'timeout' }
    }
    $results += [pscustomobject]@{ App = $s.name; Id = $s.id; Resultado = $(if ($okk) { 'OK' } else { "FALLÓ ($code)" }) }
    "$($s.name) [$($s.id)] -> $code" | Add-Content $log
}
Write-Progress -Activity 'Apps opcionales' -Completed
Write-Host "`n[100%] Terminado. Resumen (log en $log):" -ForegroundColor Green
$results | Format-Table -AutoSize | Out-String | Write-Host
Read-Host 'Presiona Enter para cerrar'
