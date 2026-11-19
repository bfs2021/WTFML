#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path $repo ('build/test-runner-selfchecks/' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $work 'fixture space 测试'
$reports = Join-Path $work 'reports'
$null = New-Item -ItemType Directory -Path $fixture -Force
Copy-Item -LiteralPath (Join-Path $repo 'tests/test_runner/RunnerFixture.cmake') -Destination (Join-Path $fixture 'CTestTestfile.cmake')
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
$oldPartitionCase = $env:WTFML_PARTITION_FIXTURE_CASE
$failed = 0

function Check([bool]$Ok, [string]$Text) {
    if ($Ok) { Write-Host "PASS $Text" }
    else { Write-Host "FAIL $Text"; $script:failed++ }
}

try {
    . (Join-Path $PSScriptRoot 'test-impact.ps1')
    . (Join-Path $PSScriptRoot 'test-build-plan.ps1')
    $owners = @([pscustomobject]@{test='one'; target='ui_check_theme'}, [pscustomobject]@{test='runner'; target='-'})
    $picked = @(Get-TestBuildTargets @([pscustomobject]@{name='one'}, [pscustomobject]@{name='one'}) $owners)
    Check ($picked.Count -eq 1 -and $picked[0] -eq 'ui_check_theme') 'test build plan deduplicates independent executable targets'
    Check (@(Get-TestBuildTargets @([pscustomobject]@{name='runner'}) $owners).Count -eq 0) 'tooling tests require no C++ target'
    foreach ($invalidOwners in @(@(), @($owners[0], $owners[0]))) {
        $rejected = $false
        try { $null = Get-TestBuildTargets @([pscustomobject]@{name='one'}) $invalidOwners } catch { $rejected = $true }
        Check $rejected 'missing/duplicate build owner fails closed'
    }
    Check (@(Get-TestRuntimeTargets @('mw_check_instance_upgrade')).Count -eq 3) 'cold integration builds have three bounded shared-layer stages'
    Check (@(Get-TestRuntimeTargets @()).Count -eq 0) 'runner-only changes do not build a shared runtime'
    Check ((Get-CompactTestRunnerMode Auto ci-integration $false) -eq 'ON') 'full integration partition shares specialist link outputs'
    Check ((Get-CompactTestRunnerMode Auto ci-integration $true) -eq 'OFF') 'partial CI avoids compiling unrelated case objects'
    Check ((Get-CompactTestRunnerMode Auto affected $true) -eq 'OFF') 'single module retains independent compilation'
    Check ((Get-CompactTestRunnerMode Auto full $false) -eq 'ON') 'full runs use compact specialist runners'
    Check ((Get-CompactTestRunnerMode Standalone full $false) -eq 'OFF') 'explicit standalone fallback is available'
    $compactOwners = @([pscustomobject]@{test='one';target='mw_check_modules'}, [pscustomobject]@{test='two';target='mw_check_modules'})
    Check (@(Get-TestBuildTargets @([pscustomobject]@{name='one'}, [pscustomobject]@{name='two'}) $compactOwners).Count -eq 1) 'compact owner registry links selected runner only once'
    $docs = Get-TestImpact @('docs/features/INSTANCE_UPGRADE.md', 'README.md')
    Check ($docs.suites.Count -eq 0) 'documentation-only changes skip compiled CI partitions'
    $javaCase = Get-TestImpact @('tests/core_modules/AsciiAliasTests.cpp')
    Check (-not $javaCase.full -and $javaCase.modules.Count -eq 1 -and $javaCase.modules[0] -eq 'core-java') 'one core case selects only its owning executable'
    Check ($javaCase.suites.Count -eq 1 -and $javaCase.suites[0] -eq 'ci-core') 'individual core domains remain in the core CI partition'
    $historyCase = Get-TestImpact @('tests/ui_check/modules/UiContentPagesChecks.cpp')
    Check (-not $historyCase.full -and 'ui-bootstrap' -in $historyCase.tests -and 'ci-ui' -in $historyCase.suites) 'historical UI assertions are still compiled when their module changes'
    $upgradeTest = Get-TestImpact @('tests/mw_check/InstanceUpgradeChecks.cpp')
    Check ($upgradeTest.modules.Count -eq 1 -and $upgradeTest.modules[0] -eq 'upgrade') 'editing an upgrade assertion file does not select unrelated production modules'
    $themeTest = Get-TestImpact @('tests/ui_check/modules/UiThemeCheck.cpp')
    Check ($themeTest.modules.Count -eq 1 -and $themeTest.modules[0] -eq 'theme') 'editing a theme assertion file selects only the theme executable'
    foreach ($path in 'ui/Popups.cpp', 'tests/ui_check/modules/UiPopupCheck.cpp') {
        $popupImpact = Get-TestImpact @($path)
        Check (-not $popupImpact.full -and 'ci-ui' -in $popupImpact.suites -and
               'popups' -in $popupImpact.tests -and 'popups-scale' -in $popupImpact.tests) "editing $path selects popup checks at both scales"
    }
    $windowTest = Get-TestImpact @('tests/mw_check/modules/MwMemoryPreferencesChecks.cpp')
    Check ($windowTest.modules.Count -eq 1 -and $windowTest.modules[0] -eq 'window') 'historical main-window assertion changes retain their integration owner'
    foreach ($controller in @('ResourceSearchController', 'InstanceUpdateCheckController')) {
        $workflow = Get-TestImpact @("src/controllers/$controller.cpp")
        Check (-not $workflow.full -and 'main-window' -in $workflow.tests -and 'mod-action-panel' -in $workflow.tests) 'extracted resource workflows retain main-window and mod integration coverage'
    }
    $promptCase = Get-TestImpact @('tests/mw_check/modules/PromptProbe.cpp')
    Check ($promptCase.modules.Count -eq 1 -and $promptCase.modules[0] -eq 'window') 'prompt fixture implementation has a focused integration owner'
    $exportCase = Get-TestImpact @('tests/core_modules/ModpackExportPipelineTests.cpp')
    Check ($exportCase.modules.Count -eq 1 -and $exportCase.modules[0] -eq 'core-resources') 'split export assertions keep their existing core resource owner'
    $upgrade = Get-TestImpact @('src/controllers/UpgradeAssessment.cpp')
    Check ('upgrade' -in $upgrade.modules -and 'window' -notin $upgrade.modules -and -not $upgrade.full) 'upgrade changes select their module without the monolithic window suite'
    Check ('ci-app' -in $upgrade.suites -and 'upgrade' -in $upgrade.modules -and 'core' -notin $upgrade.modules) 'upgrade controller changes build the application without unrelated core monolith'
    Check ('core' -in (Get-TestImpact @('src/operations/ModVersionDeclaration.hpp')).modules) 'shared version declaration changes retain core coverage'
    $shared = Get-TestImpact @('src/MainWindow.hpp')
    Check ($shared.full -and $shared.suites.Count -eq 4) 'shared headers expand to all CI partitions'
    Check ((Get-TestImpact @('src/new-unmapped-feature.cpp')).full) 'unclassified paths fail closed to full verification'
    Check ((Get-TestImpact @('assets/icons.qrc')).full) 'resource assets are not mistaken for documentation'
    $tooling = Get-TestImpact @('tools/test.ps1')
    Check ($tooling.suites.Count -eq 1 -and $tooling.suites[0] -eq 'ci-core' -and 'core' -notin $tooling.modules) 'runner-only changes do not build C++ test executables'
    & (Join-Path $PSScriptRoot 'test.ps1') -Suite affected -ChangedPath 'src/controllers/ModActionPanelChecks.cpp' `
        -BuildDir $fixture -NoBuild -ListOnly -ReportRoot (Join-Path $work 'impact-reports') *> (Join-Path $work 'impact.output.log')
    Check ($LASTEXITCODE -eq 0) 'affected command accepts explicit paths without losing them during import'
    $impactReport = Get-ChildItem (Join-Path $work 'impact-reports') -Filter impact.json -Recurse | Select-Object -First 1
    $record = Get-Content -LiteralPath $impactReport.FullName -Raw | ConvertFrom-Json
    Check ('mods' -in $record.modules -and -not $record.full) 'affected command records the expected module selection'
    # Explicit -Modules must win over impact analysis, even when impact is full.
    & (Join-Path $PSScriptRoot 'test.ps1') -Suite affected -ChangedPath 'src/MainWindow.hpp' `
        -Modules mods -BuildDir $fixture -NoBuild -ListOnly -ReportRoot (Join-Path $work 'explicit-modules-reports') *> (Join-Path $work 'explicit-modules.output.log')
    Check ($LASTEXITCODE -eq 0) 'affected command accepts explicit -Modules'
    $explicitLog = Get-Content -LiteralPath (Join-Path $work 'explicit-modules.output.log') -Raw
    Check ($explicitLog -match 'Affected modules: mods') 'explicit -Modules is not overwritten by full impact analysis'
    $explicitReport = Get-ChildItem (Join-Path $work 'explicit-modules-reports') -Filter summary.json -Recurse | Select-Object -First 1
    $explicitSummary = Get-Content -LiteralPath $explicitReport.FullName -Raw | ConvertFrom-Json
    $testStageArgs = @(($explicitSummary.stages | Where-Object name -eq 'test').arguments | ForEach-Object { [string]$_ })
    Check ($testStageArgs -contains '-R' -and ($testStageArgs -join ' ') -match 'mod-action-panel') 'explicit -Modules filters the selected tests'
    . (Join-Path $PSScriptRoot 'ci-object-batches.ps1')
    $objectFixture = @(
        'CMakeFiles/WTFMinecraftLauncher.dir/src/one.cpp.obj: CXX_COMPILER__WTFMinecraftLauncher_unscanned_Release',
        'CMakeFiles/WTFMinecraftLauncher.dir/src/one.cpp.obj: CXX_COMPILER__WTFMinecraftLauncher_unscanned_Release',
        'CMakeFiles/WTFMinecraftLauncher.dir/src/space name.cpp.obj: CXX_COMPILER__WTFMinecraftLauncher_unscanned_Release',
        'tests/CMakeFiles/verify.dir/one.cpp.obj: CXX_COMPILER__verify_unscanned_Release',
        'WTFMinecraftLauncher.exe: CXX_EXECUTABLE_LINKER__WTFMinecraftLauncher_Release'
    )
    $planned = @(Get-CiLauncherObjects $objectFixture)
    Check ($planned.Count -eq 2 -and $planned[1] -like '*space name.cpp.obj') 'launcher object plan excludes other targets and deduplicates outputs'
    $emptyRejected = $false
    try { $null = Get-CiLauncherObjects @('unrelated: phony') } catch { $emptyRejected = $true }
    Check $emptyRejected 'empty launcher object plan fails closed'
    foreach ($suite in @('core', 'mods', 'java', 'window')) {
        # These failures are intentional fixture outcomes, isolated from normal CI reports.
        $timeout = if ($suite -eq 'java') { 2 } else { 15 }
        $output = Join-Path $work "$suite.output.log"
        & (Join-Path $PSScriptRoot 'test.ps1') -Suite $suite -BuildDir $fixture -NoBuild -ReportRoot $reports -TestTimeoutSeconds $timeout *> $output
        $code = $LASTEXITCODE
        $expected = if ($suite -eq 'core') { 0 } else { 1 }
        Check ($code -eq $expected) "runner exit status for $suite"
        if ($code -ne $expected) { Get-Content -LiteralPath $output -Tail 25 | Write-Host }
        Check ($env:TEMP -eq $oldTemp -and $env:TMP -eq $oldTmp) "temporary environment restored after $suite"
    }
    $files = @(Get-ChildItem -LiteralPath $reports -Filter summary.json -Recurse)
    Check ($files.Count -eq 4) 'each invocation preserves a separate report'
    foreach ($file in $files) {
        $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        Check ($record.stages.Count -eq 1) "one test stage recorded for $($record.suite)"
        $stage = $record.stages[0]
        switch ($record.suite) {
            'core' {
                Check ($record.exitCode -eq 0 -and $stage.exitCode -eq 0) 'passing tests succeed with a spaced/Unicode build path'
                $junit = Join-Path $file.DirectoryName 'results.xml'
                Check (Test-Path -LiteralPath $junit) 'successful test writes JUnit report'
            }
            'mods' { Check ($record.exitCode -ne 0 -and $stage.exitCode -ne 0 -and -not $stage.timedOut) 'real assertion failure is not swallowed' }
            'java' { Check ($stage.timedOut -and $stage.exitCode -eq 124 -and $record.exitCode -ne 0) 'timeout kills the process tree and records 124' }
            'window' { Check ($record.exitCode -ne 0 -and $stage.exitCode -ne 0 -and -not $stage.timedOut) 'empty test selection is not a false green' }
            default { Check $false 'unexpected fixture suite' }
        }
    }
    $partitionFixture = Join-Path $work 'partitions space 测试'
    $null = New-Item -ItemType Directory -Path $partitionFixture -Force
    Copy-Item -LiteralPath (Join-Path $repo 'tests/test_runner/PartitionFixture.cmake') `
        -Destination (Join-Path $partitionFixture 'CTestTestfile.cmake')
    foreach ($case in @('valid', 'missing', 'duplicate', 'empty')) {
        $env:WTFML_PARTITION_FIXTURE_CASE = $case
        & (Join-Path $PSScriptRoot 'check-ci-partitions.ps1') -BuildDir $partitionFixture `
            *> (Join-Path $work "partition-$case.output.log")
        Check ($LASTEXITCODE -eq $(if ($case -eq 'valid') { 0 } else { 1 })) `
            "CI partition check handles $case (visual tests excluded)"
    }
} catch {
    Write-Host "FAIL runner self-check: $_"
    $failed++
} finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
    $env:WTFML_PARTITION_FIXTURE_CASE = $oldPartitionCase
    Write-Host "Self-check evidence: $work"
}
exit $(if ($failed) { 1 } else { 0 })
