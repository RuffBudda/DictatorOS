# DictatorOS: run once in each Windows install, in PowerShell *as Administrator*:
#   irm https://raw.githubusercontent.com/RuffBudda/DictatorOS/main/windows/install-limine-first.ps1 | iex
# Copies limine-first.ps1 to C:\DictatorOS and registers a startup task (runs as
# SYSTEM at every boot) that keeps Limine first in the firmware boot order.
# Undo: schtasks /delete /tn "DictatorOS Limine first" /f ; Remove-Item C:\DictatorOS -Recurse
$dir = "C:\DictatorOS"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Invoke-RestMethod "https://raw.githubusercontent.com/RuffBudda/DictatorOS/main/windows/limine-first.ps1" -OutFile "$dir\limine-first.ps1"
schtasks /create /tn "DictatorOS Limine first" /sc onstart /ru SYSTEM /rl HIGHEST /f `
  /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dir\limine-first.ps1" | Out-Null
& "$dir\limine-first.ps1"
Write-Host "Done: Limine is first in the boot order, and stays first after every Windows start."
