#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2147483647)]
    [int]$TargetPid,

    [Parameter(Mandatory = $true)]
    [ValidateSet('save', 'discard')]
    [string]$Action,

    [switch]$ConfirmDiscard,

    [ValidateRange(1, 60)]
    [int]$TimeoutSec = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$nativeInteropType = $null
try {
    $nativeSource = [string]::Join([Environment]::NewLine, [string[]]@(
        'using System;',
        'using System.Runtime.InteropServices;',
        'using System.Text;',
        'public static class CeUnityAnswerDialogNative {',
        '  [DllImport("user32.dll", CharSet=CharSet.Unicode)]',
        '  public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);',
        '  [DllImport("user32.dll", CharSet=CharSet.Unicode)]',
        '  public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int maxCount);',
        '}'
    ))
    $previousLib = $env:LIB
    try {
        # Some developer shells export a stale LIB path and make Add-Type fail.
        $env:LIB = ''
        Add-Type -TypeDefinition $nativeSource -ErrorAction Stop
        $nativeInteropType = 'CeUnityAnswerDialogNative' -as [type]
    }
    finally {
        if ($null -eq $previousLib) {
            Remove-Item Env:LIB -ErrorAction SilentlyContinue
        }
        else {
            $env:LIB = $previousLib
        }
    }
}
catch {
    # UIAutomation.InvokePattern remains usable when the native helper cannot compile.
    $nativeInteropType = $null
}

function Write-JsonResult {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Result
    )

    $Result | ConvertTo-Json -Depth 8 -Compress | Write-Output
}

function Write-PolicyError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $result = @{
        'status' = 'error'
        'error' = @{ 'message' = $Message }
    }
    Write-JsonResult $result
    exit 4
}

function Test-AutomationContext {
    $truthy = '^(1|true|yes|on)$'
    $signals = @(
        $env:CI,
        $env:GITHUB_ACTIONS,
        $env:TF_BUILD,
        $env:CE_OPERATOR_AUTO_LOOP
    )

    foreach ($value in $signals) {
        if ($null -ne $value -and $value -match $truthy) {
            return $true
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:JENKINS_URL)) {
        return $true
    }
    return $false
}

function Assert-ActionPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Intent,

        [Parameter(Mandatory = $true)]
        [bool]$Confirmed
    )

    if ($Intent -ne 'discard') {
        return
    }
    if (-not $Confirmed) {
        Write-PolicyError 'discard requires -ConfirmDiscard'
    }
    $automationContext = Test-AutomationContext
    if ($automationContext) {
        Write-PolicyError 'discard is disabled in CI or automatic-loop contexts'
    }
}

function Normalize-UiText {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return ''
    }

    $normalized = $Text.Replace([char]0x00A0, ' ')
    $normalized = $normalized.Replace('&', '')
    $normalized = $normalized.Trim()
    $normalized = [regex]::Replace($normalized, "\u2026$", "")
    $normalized = [regex]::Replace($normalized, "\.{2,}$", "")
    return $normalized.Trim().ToLowerInvariant()
}

function Test-ActionButtonText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [ValidateSet('save', 'discard')]
        [string]$Intent
    )

    $normalized = Normalize-UiText $Text
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }

    if ($Intent -eq 'save') {
        return $normalized -match '^(save|save scene|save changes|\u4FDD\u5B58|\u4FDD\u5B58\u3059\u308B|\u4FDD\u5B58\u3057\u3066\u7D9A\u884C)$'
    }

    return $normalized -match '^(don''t save|do not save|discard|discard changes|\u4FDD\u5B58\u3057\u306A\u3044|\u7834\u68C4|\u5909\u66F4\u3092\u7834\u68C4)$'
}

function Get-NativeWindowClassName {
    param(
        [Parameter(Mandatory = $true)]
        [int]$WindowHandle
    )

    if ($null -eq $nativeInteropType -or $WindowHandle -eq 0) {
        return ''
    }

    $className = New-Object System.Text.StringBuilder 256
    [void]$nativeInteropType::GetClassName(
        [IntPtr]$WindowHandle,
        $className,
        $className.Capacity)
    return $className.ToString()
}

function Test-NativeButtonHandle {
    param(
        [Parameter(Mandatory = $true)]
        [int]$WindowHandle
    )

    $className = Get-NativeWindowClassName $WindowHandle
    return $className -match '^(Button|WindowsForms10\.BUTTON\.)'
}

function Find-UiAutomationButton {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId,

        [Parameter(Mandatory = $true)]
        [string]$Intent
    )

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    $automationElement = [System.Windows.Automation.AutomationElement]
    $propertyCondition = [System.Windows.Automation.PropertyCondition]
    $treeScope = [System.Windows.Automation.TreeScope]
    $controlType = [System.Windows.Automation.ControlType]
    $root = $automationElement::RootElement
    $pidCondition = $propertyCondition::new($automationElement::ProcessIdProperty, $ProcessId)
    $allCondition = [System.Windows.Automation.Condition]::TrueCondition

    # Query by process first. Combining ProcessId and ControlType in one UIA
    # condition can make WinForms controls appear as panes on some providers.
    foreach ($window in $root.FindAll($treeScope::Children, $pidCondition)) {
        $windowInfo = $window.Current
        if ($windowInfo.ControlType -ne $controlType::Window -or
            $windowInfo.IsOffscreen -or -not $windowInfo.IsEnabled -or
            [string]::IsNullOrWhiteSpace($windowInfo.Name)) {
            continue
        }

        foreach ($element in $window.FindAll($treeScope::Descendants, $allCondition)) {
            $elementInfo = $element.Current
            if (-not $elementInfo.IsOffscreen -and $elementInfo.IsEnabled -and
                (Test-ActionButtonText $elementInfo.Name $Intent)) {
                $invokePattern = $null
                $hasInvokePattern = $false
                try {
                    $hasInvokePattern = $element.TryGetCurrentPattern(
                        [System.Windows.Automation.InvokePattern]::Pattern,
                        [ref]$invokePattern)
                }
                catch {
                }
                $hasNativeButton = Test-NativeButtonHandle $elementInfo.NativeWindowHandle
                if (-not $hasInvokePattern -and -not $hasNativeButton) {
                    continue
                }
                return [pscustomobject]@{
                    Element = $element
                    Text = $elementInfo.Name
                    WindowTitle = $windowInfo.Name
                    NativeWindowHandle = $elementInfo.NativeWindowHandle
                }
            }
        }
    }
    return $null
}

function Invoke-UiAutomationButton {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Candidate
    )

    try {
        $invokePattern = $Candidate.Element.GetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern)
        [void]$invokePattern.Invoke()
        return 'UIAutomation.InvokePattern'
    }
    catch {
        if (-not (Test-NativeButtonHandle $Candidate.NativeWindowHandle)) {
            throw
        }
        [void]$nativeInteropType::SendMessage(
            [IntPtr]$Candidate.NativeWindowHandle,
            0x00F5,
            [IntPtr]::Zero,
            [IntPtr]::Zero)
        return 'Win32.BM_CLICK'
    }
}

try {
    Assert-ActionPolicy -Intent $Action -Confirmed ([bool]$ConfirmDiscard)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $lastError = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $candidate = Find-UiAutomationButton -ProcessId $TargetPid -Intent $Action
            if ($null -ne $candidate) {
                $method = Invoke-UiAutomationButton $candidate
                Write-JsonResult @{
                    status = 'clicked'
                    action = $Action
                    button = $candidate.Text
                    window = $candidate.WindowTitle
                    method = $method
                }
                exit 0
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 100
    }

    $details = @{
        target_pid = $TargetPid
        action = $Action
        timeout_sec = $TimeoutSec
    }
    if ($null -ne $lastError) {
        $details.last_error = $lastError
    }
    Write-JsonResult @{
        status = 'not_found'
        error = @{
            message = 'the requested action button was not found on a modal owned by the target process'
            details = $details
        }
    }
    exit 1
}
catch {
    Write-JsonResult @{
        status = 'error'
        error = @{
            message = $_.Exception.Message
            target_pid = $TargetPid
            action = $Action
        }
    }
    exit 1
}
