#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('powershell.exe', 'pwsh.exe')]
    [string]$AnswerPowerShell = 'powershell.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$answerScript = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\RunTool_CeUnityAnswerDialog.ps1'))
$powershellCommand = (Get-Command $AnswerPowerShell -ErrorAction Stop).Source

function Start-TestModal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ButtonText,

        [Parameter(Mandatory = $true)]
        [string]$WindowTitle
    )

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $runspace.Open()

    $worker = [powershell]::Create()
    $worker.Runspace = $runspace
    $null = $worker.AddScript({
        param($dialogButtonText, $dialogWindowTitle)

        Add-Type -AssemblyName System.Windows.Forms
        $form = New-Object System.Windows.Forms.Form
        $form.Text = $dialogWindowTitle
        $form.Width = 360
        $form.Height = 150
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.ShowInTaskbar = $true
        $form.TopMost = $true

        $button = New-Object System.Windows.Forms.Button
        $button.Text = $dialogButtonText
        $button.Width = 120
        $button.Height = 32
        $button.Left = 115
        $button.Top = 45
        $button.Add_Click({ $form.Close() })
        $null = $form.Controls.Add($button)

        $null = $form.ShowDialog()
        $form.Dispose()
    })
    $null = $worker.AddArgument($ButtonText)
    $null = $worker.AddArgument($WindowTitle)
    $asyncResult = $worker.BeginInvoke()
    Start-Sleep -Milliseconds 1000

    return [pscustomobject]@{
        Runspace = $runspace
        Worker = $worker
        AsyncResult = $asyncResult
    }
}

function Stop-TestModal {
    param(
        [AllowNull()]
        [psobject]$State
    )

    if ($null -eq $State) {
        return
    }

    try {
        if (-not $State.AsyncResult.IsCompleted) {
            $State.Worker.Stop()
        }
    }
    catch {
    }
    try {
        $State.Worker.Dispose()
    }
    catch {
    }
    try {
        $State.Runspace.Close()
        $State.Runspace.Dispose()
    }
    catch {
    }
}

function Invoke-AnswerSmoke {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('save', 'discard')]
        [string]$Action,

        [switch]$ConfirmDiscard
    )

    $buttonText = if ($Action -eq 'save') { 'Save' } else { "Don't Save" }
    $state = $null
    try {
        $state = Start-TestModal -ButtonText $buttonText -WindowTitle "CeUnity answer $Action"
        $arguments = @(
            '-NoProfile',
            '-NonInteractive',
            '-STA',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $answerScript,
            '-TargetPid',
            [string]$PID,
            '-Action',
            $Action,
            '-TimeoutSec',
            '5'
        )
        if ($ConfirmDiscard) {
            $arguments += '-ConfirmDiscard'
        }

        $raw = (& $powershellCommand @arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "answer dialog returned exit code $($exitCode): $raw"
        }

        $result = $raw | ConvertFrom-Json
        if ($result.status -ne 'clicked' -or $result.action -ne $Action) {
            throw "unexpected answer dialog result: $raw"
        }
        $null = $state.Worker.EndInvoke($state.AsyncResult)

        Write-Output "answer-modal smoke passed: $Action ($($result.button))"
    }
    finally {
        Stop-TestModal -State $state
    }
}

Invoke-AnswerSmoke -Action save
Invoke-AnswerSmoke -Action discard -ConfirmDiscard
Write-Output 'answer-modal smoke: 2/2 passed'
