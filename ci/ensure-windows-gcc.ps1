# Provision the declared x64 C compiler without changing the selected Nim SDK.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or
    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This compiler prerequisite requires native Windows x64; no ARM emulation fallback'
}
function Regular-File([string]$path) {
    if (-not [IO.Path]::IsPathFullyQualified($path)) { throw 'Relative file authority refused' }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Nonregular file authority refused' }
    [ordered]@{path=$item.FullName;length=$item.Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
function Checked-Directory([string]$path) {
    if (-not [IO.Path]::IsPathFullyQualified($path)) { throw 'Relative directory authority refused' }
    $item = Get-Item -LiteralPath $path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Foreign directory authority refused' }
    $item.FullName
}
$root = Join-Path (Checked-Directory $env:RUNNER_TEMP) ('termctl-gcc-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
Checked-Directory $root | Out-Null
$source = Join-Path $root 'source'
$toolRoot = Join-Path $root 'toolchain'
New-Item -ItemType Directory -Path $source -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path $toolRoot -ErrorAction Stop | Out-Null
$pin = '76659f5730ecf698b1963c656494d2cb66eb256d'
$hashes = @{
    'toolchain-utils.ps1' = 'd1cb869b8c0652cbd96e362bc88d23b46385e6468be654adf0de8a276772979b'
    'ensure-gcc.ps1' = '96c893eb18253469092960a548858bbaa3da3ea0cc53fa3a47478256f73176eb'
    'toolchain-versions.env' = '9bde26a453e5af29512b44dd04156e90a4a4df886dd15acbc896ff84f22ea5cd'
}
$held = @{}
$client = [Net.Http.HttpClient]::new()
try {
    foreach ($name in $hashes.Keys) {
        $bytes = $client.GetByteArrayAsync("https://raw.githubusercontent.com/metacraft-labs/reprobuild/$pin/windows/$name").GetAwaiter().GetResult()
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($digest -cne $hashes[$name]) { throw "Selected source hash mismatch: $name" }
        $path = Join-Path $source $name
        $writer = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $writer.Write($bytes,0,$bytes.Length);$writer.Flush($true) } finally { $writer.Dispose() }
        # Readers must share every existing access on Windows. Retain a
        # read-only, no-write/no-delete-sharing handle and authenticate THAT
        # handle after reopening, before any path-based source consumer runs.
        $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $held[$name] = $stream
        $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
        $stream.Position = 0
        if ($actual -cne $hashes[$name]) { throw "Reopened source hash mismatch: $name" }
    }
    # Execute only the already authenticated bytes, not another path lookup.
    . ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $source 'toolchain-utils.ps1'))))
    . ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $source 'ensure-gcc.ps1'))))
    $pins = Read-KeyValueFile -Path (Join-Path $source 'toolchain-versions.env')
    if ($pins.GCC_VERSION -cne '16.1.0' -or $pins.GCC_WINLIBS_RELEASE -cne '16.1.0posix-14.0.0-ucrt-r2' -or
        $pins.GCC_WINLIBS_SHA256 -cne '78eff1e2e804b6a6320c713f084b8f820c662104a24cea6a3bfcab82032bdd60') { throw 'Selected compiler pin mismatch' }
    # The sole early-return branch requires an installed compiler+metadata.
    # This newly created empty Root has neither, so ambient gcc cannot win it.
    if (@(Get-ChildItem -LiteralPath (Checked-Directory $toolRoot) -Force).Count -ne 0) { throw 'Fresh toolchain Root changed' }
    $tar = Regular-File (Join-Path $env:SystemRoot 'System32/tar.exe')
    $installation = @(Ensure-Gcc -Root $toolRoot -Arch 'x64' -Toolchain $pins)
    if ($installation.Count -ne 1) { throw 'Unexpected compiler installation result' }
    $expectedPrefix = [IO.Path]::GetFullPath((Join-Path $toolRoot 'gcc/16.1.0'))
    if ([IO.Path]::GetFullPath($installation[0]) -ine $expectedPrefix) { throw 'Foreign compiler prefix returned' }
    Checked-Directory $expectedPrefix | Out-Null
    $compiler = Regular-File (Join-Path $expectedPrefix 'bin/gcc.exe')
    $archive = Regular-File (Join-Path $toolRoot 'gcc/_downloads/winlibs-x86_64-posix-seh-gcc-16.1.0-mingw-w64ucrt-14.0.0-r2.zip')
    if ($archive.sha256 -cne $pins.GCC_WINLIBS_SHA256) { throw 'Changed verified compiler archive' }
    $image = [IO.File]::ReadAllBytes($compiler.path)
    if ($image.Length -lt 64 -or [BitConverter]::ToUInt16($image,0) -ne 0x5a4d) { throw 'Missing compiler DOS image' }
    $pe = [BitConverter]::ToInt32($image,0x3c)
    if ($pe -lt 0 -or $pe -gt $image.Length-26 -or [BitConverter]::ToUInt32($image,$pe) -ne 0x4550 -or
        [BitConverter]::ToUInt16($image,$pe+4) -ne 0x8664 -or [BitConverter]::ToUInt16($image,$pe+24) -ne 0x20b) { throw 'Compiler is not native x64 PE32+' }
    $bin = Split-Path $compiler.path -Parent
    $env:PATH = $bin+[IO.Path]::PathSeparator+$env:PATH
    $resolved = (Get-Command gcc.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    if ([IO.Path]::GetFullPath($resolved) -ine $compiler.path) { throw 'Ambient compiler still shadows the declared compiler' }
    $version = @(& $compiler.path -dumpfullversion 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or $version.Count -ne 1 -or $version[0] -cne '16.1.0') { throw 'Compiler version mismatch' }
    $target = @(& $compiler.path -dumpmachine 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or $target.Count -ne 1 -or $target[0] -cne 'x86_64-w64-mingw32') { throw 'Compiler target mismatch' }
    $nim = Regular-File ((Get-Command nim.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    $dump = & $nim.path dump --dump.format:json --skipParentCfg --skipUserCfg tests/test_windows_signals_compile.nim 2> (Join-Path $root 'nim-dump.stderr')
    if ($LASTEXITCODE -ne 0) { throw 'Selected Nim library lookup failed' }
    [IO.File]::WriteAllText((Join-Path $root 'nim-dump.json'),($dump -join "`n"))
    $nimLib = Checked-Directory (($dump -join "`n" | ConvertFrom-Json).libpath)
    $nimBase = Regular-File (Join-Path $nimLib 'nimbase.h')
    $cSource = Join-Path $root 'headers.c'
    [IO.File]::WriteAllText($cSource,"#define NIM_INTBITS 64`n#include <nimbase.h>`n#include <windows.h>`n#include <stdint.h>`n#include <stdio.h>`nint main(void) { uint32_t tid = GetCurrentThreadId(); return tid == 0; }`n")
    & $compiler.path "-I$nimLib" $cSource -o (Join-Path $root 'headers.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Real Nim/stdlib/Win32 header compile failed' }
    & (Join-Path $root 'headers.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Real compiled Win32 header control failed' }
    $nimProbe = Join-Path $root 'native_probe.nim'
    [IO.File]::WriteAllText($nimProbe,"proc tid(): uint32 {.importc: `"GetCurrentThreadId`", header: `"<windows.h>`", stdcall.}`nif tid() == 0: quit(1)`n")
    & $nim.path c --skipParentCfg --skipUserCfg ("--nimcache:"+(Join-Path $root 'nimcache')) ("--out:"+(Join-Path $root 'native_probe.exe')) $nimProbe
    if ($LASTEXITCODE -ne 0) { throw 'Default Nim C-backend header compile failed' }
    & (Join-Path $root 'native_probe.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Default Nim C-backend control failed' }
    & $compiler.path -c -DWIN32_LEAN_AND_MEAN src/nim_termctl/ctrl_owner.c -o (Join-Path $root 'ctrl_owner.o')
    if ($LASTEXITCODE -ne 0) { throw 'Actual native owner C implementation compile failed' }
    if ((Regular-File $compiler.path).sha256 -cne $compiler.sha256 -or (Regular-File $nim.path).sha256 -cne $nim.sha256 -or
        (Regular-File $nimBase.path).sha256 -cne $nimBase.sha256) { throw 'Compiler/Nim identity changed during controls' }
    $receipt = [ordered]@{sourcePin=$pin;helperHashes=$hashes;compiler=$compiler;archive=$archive;nim=$nim;nimBase=$nimBase;version=$version[0];target=$target[0];headerCompileAndRun='passed';defaultNimCompileAndRun='passed';extractor=$tar;actualOwnerCCompile='passed';scope='x64 compiler prerequisite only; original suites and Windows lifetime controls remain mandatory'}
    [IO.File]::WriteAllText((Join-Path $root 'compiler-prerequisite.json'),($receipt|ConvertTo-Json -Depth 6))
    if ($bin.Contains("`r") -or $bin.Contains("`n")) { throw 'Invalid compiler path line' }
    $pathFile = Regular-File $env:GITHUB_PATH
    $append = [IO.File]::Open($pathFile.path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    try {
        if ($append.Length -ne $pathFile.length) { throw 'Activation file changed before append' }
        if ($append.Length -gt 0) { $append.Seek(-1,[IO.SeekOrigin]::End)|Out-Null;if ($append.ReadByte() -ne 10) { throw 'Malformed existing activation path line' } }
        $append.Seek(0,[IO.SeekOrigin]::End)|Out-Null
        $bytes=[Text.Encoding]::UTF8.GetBytes($bin+"`n");$append.Write($bytes,0,$bytes.Length);$append.Flush($true)
    } finally { $append.Dispose() }
    Write-Host ('Declared compiler {0}; SHA256={1}; Nim library {2}' -f $compiler.path,$compiler.sha256,$nimLib)
    Write-Host ('Compiler prerequisite receipt: '+(Join-Path $root 'compiler-prerequisite.json'))
} finally {
    foreach ($stream in $held.Values) { $stream.Dispose() }
    $client.Dispose()
}
