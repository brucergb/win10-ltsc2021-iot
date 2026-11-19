<#
.SYNOPSIS
  Crea un ISO booteable (BIOS + UEFI) a partir de una carpeta de instalación de Windows,
  usando IMAPI2 (incluido en Windows; no requiere ADK/oscdimg).
.EXAMPLE
  .\tools\New-IsoImage.ps1 -Source .\work\dvd -Iso .\out\win10.iso -Label LTSC2021_IOT
#>
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Iso,
    [string]$Label = 'DVD_ROM'
)
$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path $Source).Path

if (-not ('IsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class IsoWriter {
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateStreamOnFileEx(string f, uint mode, uint attr, bool create, IStream tmpl, out IStream s);
    public static void Write(string file, object imageStream, int blockSize, int totalBlocks) {
        IStream src = (IStream)imageStream, dst;
        SHCreateStreamOnFileEx(file, 0x1001, 0x80, true, null, out dst);   // STGM_CREATE|STGM_WRITE
        const int chunkBlocks = 1024;
        long done = 0; int lastPct = -1;
        while (done < totalBlocks) {
            int n = (int)Math.Min(chunkBlocks, totalBlocks - done);
            src.CopyTo(dst, (long)n * blockSize, IntPtr.Zero, IntPtr.Zero);
            done += n;
            int pct = (int)(done * 100 / totalBlocks);
            if (pct / 5 != lastPct / 5) { Console.WriteLine("  [{0,3}%] {1:N0}/{2:N0} MiB", pct, done * blockSize >> 20, (long)totalBlocks * blockSize >> 20); lastPct = pct; }
        }
        dst.Commit(0);
    }
}
'@
}

# Imágenes de arranque: El Torito BIOS (PlatformId 0) + UEFI (PlatformId 0xEF), sin emulación
$boot = @()
foreach ($b in @(@{ f = 'boot\etfsboot.com'; p = 0 }, @{ f = 'efi\microsoft\boot\efisys.bin'; p = 0xEF })) {
    $path = Join-Path $Source $b.f
    if (-not (Test-Path $path)) { throw "Falta el archivo de arranque $path" }
    $stream = New-Object -ComObject ADODB.Stream
    $stream.Open(); $stream.Type = 1; $stream.LoadFromFile($path)
    $opt = New-Object -ComObject IMAPI2FS.BootOptions
    $opt.AssignBootImage($stream.psobject.BaseObject)
    $opt.Manufacturer = 'Microsoft'; $opt.PlatformId = $b.p; $opt.Emulation = 0
    $boot += $opt.psobject.BaseObject
}

$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.FileSystemsToCreate = 4      # UDF (admite archivos > 4 GB)
$fsi.UDFRevision = 0x102
$fsi.FreeMediaBlocks = 0          # sin límite de tamaño de medio
$fsi.VolumeName = $Label
$fsi.BootImageOptionsArray = $boot
Write-Host "Agregando archivos de $Source ..."
$fsi.Root.AddTree($Source, $false)
$res = $fsi.CreateResultImage()
if (Test-Path $Iso) { Remove-Item $Iso -Force }
Write-Host "Escribiendo $Iso"
[IsoWriter]::Write([IO.Path]::GetFullPath($Iso), $res.ImageStream, $res.BlockSize, $res.TotalBlocks)
[GC]::Collect()
Get-Item $Iso
