# Omarchy Power + CPU Boost

This is an Omarchy Quickshell power widget with a **Disable turbo boost / Enable turbo boost**
button. It adds the live CPU boost status to the built-in power popup. It finds the Intel and
the AMD-compatible kernel controls automatically.

The plugin ID is `rasp.power`. It replaces `omarchy.power` in the bar. It keeps the Omarchy
power IPC target and the current battery controls.

## What it does

- It shows the current battery icon, an optional percentage, the charge data, the system
  statistics and the power profile buttons.
- It adds a full-width turbo boost button below the profile buttons.
- It shows if the CPU boost is enabled or disabled.
- It reads the real kernel state when the popup opens. While the popup stays open, it reads
  the state every five seconds.
- If Intel's `intel_pstate/no_turbo` control is available, it uses that control. If not, it
  uses the generic CPUFreq `boost` control that AMD and some other drivers use.
- It asks for administrator authorization through Polkit when you change the boost.
- It shows a busy label during the change. It shows an error message if you cancel the
  authorization or the write fails.
- It hides the boost controls if it cannot read one of the supported kernel interfaces.

When you disable the boost, the CPU can make less heat, less fan noise and use less power. The
peak CPU performance is then lower. The result changes with the CPU and the workload. When you
enable the boost, the CPU can boost. This does not set a specific frequency.

## Requirements

- Omarchy with the **Quickshell shell and plugin system**. This includes `omarchy plugin enable`,
  `omarchy-shell` and the built-in `omarchy.power` widget. This is not a Waybar module.
- A battery that UPower shows. The widget hides itself on computers without a battery, for
  example desktops. This version keeps that behavior.
- `bash`, `jq`, `install`, Polkit's `pkexec` and a graphical authentication agent that runs.
  Omarchy usually supplies these.
- A `/sys/devices/system/cpu/intel_pstate/no_turbo` or `/sys/devices/system/cpu/cpufreq/boost`
  interface that the widget can read. The new controls use it.
- Node.js, only if you want to run the development tests.

The CPU scaling driver and the firmware set which control exists. The CPU brand alone does not
tell you the sysfs path.

## Install

Run these commands as your usual desktop user, in an unlocked Omarchy session:

```bash
git clone https://github.com/nuo-yi/omarchy-power-widget.git
cd omarchy-power-widget
./install.sh
```

The installer does these steps:

1. It examines the shell connection and the manifest. If Qt's `qmlformat` is available, it
   also examines the QML syntax.
2. It makes a backup of `shell.json` and of a current `rasp.power` directory, in
   `~/.config/omarchy/power-widget-backup.XXXXXX`. It shows the backup path.
3. It copies the four widget files into `~/.config/omarchy/plugins/rasp.power/`.
4. It scans the plugins again, enables `rasp.power` and starts the shell again. This removes
   the cached QML components.

Omarchy uses `omarchy.clonedFrom` to replace the standard power entry. The entry keeps its
position and its inline settings, for example `showPercentage`.

- The installer uses `XDG_CONFIG_HOME` if it is set.
- The shell must run. If it does not run, the installer stops before it changes files.
- If an installation fails later, use the backup path that the installer showed to recover.

To update, run `git pull --ff-only` in this repository. Then run `./install.sh` again.

## Use

1. Click the power icon in the bar.
2. Below **POWER PROFILE**, select **Disable turbo boost** or **Enable turbo boost**.
3. Complete the authentication prompt.

The status updates after the command is complete. While the authorization or the write
continues, the button is disabled.

- A boost change applies to the system that runs now.
- This widget does not install a boot service, a privileged helper, a Polkit rule or a saved
  boost setting. Thus the setting can reset after a reboot. A different power management tool
  can also change it.
- The boost is independent of the profile buttons. When you select a profile, this widget does
  not set the boost.

## AMD and Intel commands

You can also use these commands without the widget. Use the interface that your computer has.
To read the value, you do not need administrator access. To write it, use `sudo tee`. Then the
privileged process does the write.

### AMD / generic CPUFreq boost

AMD-compatible scaling drivers usually supply this interface. Some Intel configurations also
use it.

```bash
# Read: 1 = boost enabled, 0 = boost disabled
cat /sys/devices/system/cpu/cpufreq/boost

# Disable boost
printf '0\n' | sudo tee /sys/devices/system/cpu/cpufreq/boost

# Enable boost
printf '1\n' | sudo tee /sys/devices/system/cpu/cpufreq/boost
```

### Intel with intel_pstate

The name of the Intel interface is `no_turbo`. Thus its values have the opposite meaning:

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

The widget examines the Intel interface first, then CPUFreq. It uses `pkexec /usr/bin/bash -c`
to write a fixed `0` or `1` to the selected fixed path. It does not send text that the user
types to the privileged command.

For the driver behavior and the firmware limits, refer to the Linux kernel
[CPU frequency boost documentation](https://docs.kernel.org/admin-guide/pm/cpufreq.html#frequency-boost-support)
and the [intel_pstate documentation](https://docs.kernel.org/admin-guide/pm/intel_pstate.html).

## Every change from the built-in widget

### `Panel.qml`

1. It imports the new `Boost.js` module.
2. It adds properties for the boost availability, the normalized enabled state, the backend
   that it found, and the last action error.
3. It adds a boost read to the current refresh function. The read uses the same refresh when
   the popup opens and the same five-second timer. Thus there is no separate background poll
   when the popup is closed.
4. It adds `toggleBoost()`. This function clears an earlier error, refuses duplicate requests
   and starts the privileged command for the selected backend.
5. It adds `boostProc`. This finds the kernel interface and reads its state without
   authorization.
6. It adds `boostActionProc`. This does the authorized write and reports exit codes that are
   not zero. After a success or a failure, it reads the real kernel state again. The UI does
   not think that the write was successful.
7. It adds the action button below the profile row. Its text tells you the available action.
   Its active style shows that the boost is disabled. While a command runs, it shows a busy
   label.
8. It adds a `CPU boost` status row and a wrapped error message. If the widget finds no valid
   supported control, it hides the boost rows.

The current `moduleName`, the IPC target, `manageIpc: false` and the `togglePercentage()`
behavior stay compatible with the Omarchy cloned-plugin routing. The battery handling, the
profile selection, the keyboard profile navigation and the system statistics come from the
upstream widget.

### `Boost.js`

This new module keeps the interface detection, the value interpretation and the construction of
the privileged command together. It changes the inverted Intel values and the usual CPUFreq
values into one boolean. It refuses unknown interfaces and incorrect status output. Writes can
use only the two known paths.

### `manifest.json`

- It changes the plugin ID from `omarchy.power` to `rasp.power`. Thus the extension is in the
  user plugin directory.
- It adds `omarchy.clonedFrom: "omarchy.power"`. Thus Omarchy can replace the original bar
  entry and find its stable IPC target.
- It uses the name **Power + CPU Boost**, the version **1.1.0** and a description that includes
  the boost support.
- It gives credit to Omarchy for the original widget and to nuo-yi for the extension.
- It keeps the bar-widget entry point, the System category and the limit of one instance.

### Other files

| File | Purpose |
| --- | --- |
| `Model.js` | The upstream battery and profile helpers, without changes. |
| `install.sh` | Dependency and syntax checks, backups, file installation, enablement and a shell restart. |
| `tests/boost.test.cjs` | Tests the opposite value meanings of the two interfaces, the generated command paths, incorrect status and the refusal of unknown backends. It never writes to sysfs. |
| `upstream/Panel.qml` | The original installed Omarchy panel, kept as a baseline for comparison. It is not installed. |
| `upstream/CHANGES.patch` | The exact diff from that baseline to this panel. |
| `upstream/PROVENANCE.md` | The source paths, checksums and attribution for the inherited code. |
| `LICENSE` | The original Omarchy MIT license, kept for the derived files. The extension has the same terms. |
| `.gitignore` | Excludes temporary files and Node dependency directories. |

The plugin does not change files in `/usr/share/omarchy/`. The plugin stays after Omarchy
package updates. But it is a copy, thus it does not get future changes to the standard power
widget automatically.

## Validation and development

```bash
node tests/boost.test.cjs
bash -n install.sh
/usr/lib/qt6/bin/qmlformat Panel.qml >/dev/null
diff -u upstream/Panel.qml Panel.qml
```

- The `diff` command stops with status 1 when it finds the expected differences.
- `qmlformat` examines the parse only. It does not show that the shell imports, the hardware
  or the authentication work.
- The original widget and the first CPUFreq version operated in the live Omarchy session of
  the user. The published version also had a check in that session during preparation.
- Automated tests cover the Intel polarity. There was no test of an Intel hardware write.
- Hardware writes on other computers depend on their driver, their firmware and their
  authorization setup.

To examine the shell errors:

```bash
quickshell log --any-display -p /usr/share/omarchy/shell -t 80
```

## Troubleshooting

**The power icon is not visible:** Look for `Plugin widget rasp.power failed` in the shell log.
In an earlier local version, a QML syntax error removed the icon. The error was a missing
closing brace, and this version corrects it. Install the widget again and start the shell
again to clear the cached components. If necessary, restore the standard widget with the
commands below.

**There is no boost button:** Make sure that one of the sysfs files exists and contains `0` or
`1`. The driver or the firmware can lack support for the feature. Or the widget cannot read the
controls. In these cases, the widget does not show the feature.

**The authorization fails or no prompt shows:** Make sure that `pkexec` and a graphical Polkit
authentication agent are available. If you cancel the authorization, the current state does
not change and an error shows. The firmware can also refuse a change.

**The value changes back:** A different power management tool can write it. The widget reads
the real state again. It does not save its own setting.

**There is no icon on a desktop without a battery:** When UPower reports no battery, the
inherited panel hides itself. Desktop support needs a separate change to that behavior.

## Restore the stock widget

```bash
omarchy plugin disable rasp.power
omarchy plugin enable omarchy.power
omarchy restart shell
```

When you disable the clone, Omarchy restores the source of the clone. The enable command also
covers a missing standard entry. The copied files can stay installed while the plugin is
disabled. To restore the exact earlier configuration, use the backup path that the installer
showed. An older `shell.json` also restores all other bar settings from that backup.

## Credits

This widget uses the built-in power panel and helpers of [Omarchy](https://github.com/basecamp/omarchy).
The original code is copyright David Heinemeier Hansson and contributors. The CPU boost
extension is by [nuo-yi](https://github.com/nuo-yi). The license is MIT.
