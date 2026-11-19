# Windows 10 IoT Enterprise LTSC 2021 — ISO actualizado y semi-desatendido

Genera un ISO de **Windows 10 IoT Enterprise LTSC 2021** con:

- **Actualizaciones integradas** (acumulativa del SO, .NET, WinRE, instalador y Defender), para no esperar horas de Windows Update después de instalar.
- **Solo la edición IoT Enterprise LTSC.** Tiene soporte hasta el **13 de enero de 2032**; la Enterprise LTSC "normal" termina en enero de 2027.
- **Instalación semi-desatendida**: no pregunta idioma ni EULA y no ofrece cuenta Microsoft. **Sí pregunta el disco/particiones** y la **cuenta local**.
- **Ajustes de seguridad y privacidad** que se aplican solos al final de la instalación.
- **Apps por defecto (offline):** Edge actualizado, **ImageGlass** como visor de imágenes predeterminado (con el Visor de fotos clásico como alternativa) y **winget**. Internet Explorer 11 se quita.
- **Apps opcionales:** en el primer inicio de sesión aparece un menú con casillas para instalar con winget, siempre en la última versión: 7-Zip, Notepad++, VLC, AIMP, qBittorrent, ONLYOFFICE, Zoom, Brave, PowerToys, Visual C++, Windows Terminal, Minecraft Launcher y Microsoft Store (experimental).

Todo es local, con herramientas gratuitas: DISM (incluido en Windows), [W10UI](https://github.com/abbodi1406/BatUtil/tree/master/W10UI) de abbodi1406 y un script propio para descargar del Microsoft Update Catalog.

## Estructura

| Ruta | Qué es |
|---|---|
| `build.ps1` | Script principal: descarga, prepara, integra y crea el ISO |
| `updates.txt` | Lista de actualizaciones (IDs del Update Catalog). **Se actualiza cada mes** |
| `unattend/autounattend.xml` | Respuestas del instalador (va en la raíz del ISO) |
| `unattend/$OEM$/$$/Setup/Scripts/` | Se copian a `C:\Windows\Setup\Scripts`: `SetupComplete.cmd`, `install-defaults.ps1`, `hardening.ps1`, `apps-opcionales.ps1` + `.json` |
| `tools/catalog.py` | Busca y descarga del Microsoft Update Catalog (Python, sin dependencias) |
| `tools/New-IsoImage.ps1` | Crea un ISO booteable BIOS+UEFI con IMAPI2 (sin ADK) |
| `tools/W10UI/` | W10UI v10.67 (con un parche, ver abajo) |
| `updates/`, `apps/`, `work/`, `out/` | Descargas de updates y apps, temporales e ISO final (ignorados por git) |

## Uso

Requisitos: Windows 10/11, **PowerShell como administrador**, Python 3 en el PATH y unos **30 GB libres**.

1. Pon el ISO original en la raíz del repo (`en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso`).
2. En **PowerShell (admin)**:
   ```powershell
   cd C:\Repo\win10-ltsc2021-iot
   powershell -ExecutionPolicy Bypass -File .\build.ps1
   ```
   - `-SkipDownload` reutiliza lo que ya está en `updates\` y `apps\`, sin consultar internet.
   - `-SkipIntegration` **(modo rápido, minutos)**: reutiliza `work\dvd`, que ya tiene las updates integradas. Solo refresca `autounattend.xml`, los scripts y las apps offline, y vuelve a crear el ISO. Úsalo cuando cambies algo en `unattend\` o en la lista de apps.
   - `-Iso <ruta>` usa otro ISO de origen.
3. El ISO queda en `out\Win10_IoT_Enterprise_LTSC_2021_x64_es-MX_actualizado.iso`. Al final se imprime un resumen: versión, número de ediciones, tamaño, scripts, apps y archivos de arranque.

Tarda **entre 30 y 60 minutos**. Lo más lento es integrar la acumulativa y la limpieza de componentes.

Progreso: cada etapa imprime `==> [ NN%] ... (transcurrido hh:mm:ss)`, con el porcentaje global aproximado, y además actualiza la barra de `Write-Progress`. Las descargas muestran `[ NN%] x/y MiB` cada 5 %. Durante la etapa de W10UI (20 → 97 %), DISM muestra su propia barra `[==== 45.0% ]` por cada paquete.

### Actualizar el ISO cada mes

1. Busca las updates nuevas (Bash o PowerShell):
   ```
   python tools/catalog.py search "2026-12 Cumulative Update for Windows 10 Version 21H2 x64"
   python tools/catalog.py search "Cumulative Update for .NET Framework 3.5 and 4.8 for Windows 10 Version 21H2 for x64"
   python tools/catalog.py search "Dynamic Update for Windows 10 Version 21H2 x64-based"
   ```
2. Cambia los IDs en `updates.txt` (solo x64; la LCU es el resultado *"Cumulative Update for Windows 10 Version 21H2 for x64-based Systems"*).
3. Borra las versiones viejas de `updates\` y vuelve a correr `build.ps1`.

Cómo distinguir los dos "Dynamic Update" del catálogo, que tienen el mismo título:
- **Safe OS** (WinRE): sale cada mes, pesa más de 100 MB y lleva componentes `amd64_microsoft-windows-...`.
- **Setup** (`\sources`): sale con menos frecuencia, pesa unos 20 MB y lleva archivos tipo `AcRes.dll.mui`.

Si tienes dudas, revisa el contenido con `7z l archivo.cab`.

## Grabar a USB

El ISO pesa unos **6.4 GB** (necesitas una USB de **8 GB o más**). El `install.wim` queda en unos 5.1 GB, y FAT32 no acepta archivos de más de 4 GB. Opciones:

- **[Rufus](https://rufus.ie)** (recomendado): selecciona el ISO y listo. Si hace falta, usa NTFS con UEFI:NTFS automáticamente. En el diálogo de "Windows User Experience" **desmarca todo**, porque el ISO ya trae su propio `autounattend.xml`.
- **Ventoy**: también funciona copiando el ISO.

## Qué hace la instalación

1. Arranca directo en el instalador: sin pantalla de idioma, con la EULA aceptada.
2. **Particionado manual**: tú eliges el disco. Para borrar todo y dejar que Windows cree las particiones, elimina las particiones existentes y selecciona el espacio sin asignar.
3. OOBE: región y teclado ya configurados (interfaz en inglés, formatos **es-MX**, teclado **Español (México) – Estados Unidos-Internacional**, zona horaria **Central (México)**). Pide **nombre de usuario, contraseña y preguntas de seguridad** de la cuenta local. Se salta las pantallas de cuenta Microsoft y de privacidad.
4. Al terminar el setup, `SetupComplete.cmd` corre como SYSTEM `install-defaults.ps1` (apps por defecto) y después `hardening.ps1`. Los logs quedan en `C:\Windows\Setup\Scripts\*.log`.
5. En el primer inicio de sesión se abre el **menú de apps opcionales**.

## Apps por defecto (`install-defaults.ps1`, offline)

`build.ps1` descarga la última versión de cada una, **verifica su firma digital** y las mete en el ISO (`$OEM$\$$\Setup\Apps`, unos 540 MB). Al terminar de instalarlas, el script borra esa carpeta.

| App | Detalle |
|---|---|
| **Microsoft Edge** | MSI empresarial (Stable x64). Reemplaza el Edge de 2021 que trae la imagen. Después se sigue actualizando solo |
| **ImageGlass** | Visor de imágenes de código abierto (abre JPG, PNG, GIF, WebP, HEIC, AVIF, JXL, TIFF, ICO…). Se instala para todos los usuarios y queda **predeterminado** con un ProgID propio (`ImageGlass.Image`) + `dism /Import-DefaultAppAssociations`, así que aplica a las cuentas nuevas |
| **Visor de fotos de Windows** (clásico) | Se reactiva como alternativa en "Abrir con" (no abre WebP/HEIC) |
| **winget** (App Installer) | Aprovisionado para todos los usuarios, con sus dependencias (VCLibs, Windows App Runtime). La LTSC no lo trae |
| *(sin Internet Explorer)* | `hardening.ps1` desinstala la característica IE11. Se aplica en el siguiente reinicio. Se pierde el "modo IE" de Edge |

## Apps opcionales (`apps-opcionales.ps1`)

- Se abre solo en el primer inicio de sesión. Después está en **Inicio → "Instalar apps opcionales"**: pide permisos de administrador y se puede usar las veces que quieras.
- Marcas las casillas y cada app se instala en silencio con `winget install`. La consola muestra `[ NN%] k/n App` y un resumen al final. El log queda en `C:\ProgramData\apps-opcionales.log`.
- **Para agregar o quitar apps**, edita `unattend\$OEM$\$$\Setup\Scripts\apps-opcionales.json` y corre `build.ps1 -SkipIntegration`. El ID de cada app se busca con `winget search <nombre>`.

Notas por app:
- **Windows Terminal y PowerToys**: requieren Windows 10 19041 o más nueva. La LTSC 2021 (19044) cumple.
- **Minecraft Launcher**: es el launcher oficial de **Java Edition**.
- **Minecraft Bedrock ("Windows Edition")** necesita la **Microsoft Store, la app de Xbox y Gaming Services**. En LTSC no tiene soporte oficial. La opción "Microsoft Store (experimental)" corre `wsreset -i`, que la descarga de Microsoft, y espera hasta 5 min. Si no aparece, la LTSC no la aceptó por ese método y Bedrock no va a funcionar sin pasos extra.

Para cambiar el teclado o la región, edita `InputLocale`/`UserLocale` en `autounattend.xml` (los dos bloques: `windowsPE` y `oobeSystem`). Por ejemplo, teclado latinoamericano = `080a:0000080a`.

## Ajustes de seguridad (`hardening.ps1`)

| Ajuste | Por qué |
|---|---|
| SMBv1 deshabilitado | Protocolo obsoleto, vector de WannaCry/EternalBlue |
| PowerShell 2.0 deshabilitado | Permite evadir AMSI y el registro de scripts |
| LLMNR deshabilitado | Evita envenenamiento de nombres en la LAN (robo de hashes tipo Responder) |
| SMB como invitado prohibido | No conectarse a recursos compartidos sin autenticación |
| Asistencia remota off | Menos superficie de acceso remoto |
| Firewall forzado en todos los perfiles | Por si algún instalador lo apaga |
| AutoRun off en todas las unidades | USBs/CDs no ejecutan nada solos |
| LSA protegido (`RunAsPPL`) | Dificulta volcar credenciales de memoria (mimikatz) |
| SEHOP on | Mitiga exploits que sobrescriben manejadores de excepciones |
| WDigest off | No guardar contraseñas en claro en memoria |
| Defender: bloqueo de PUA | Bloquea adware, mineros y "bundles" |
| Telemetría nivel 0 (Seguridad) | Mínimo permitido; solo existe en ediciones Enterprise |
| ID de publicidad, historial de actividad, "experiencias personalizadas" y reportes de error off | Privacidad |
| Sin apps ni sugerencias patrocinadas | Privacidad y limpieza |
| Mostrar extensiones de archivo (usuarios nuevos) | Para detectar trampas tipo `factura.pdf.exe` |

Lo que **no** cambia: UAC, Windows Update automático, Defender activo y SmartScreen se quedan con su configuración por defecto, que ya es segura.

### Revertir ajustes

En **PowerShell (admin)** en el equipo instalado:
```powershell
# LSA protegido (si algún driver/antivirus viejo falla al cargar)
Remove-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RunAsPPL
# LLMNR (si algo de la red local deja de resolver nombres)
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name EnableMulticast
# SMBv1 (solo si de verdad tienes un NAS/impresora antigua que lo requiera)
Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol
# .NET 3.5 (apps/juegos viejos)
Enable-WindowsOptionalFeature -Online -FeatureName NetFx3
```
Reinicia después de cambiar `RunAsPPL` o las features.

### Opcionales que no se aplican

- **BitLocker**: actívalo a mano después de instalar (`manage-bde -on C:` o desde el Panel de control). Guarda la clave de recuperación.
- **Credential Guard / VBS**: depende del hardware (virtualización y Secure Boot activos). Se configura con `gpedit.msc` → *Device Guard*.

## Configuración de W10UI

`build.ps1` reescribe `tools/W10UI/W10UI.ini` en cada ejecución:

| Opción | Valor | Motivo |
|---|---|---|
| `Net35` | 0 | No habilitar .NET 3.5 (Windows lo instala bajo demanda si una app lo pide) |
| `Cleanup` / `ResetBase` | 1 / 0 | Limpiar componentes reemplazados sin romper "Restablecer este PC" |
| `WinRE` | 1 | Actualizar el entorno de recuperación |
| `ISO` | 0 | W10UI solo integra. El ISO lo crea `tools/New-IsoImage.ps1` (IMAPI2, El Torito BIOS + UEFI), porque el `DIR2ISO` de W10UI falló con "Acceso denegado" |
| `AutoStart` | 1 | Correr sin menú interactivo |

**Parche local:** en `W10UI.cmd`, línea 1638, se desactivó (con `rem`) la inyección del componente falso `ExtendedSecurityUpdatesAI`. W10UI lo agrega en las compilaciones 14393–19045 para que se instalen las updates ESU en ediciones no elegibles. **IoT Enterprise LTSC 2021 recibe actualizaciones oficialmente**, así que no hace falta y no se meten componentes falsos en la imagen. Si actualizas W10UI desde GitHub, vuelve a aplicar ese cambio, conservando los finales de línea CRLF.

## Activación

El ISO no incluye ninguna clave. Windows se instala sin activar; actívalo con tu licencia de IoT Enterprise LTSC 2021 (Settings → Activation, o `slmgr /ipk <clave>`).
