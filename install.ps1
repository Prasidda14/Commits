# Installs the commit waitlist:
#   1. a global git pre-push hook that holds pushes to github.com
#   2. a scheduled task that runs "waitlist.sh run" every 3 hours and at logon
# Undo with:  .\install.ps1 -Uninstall
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$taskName = 'GitHubCommitWaitlist'
$hooks = (Join-Path $root 'hooks') -replace '\\', '/'

if ($Uninstall) {
    if ((git config --global core.hooksPath) -eq $hooks) { git config --global --unset core.hooksPath }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host 'Waitlist removed: pushes go straight to GitHub again and the scheduled task is gone.'
    return
}

$existing = git config --global core.hooksPath
if ($existing -and $existing -ne $hooks) {
    throw "core.hooksPath is already set globally to '$existing'. Remove it first or merge the hooks by hand."
}
git config --global core.hooksPath $hooks

$bash = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'bin\bash.exe'
if (-not (Test-Path $bash)) { throw "Git Bash not found at $bash" }

$action = New-ScheduledTaskAction -Execute $bash -Argument ('"{0}" run' -f (Join-Path $root 'waitlist.sh')) -WorkingDirectory $root
$triggers = @(
    (New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 3)),
    (New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME")
)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Force | Out-Null

Write-Host "Installed. Hook path: $hooks"
Write-Host "Scheduled task '$taskName' runs every 3 hours and at logon."
