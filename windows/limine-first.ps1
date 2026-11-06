# DictatorOS: keep Limine first in the firmware boot order.
# Windows moves "Windows Boot Manager" to the top of the boot order every time it
# starts, so the next restart skips Limine. Run at every Windows startup (as SYSTEM,
# see install-limine-first.ps1) to put Limine back on top. Safe to run any time.
$firmware = (bcdedit /enum firmware | Out-String) -split "(\r?\n){2,}"
$limine = $firmware | Where-Object { $_ -match '(?m)^description\s+Limine\s*$' } | Select-Object -First 1
if ($limine -and $limine -match '(?m)^identifier\s+(\{[0-9a-fA-F-]+\})') {
    bcdedit /set "{fwbootmgr}" displayorder $Matches[1] /addfirst | Out-Null
}
