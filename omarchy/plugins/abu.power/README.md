# Omarchy Power + CPU Boost

An Omarchy Quickshell power widget with a **Disable turbo boost / Enable turbo boost** button. It extends the built-in power popup with live CPU boost status and automatic detection of Intel and AMD-compatible kernel controls.

The plugin ID is `rasp.power`. It replaces `omarchy.power` in the bar while keeping Omarchy's power IPC target and existing battery controls.

## What it does

- Shows the existing battery icon, optional percentage, charge information, system statistics, and power profile buttons.
- Adds a full-width turbo boost button below the profile buttons.
- Shows whether CPU boost is currently enabled or disabled.
- Reads the actual kernel state when the popup opens and every five seconds while it stays open.
- Automatically uses Intel's `intel_pstate/no_turbo` control when available, otherwise the generic CPUFreq `boost` control used by AMD and some other drivers.
- Requests administrator authorization through Polkit when changing boost.
- Shows a busy label during the change and an error message if authorization is cancelled or the write fails.
- Hides the boost controls when neither supported kernel interface is readable.

Disabling boost may reduce heat, fan noise, and power use, with lower peak CPU performance. The effect depends on the CPU and workload. Enabling boost permits the CPU to boost; it does not force a particular frequency.

## Requirements

- Omarchy with the **Quickshell shell and plugin system**, including `omarchy plugin enable`, `omarchy-shell`, and the built-in `omarchy.power` widget. This is not a Waybar module.
- A battery exposed through UPower. The inherited widget hides itself on machines without a battery, including desktops; this version retains that behavior.
- `bash`, `jq`, `install`, Polkit's `pkexec`, and a running graphical authentication agent. Omarchy normally provides these.
- A readable `/sys/devices/system/cpu/intel_pstate/no_turbo` or `/sys/devices/system/cpu/cpufreq/boost` interface for the new controls.
- Node.js only if you want to run the development tests.

The installed CPU scaling driver and firmware determine which control exists. CPU brand alone does not guarantee a particular sysfs path.

## Install

Run these commands as your normal desktop user, from an unlocked Omarchy session:

```bash
git clone https://github.com/nuo-yi/omarchy-power-widget.git
cd omarchy-power-widget
./install.sh
```

The installer checks the shell connection, manifest, and QML syntax when Qt's `qmlformat` is available. It backs up `shell.json` and any existing `rasp.power` directory under `~/.config/omarchy/power-widget-backup.XXXXXX`, prints the backup path, and copies the four widget files into `~/.config/omarchy/plugins/rasp.power/`.

It then rescans the plugins, enables `rasp.power`, and restarts the shell to clear any cached QML components. Omarchy uses `omarchy.clonedFrom` to replace the stock power entry while preserving its position and inline settings, such as `showPercentage`.

`XDG_CONFIG_HOME` is respected if set. The installer requires the shell to be running; if it is not, it stops before changing files. If an installation fails later, its printed backup remains available for recovery.

To update, run `git pull --ff-only` in this repository and then `./install.sh` again.

## Use

Click the power icon in the bar. Under **POWER PROFILE**, select **Disable turbo boost** or **Enable turbo boost** and complete the authentication prompt. The status is refreshed after the command finishes. The button is temporarily disabled while authorization or the write is in progress.

Changing boost applies to the current running system. This widget does not install a boot service, a privileged helper, a Polkit rule, or a saved boost preference. The setting can reset after reboot or be changed by another power management tool. Boost is independent of the profile buttons; selecting a profile does not explicitly set boost through this widget.

## AMD and Intel commands

These commands are also useful without the widget. Use the interface that exists on your machine. Reads need no administrator privileges; writes use `sudo tee` so the privileged process performs the write.

### AMD / generic CPUFreq boost

This is commonly exposed by AMD-compatible scaling drivers. Some Intel configurations also use this interface.

```bash
# Read: 1 = boost enabled, 0 = boost disabled
cat /sys/devices/system/cpu/cpufreq/boost

# Disable boost
printf '0\n' | sudo tee /sys/devices/system/cpu/cpufreq/boost

# Enable boost
printf '1\n' | sudo tee /sys/devices/system/cpu/cpufreq/boost
```

### Intel with intel_pstate

The Intel interface is named `no_turbo`, so its values have the opposite meaning:

```bash
# Read: 1 = turbo disabled, 0 = turbo enabled
cat /sys/devices/system/cpu/intel_pstate/no_turbo

# Disable turbo boost
printf '1\n' | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo

# Enable turbo boost
printf '0\n' | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
```

| Interface | Disable boost | Enable boost |
| --- | --- | --- |
| `/sys/devices/system/cpu/cpufreq/boost` | `0` | `1` |
| `/sys/devices/system/cpu/intel_pstate/no_turbo` | `1` | `0` |

The widget checks Intel's interface first, then CPUFreq. It uses `pkexec /usr/bin/bash -c` to write a fixed `0` or `1` to the selected fixed path. It does not pass user-entered text to the privileged command.

See the Linux kernel's [CPU frequency boost documentation](https://docs.kernel.org/admin-guide/pm/cpufreq.html#frequency-boost-support) and [intel_pstate documentation](https://docs.kernel.org/admin-guide/pm/intel_pstate.html) for driver behavior and firmware restrictions.

## Every change from the built-in widget

### `Panel.qml`

1. Imports the new `Boost.js` module.
2. Adds properties for boost availability, normalized enabled state, detected backend, and the latest action error.
3. Adds a boost read to the existing refresh function. It shares the existing popup-open refresh and five-second timer, avoiding a separate background poll when the popup is closed.
4. Adds `toggleBoost()`, which clears a previous error, rejects duplicate requests, and starts the privileged command for the selected backend.
5. Adds `boostProc`, which detects the kernel interface and parses its state without requiring authorization.
6. Adds `boostActionProc`, which performs the authorized write, reports nonzero exit codes, and refreshes the real kernel state after success or failure. The UI does not assume the write succeeded.
7. Adds the action button under the profile row. Its text describes the available action, its active styling marks boost as disabled, and it displays a busy label while a command runs.
8. Adds a `CPU boost` status row and a wrapped error message. Boost rows are hidden if no valid supported control is found.

The existing `moduleName`, IPC target, `manageIpc: false`, and `togglePercentage()` behavior remain compatible with Omarchy's cloned-plugin routing. Battery handling, profile selection, keyboard profile navigation, and system statistics are inherited from the upstream widget.

### `Boost.js`

This new module keeps interface detection, value interpretation, and privileged command construction together. It normalizes Intel's inverted values and CPUFreq's regular values to one boolean. Unknown interfaces and malformed status output are rejected. Only the two known paths can be used for writes.

### `manifest.json`

- Changes the plugin ID from `omarchy.power` to `rasp.power` so the extension lives in the user plugin directory.
- Adds `omarchy.clonedFrom: "omarchy.power"` so Omarchy can replace the original bar entry and resolve its stable IPC target.
- Uses the name **Power + CPU Boost**, version **1.1.0**, and a description covering boost support.
- Credits Omarchy for the original widget and nuo-yi for the extension.
- Retains the bar-widget entry point, System category, and single-instance restriction.

### Other files

| File | Purpose |
| --- | --- |
| `Model.js` | Unmodified upstream battery/profile helpers. |
| `install.sh` | Dependency and syntax checks, backups, file installation, enablement, and shell restart. |
| `tests/boost.test.cjs` | Tests both interfaces' opposite value meanings, generated command paths, malformed status, and unknown-backend rejection. It never writes to sysfs. |
| `upstream/Panel.qml` | Original installed Omarchy panel, retained as a comparison baseline. It is not installed. |
| `upstream/CHANGES.patch` | Exact diff from that baseline to this panel. |
| `upstream/PROVENANCE.md` | Source paths, checksums, and attribution for inherited code. |
| `LICENSE` | Original Omarchy MIT license, preserved for the derived files. The extension is distributed under the same terms. |
| `.gitignore` | Excludes temporary files and Node dependency directories. |

No files under `/usr/share/omarchy/` are modified. The plugin survives Omarchy package updates, but as a copy it does not automatically inherit future changes to the stock power widget.

## Validation and development

```bash
node tests/boost.test.cjs
bash -n install.sh
/usr/lib/qt6/bin/qmlformat Panel.qml >/dev/null
diff -u upstream/Panel.qml Panel.qml
```

The `diff` command exits with status 1 when it finds the expected differences. `qmlformat` checks parsing; it does not prove that shell imports, hardware, or authentication work. The original widget and the initial CPUFreq version were loaded in the user's live Omarchy session. The published revision is also checked in that session during preparation. Intel polarity is covered by automated tests; no Intel hardware write has been tested here. Successful hardware writes on other machines depend on their driver, firmware, and authorization setup.

To inspect shell errors:

```bash
quickshell log --any-display -p /usr/share/omarchy/shell -t 80
```

## Troubleshooting

**Power icon disappeared:** check the shell log for `Plugin widget rasp.power failed`. A QML syntax error in an earlier local version caused the icon to disappear; that error was a missing closing brace and is fixed in this version. Reinstall and restart the shell to clear cached components. If needed, restore the stock widget using the commands below.

**No boost button:** check whether either sysfs file exists and contains `0` or `1`. Unsupported drivers, firmware settings, or unreadable controls prevent the widget from showing the feature.

**Authorization fails or no prompt appears:** confirm that `pkexec` and a graphical Polkit authentication agent are available. Cancelled authorization leaves the current state unchanged and shows an error. Firmware can also reject an attempted change.

**The value changes back:** another power management tool may be writing it. The widget reads the actual state again rather than saving its own preference.

**No icon on a desktop without a battery:** the inherited panel hides itself when UPower reports no battery. Supporting desktops requires a separate change to that behavior.

## Restore the stock widget

```bash
omarchy plugin disable rasp.power
omarchy plugin enable omarchy.power
omarchy restart shell
```

Omarchy restores the clone's source when the clone is disabled. The explicit enable command also covers a missing stock entry. The copied files can remain installed while disabled. To recover the exact previous configuration, use the installer backup path it printed; restoring an older `shell.json` also restores all other bar settings from that backup.

## Credits

Based on [Omarchy](https://github.com/basecamp/omarchy)'s built-in power panel and helpers. Original code copyright David Heinemeier Hansson and contributors; CPU boost extension by [nuo-yi](https://github.com/nuo-yi). Distributed under the MIT license.
