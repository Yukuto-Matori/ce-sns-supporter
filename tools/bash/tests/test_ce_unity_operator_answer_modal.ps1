#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Fixture,

    [string]$HeartbeatFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Fixture) {
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $runspace.Open()
    $worker = [powershell]::Create()
    $worker.Runspace = $runspace
    $null = $worker.AddScript({
        param($dialogHeartbeatFile, $dialogPid)

        Add-Type -AssemblyName System.Windows.Forms
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'CeUnity operator answer smoke'
        $form.Width = 360
        $form.Height = 150
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.ShowInTaskbar = $true
        $form.TopMost = $true

        $button = New-Object System.Windows.Forms.Button
        $button.Text = 'Save'
        $button.Width = 120
        $button.Height = 32
        $button.Left = 115
        $button.Top = 45
        $button.Add_Click({
            $freshHeartbeat = @{
                updated_at = [DateTime]::UtcNow.ToString('o')
                pid = $dialogPid
                is_main_thread_blocking = $false
            } | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText($dialogHeartbeatFile, $freshHeartbeat)
            $form.Close()
        })
        $null = $form.Controls.Add($button)

        $null = $form.ShowDialog()
        $form.Dispose()
    })
    $null = $worker.AddArgument($HeartbeatFile)
    $null = $worker.AddArgument([int]$PID)
    $null = $worker.BeginInvoke()
    Start-Sleep -Seconds 60
    exit 0
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$wrapper = Join-Path $repoRoot 'tools\bash\RunTool_CeUnityOperator.sh'
$testRoot = Join-Path $repoRoot ('tmp\ce-operator-answer-smoke-' + [Guid]::NewGuid().ToString('N'))
$testRootBash = $testRoot.Replace('\', '/')
$heartbeatFile = Join-Path $testRoot 'status\heartbeat.json'
$commandDirectory = Join-Path $testRoot 'command'
$resultDirectory = Join-Path $testRoot 'result'
$stdoutFile = Join-Path $testRoot 'wrapper.stdout.txt'
$stderrFile = Join-Path $testRoot 'wrapper.stderr.txt'
$fixtureProcess = $null
$runner = $null

try {
    New-Item -ItemType Directory -Path (Join-Path $testRoot 'status') -Force | Out-Null
    New-Item -ItemType Directory -Path $commandDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null

    $fixtureProcess = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @(
            '-NoProfile',
            '-STA',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $PSCommandPath,
            '-Fixture',
            '-HeartbeatFile',
            $heartbeatFile
        ) `
        -PassThru
    Start-Sleep -Milliseconds 1200

    $staleHeartbeat = @{
        updated_at = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        pid = $fixtureProcess.Id
        is_main_thread_blocking = $false
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($heartbeatFile, $staleHeartbeat)

    $bash = (Get-Command bash.exe -ErrorAction Stop).Source
    $runner = Start-Process -FilePath $bash `
        -ArgumentList @($wrapper, 'ping', '--root', $testRootBash, '--answer-modal', 'save') `
        -WorkingDirectory $repoRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile `
        -PassThru

    $resultCreated = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        $runner.Refresh()
        if ($runner.HasExited) {
            break
        }

        $commandFiles = @(Get-ChildItem -LiteralPath $commandDirectory -Filter '*.command.json' -File -ErrorAction SilentlyContinue)
        foreach ($commandFile in $commandFiles) {
            $id = $commandFile.Name.Substring(0, $commandFile.Name.Length - '.command.json'.Length)
            $resultFile = Join-Path $resultDirectory ($id + '.result.json')
            if (-not (Test-Path -LiteralPath $resultFile)) {
                $result = @{ id = $id; command = 'ping'; status = 'success' } | ConvertTo-Json -Compress
                [System.IO.File]::WriteAllText($resultFile, $result)
                $resultCreated = $true
            }
        }
        Start-Sleep -Milliseconds 100
    }

    $runner.Refresh()
    if (-not $runner.HasExited) {
        $runner.Kill()
        throw 'operator wrapper did not finish within 30 seconds'
    }
    $runner.WaitForExit()
    $runnerExitCode = $runner.ExitCode
    $stdout = if (Test-Path -LiteralPath $stdoutFile) {
        [System.IO.File]::ReadAllText($stdoutFile).Trim()
    }
    else {
        ''
    }
    $stderr = if (Test-Path -LiteralPath $stderrFile) {
        [System.IO.File]::ReadAllText($stderrFile).Trim()
    }
    else {
        ''
    }
    if ($null -ne $runnerExitCode -and $runnerExitCode -ne 0) {
        throw "operator wrapper returned exit code $($runnerExitCode): stdout=[$stdout] stderr=[$stderr]"
    }
    if (-not $resultCreated) {
        throw "operator wrapper completed without observing a command file: stdout=[$stdout] stderr=[$stderr]"
    }

    $wrapperResult = $stdout | ConvertFrom-Json
    if ($wrapperResult.status -ne 'success') {
        throw "unexpected operator wrapper result: $stdout"
    }
    Write-Output 'operator answer-modal smoke passed: save resumed and ping completed'
}
finally {
    if ($null -ne $runner) {
        try {
            $runner.Refresh()
            if (-not $runner.HasExited) {
                $runner.Kill()
            }
        }
        catch {
        }
        try { $runner.Dispose() } catch {}
    }
    if ($null -ne $fixtureProcess) {
        try {
            $fixtureProcess.Refresh()
            if (-not $fixtureProcess.HasExited) {
                Stop-Process -Id $fixtureProcess.Id -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
        }
        try { $fixtureProcess.Dispose() } catch {}
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
