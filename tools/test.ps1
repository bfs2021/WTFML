#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('affected', 'quick', 'full', 'core', 'window', 'java', 'mods', 'upgrade', 'network', 'visual',
                 'ci-app', 'ci-core', 'ci-ui', 'ci-integration')]
    [string]$Suite = 'affected',
    [string]$BaseRef = 'origin/main',
    [string[]]$ChangedPath,
    [string]$Modules,
    [ValidateSet('Auto', 'Compact', 'Standalone')][string]$RunnerMode = 'Auto',
    [string]$BuildDir = 'build/verification-mingw13',
    [string]$ConfigurePreset = 'verification',
    [string]$ReportRoot = 'build/test-runs',
    [switch]$NoBuild,
    [switch]$ListOnly,
    [ValidateRange(1, 900)][int]$BuildTimeoutSeconds = 600,
    [ValidateRange(1, 900)][int]$TestTimeoutSeconds = 900,
    [ValidateRange(1, 16)][int]$BuildJobs = 2,
    [ValidateRange(1, 2)][int]$TestJobs = 2
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$build = [IO.Path]::GetFullPath($BuildDir, $repo)
$reports = [IO.Path]::GetFullPath($ReportRoot, $repo)
$run = Join-Path $reports ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $run -Force
$null = New-Item -ItemType Directory -Path (Join-Path $run 'temp') -Force
$stages = [Collections.Generic.List[object]]::new()
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
$hasher = [Security.Cryptography.SHA256]::Create()
try { $lockKey = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($build.ToLowerInvariant()))).Replace('-', '') }
finally { $hasher.Dispose() }
$mutex = [Threading.Mutex]::new($false, "Local\WTFML.Tests.$lockKey")
$ownsMutex = $false
$result = 1
$failure = $null

function Invoke-Stage([string]$Name, [string]$Program, [string[]]$Arguments, [int]$Timeout) {
    $out = Join-Path $run "$Name.stdout.log"
    $err = Join-Path $run "$Name.stderr.log"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "[$Name] starting; limit ${Timeout}s; logs: $run"
    # Start-Process joins ArgumentList on Windows; quote every argument, including paths with spaces.
    $quoted = @($Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' })
    $process = Start-Process -FilePath $Program -ArgumentList $quoted -WorkingDirectory $repo -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $timedOut = $false
    try {
        $nextNotice = 30
        while (-not $process.WaitForExit(1000)) {
            if ($watch.Elapsed.TotalSeconds -ge $Timeout) {
                $timedOut = $true
                $process.Kill($true)
                $null = $process.WaitForExit(10000)
                break
            }
            if ($watch.Elapsed.TotalSeconds -ge $nextNotice) {
                Write-Host "[$Name] still running ($([int]$watch.Elapsed.TotalSeconds)s); latest output:"
                Get-Content -LiteralPath $out -Tail 3 -ErrorAction SilentlyContinue | Write-Host
                $nextNotice += 30
            }
        }
        $process.Refresh()
        $code = if ($timedOut) { 124 } else { $process.ExitCode }
        $stages.Add([pscustomobject]@{ name = $Name; exitCode = $code; timedOut = $timedOut; seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2); arguments = $Arguments })
        Get-Content -LiteralPath $out -Tail 18 -ErrorAction SilentlyContinue | Write-Host
        Get-Content -LiteralPath $err -Tail 18 -ErrorAction SilentlyContinue | Write-Host
        if ($code -ne 0) { throw "Stage '$Name' failed (exit $code). First failure logs preserved: $run" }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}

try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw "Another verification run owns this build directory: $build" }
    # 测试进程的 TEMP：默认放系统临时目录；受限令牌（Windows 沙箱 / 某些企业策略）下
    # 子进程只能写工作区，那就用 `WTFML_TEST_TEMP` 指到工作区里（见 docs/dev/TESTING.md）。
    # NOTE: 别放 build/test-runs 里面 —— 那里在受限令牌下同样写不进去，症状是凡是
    # `QTemporaryDir` 取默认路径的模块直接返回 2（ctest 报 Failed、0.03 秒、只跑 2 条断言）。
    $tempBase = if ($env:WTFML_TEST_TEMP) { $env:WTFML_TEST_TEMP } else { [IO.Path]::GetTempPath() }
    $null = New-Item -ItemType Directory -Path $tempBase -Force
    $testTemp = Join-Path $tempBase ('wtfml-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $testTemp -Force
    $env:TEMP = $testTemp
    $env:TMP = $env:TEMP
    $cmake = (Get-Command cmake -ErrorAction Stop).Source
    $ctest = (Get-Command ctest -ErrorAction Stop).Source
    . (Join-Path $PSScriptRoot 'test-impact.ps1')
    . (Join-Path $PSScriptRoot 'test-build-plan.ps1')
    $impact = $null
    if ($Suite -eq 'affected') {
        $paths = if ($PSBoundParameters.ContainsKey('ChangedPath')) { $ChangedPath } else { @(Get-ChangedTestPaths $BaseRef) }
        $impact = Get-TestImpact $paths
        $impact | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $run 'impact.json') -Encoding utf8
        # An explicitly supplied -Modules is authoritative; only derive it from impact
        # analysis when the caller did not pass one (mirrors the ChangedPath check above).
        if (-not $PSBoundParameters.ContainsKey('Modules')) {
            $Modules = if ($impact.full) { '' } else { $impact.modules -join ',' }
        }
        Write-Host "Affected modules: $Modules"
    }
    $moduleTests = @()
    if ($Modules) {
        if ($Suite -ne 'affected' -and $Suite -notlike 'ci-*') { throw '-Modules requires -Suite affected or a CI partition.' }
        $catalog = (Get-TestImpact @() $true).testMap
        foreach ($module in $Modules.Split(',', [StringSplitOptions]::RemoveEmptyEntries)) {
            if (-not $catalog.Contains($module)) { throw "Unknown test module: $module" }
            $moduleTests += $catalog[$module]
        }
        $moduleTests = @($moduleTests | Sort-Object -Unique)
    }
    $skip = $Suite -eq 'affected' -and $impact.suites.Count -eq 0
    if ($skip) { Write-Host 'No build/tests required: documentation-only changes or no changes.'; $result = 0; exit 0 }
    $selection = switch ($Suite) {
        'affected' { @('-LE', 'visual') }
        { $_ -in @('ci-app', 'ci-core', 'ci-ui', 'ci-integration') } { @('-L', "^$Suite$", '-LE', 'visual') }
        'quick' { @('-R', '^wtfml\.(test-runner|test-modules|java-manage|mod-action-panel|workspace|activity-selection|theme|ui-refresh|install-layout|lifecycle|toolbox-polish|toolbox-layout|armor-trim|core-agent|ui-agent|main-window-agent)$') }
        'core' { @('-L', '^core$') }
        'java' { @('-R', '^wtfml\.java-manage$') }
        'window' { @('-R', '^wtfml\.(main-window|main-window-agent|window-chrome)$') }
        'mods' { @('-R', '^wtfml\.mod-action-panel$') }
        'upgrade' { @('-R', '^wtfml\.instance-upgrade$') }
        'network' { @('-R', '^wtfml\.(download-retry|high-speed-download|segmented-download|segment-install|preset-install|network-diag)$') }
        'visual' { @('-L', 'visual') }
        'full' { @('-LE', 'visual') }
    }
    if ($Modules) {
        $pattern = '^wtfml\.(' + (($moduleTests | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
        $selection += @('-R', $pattern)
    }
    if (-not $NoBuild -and -not $ListOnly) {
        $compact = Get-CompactTestRunnerMode $RunnerMode $Suite ([bool]$Modules)
        $runnerOption = "-DWTFML_COMPACT_TEST_RUNNERS=$compact"
        Get-Process WTFMinecraftLauncher -ErrorAction SilentlyContinue | Stop-Process -Force
        if (-not (Test-Path -LiteralPath (Join-Path $build 'CMakeCache.txt'))) {
            Invoke-Stage 'configure' $cmake @('--preset', $ConfigurePreset, '-B', $build, $runnerOption) $BuildTimeoutSeconds
        }
        # CTest is the source of truth for selection, including future registered tests.
        Invoke-Stage 'refresh-test-graph' $cmake @('-S', $repo, '-B', $build, $runnerOption) $BuildTimeoutSeconds
        Invoke-Stage 'selected-tests' $ctest (@('--test-dir', $build, '--show-only=json-v1') + $selection) 60
        $registered = (Get-Content -LiteralPath (Join-Path $run 'selected-tests.stdout.log') -Raw | ConvertFrom-Json).tests
        $targetList = [Collections.Generic.HashSet[string]]::new()
        $manifest = Get-Content -LiteralPath (Join-Path $build 'test-targets.txt') | ConvertFrom-Csv -Delimiter '|'
        foreach ($target in @(Get-TestBuildTargets $registered $manifest)) { $null = $targetList.Add($target) }
        if ($Suite -eq 'ci-app' -or ($Suite -eq 'affected' -and 'app' -in $impact.modules) -or $Suite -eq 'full') {
            $null = $targetList.Add('WTFMinecraftLauncher')
            $null = $targetList.Add('WTFMLNetworkDiag')
        }
        $targets = @($targetList | Sort-Object)
        foreach ($runtime in @(Get-TestRuntimeTargets $targets)) {
            Invoke-Stage "build-$runtime" $cmake @('--build', $build, '--target', $runtime, '--parallel', "$BuildJobs") $BuildTimeoutSeconds
        }
        foreach ($target in $targets) {
            if ($Suite -in @('ci-app', 'affected', 'full') -and $target -eq 'WTFMinecraftLauncher') {
                # Cold launcher compilation can exceed one 900s stage. Build explicit,
                # non-overlapping object batches first, then let CMake link the full target.
                # Dependencies (including Qt autogen) remain managed by Ninja itself.
                $cache = Get-Content -LiteralPath (Join-Path $build 'CMakeCache.txt')
                if ($cache -contains 'CMAKE_GENERATOR:INTERNAL=Ninja') {
                    # Refresh before enumerating: newly added translation units must join
                    # a bounded batch, not accumulate in the final link stage.
                    Invoke-Stage 'refresh-build-graph' $cmake @('-S', $repo, '-B', $build) $BuildTimeoutSeconds
                    $makeLine = @($cache | Where-Object { $_ -match '^CMAKE_MAKE_PROGRAM:FILEPATH=' })
                    if ($makeLine.Count -ne 1) { throw 'Cannot identify the configured Ninja executable.' }
                    $ninja = ($makeLine[0] -split '=', 2)[1]
                    Invoke-Stage 'list-launcher-objects' $ninja @('-C', $build, '-t', 'targets', 'all') 60
                    . (Join-Path $PSScriptRoot 'ci-object-batches.ps1')
                    $objects = @(Get-CiLauncherObjects (Get-Content -LiteralPath (Join-Path $run 'list-launcher-objects.stdout.log')))
                    for ($offset = 0; $offset -lt $objects.Count; $offset += 32) {
                        $last = [math]::Min($offset + 31, $objects.Count - 1)
                        $batch = @($objects[$offset..$last])
                        Invoke-Stage "build-launcher-objects-$([int]($offset / 32) + 1)" $cmake `
                            (@('--build', $build, '--parallel', "$BuildJobs", '--target') + $batch) $BuildTimeoutSeconds
                    }
                }
            }
            Invoke-Stage "build-$target" $cmake @('--build', $build, '--target', $target, '--parallel', "$BuildJobs") $BuildTimeoutSeconds
        }
    }
    $testArgs = @('--test-dir', $build, '--no-tests=error', '--output-on-failure', '--parallel', "$TestJobs", '--timeout', '900') + $selection
    if ($ListOnly) { $testArgs += @('--show-only=json-v1') }
    else { $testArgs += @('--verbose', '--output-junit', (Join-Path $run 'results.xml')) }
    Invoke-Stage 'test' $ctest $testArgs $TestTimeoutSeconds
    $result = 0
} catch {
    $failure = "$_"
    Write-Host "ERROR: $_" -ForegroundColor Red
} finally {
    $summary = [ordered]@{ suite = $Suite; buildDir = $build; listOnly = [bool]$ListOnly; noBuild = [bool]$NoBuild; testJobs = $TestJobs; exitCode = $result; error = $failure; stages = @($stages.ToArray()) }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $run 'summary.json') -Encoding utf8
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
    if ($testTemp -and (Test-Path -LiteralPath $testTemp)) {
        Remove-Item -LiteralPath $testTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    Write-Host "Verification report: $run"
}
exit $result
