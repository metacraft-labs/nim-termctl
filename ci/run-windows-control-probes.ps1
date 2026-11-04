# Mandatory native Windows controls after the unchanged original test suites.
param(
  [Parameter(Mandatory)][string]$OwnerImage,
  [Parameter(Mandatory)][string]$EventImage,
  [Parameter(Mandatory)][ValidateSet('orc','arc','refc')][string]$MemoryManager,
  [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Native Windows is required' }
$osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$expectedMachine = switch ($osArch) {
  'X64' { 0x8664 }
  'Arm64' { 0xAA64 }
  default { throw "Unsupported native Windows architecture: $osArch" }
}
$images = @{}
foreach ($entry in @(@('owner', $OwnerImage), @('event', $EventImage))) {
  $file = Get-Item -LiteralPath $entry[1]
  if ($file.PSIsContainer -or $file.Extension -ne '.exe' -or $file.LinkType) { throw 'Regular native control executable required' }
  $bytes = [IO.File]::ReadAllBytes($file.FullName)
  if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'Invalid DOS executable header' }
  $pe = [BitConverter]::ToInt32($bytes, 0x3C)
  if ($pe -lt 0 -or $pe -gt $bytes.Length - 24 -or [BitConverter]::ToUInt32($bytes, $pe) -ne 0x00004550) { throw 'Invalid PE header' }
  $machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
  if ($machine -ne $expectedMachine) { throw 'Control image is not native to the actual Windows OS architecture' }
  $images[$entry[0]] = @{file=$file; SHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash; machine=$machine}
}
$output = Get-Item -LiteralPath $OutputDirectory
if (-not $output.PSIsContainer) { throw 'Existing counted output directory required' }
$cases = @(
  @{image='event'; scenario='event'},
  @{image='event'; scenario='reentrant-uninstall'},
  @{image='event'; scenario='default-termination'},
  @{image='owner'; scenario='lexical-captured-identity'},
  @{image='owner'; scenario='automatic-main-return'},
  @{image='owner'; scenario='automatic-main-quit'},
  @{image='owner'; scenario='automatic-worker-return'},
  @{image='owner'; scenario='overlap-generation-self-uninstall'},
  @{image='owner'; scenario='foreign-captured-replacement-refusal'},
  @{image='owner'; scenario='bounded-legacy-replacement'},
  @{image='owner'; scenario='pending-wait-cancellation'},
  @{image='owner'; scenario='callback-catchable-exception'},
  @{image='owner'; scenario='callback-base-exception'},
  @{image='owner'; scenario='callback-defect'}
)
$imageProof = @{}
foreach ($name in $images.Keys) {
  $imageProof[$name] = @{path=$images[$name].file.FullName; SHA256=$images[$name].SHA256; machine=$images[$name].machine}
}
$rows = [Collections.Generic.List[object]]::new()
foreach ($case in $cases) {
  $image = $images[$case.image]
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $image.file.FullName
  $start.ArgumentList.Add('--termctl-private-raw-console-child')
  $start.UseShellExecute = $false
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  if ($case.image -eq 'owner') { $start.Environment['TERMCTL_OWNER_SCENARIO'] = $case.scenario }
  else { $start.Environment['TERMCTL_CONTROL_SCENARIO'] = $case.scenario }
  $child = [Diagnostics.Process]::new()
  $child.StartInfo = $start
  $row = [ordered]@{image=$case.image; scenario=$case.scenario; pid=$null; actualRetainedProcess=$true; deadlineFailure=$false}
  try {
    if (-not $child.Start()) { throw 'Control process failed to start' }
    $row.pid = $child.Id
    $stdout = $child.StandardOutput.ReadToEndAsync()
    $stderr = $child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(15000)) { $row.deadlineFailure=$true; $child.Kill() }
    $child.WaitForExit()
    $row.exit = $child.ExitCode
    $row.stdout = $stdout.GetAwaiter().GetResult()
    $row.stderr = $stderr.GetAwaiter().GetResult()
    $rows.Add($row)
    [ordered]@{nativeOSArchitecture=$osArch; declaredMemoryManager=$MemoryManager; images=$imageProof; rows=$rows.ToArray()} |
      ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output.FullName 'windows-control-probes.json') -Encoding utf8
    if ($row.deadlineFailure) { throw "Control deadline expired: $($case.scenario)" }
    if ($case.scenario -eq 'default-termination') {
      $rawExit = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$row.exit), 0)
      if ($rawExit -ne 0xC000013AL) { throw 'Actual default CTRL_BREAK termination was not observed' }
    } elseif ($case.scenario -in @('callback-base-exception', 'callback-defect')) {
      if ($row.exit -eq 0) { throw 'Fatal callback returned normally' }
      if (-not $row.stdout.Contains('TERMCTL_FATAL_CALLBACK_RAISE:' + $case.scenario)) { throw 'Missing actual prethrow callback marker' }
      if ($row.stdout.Contains('TERMCTL_OWNER_CONTROL_PASS:')) { throw 'Fatal callback unexpectedly emitted success' }
    } else {
      if ($row.exit -ne 0) { throw "Actual control failed: $($case.scenario)" }
      $prefix = if ($case.image -eq 'owner') { 'TERMCTL_OWNER_CONTROL_PASS:' } else { 'TERMCTL_REAL_CONTROL_PASS:' }
      if (-not $row.stdout.Contains($prefix + $case.scenario)) { throw 'Missing actual control marker' }
      if ($case.scenario.StartsWith('automatic-main-') -and -not $row.stdout.Contains('TERMCTL_AUTOMATIC_OWNER_EXIT_PASS')) {
        throw 'Missing actual late owner cleanup marker'
      }
    }
    if ((Get-FileHash -LiteralPath $image.file.FullName -Algorithm SHA256).Hash -ne $image.SHA256) { throw 'Actual control image changed' }
  } finally {
    if ($row.pid -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
    $child.Dispose()
  }
}
if ($rows.Count -ne 14) { throw 'Incomplete original-event and owner-lifetime control inventory' }
