// Normalize the two kernel interfaces to enabled=true/false.
function parseState(raw) {
  var fields = String(raw || "").trim().split("\t")
  var backend = fields[0]
  var value = fields[1]
  if (fields.length !== 2 || (backend !== "intel" && backend !== "cpufreq")
      || (value !== "0" && value !== "1"))
    return { available: false, backend: "", enabled: false }
  return { available: true, backend: backend,
    enabled: backend === "intel" ? value === "0" : value === "1" }
}

function readCommand() {
  return ["/usr/bin/bash", "-c",
    "if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then "
    + "printf 'intel\\t'; cat /sys/devices/system/cpu/intel_pstate/no_turbo; "
    + "elif [ -r /sys/devices/system/cpu/cpufreq/boost ]; then "
    + "printf 'cpufreq\\t'; cat /sys/devices/system/cpu/cpufreq/boost; fi"]
}

function setCommand(backend, enabled) {
  var path, value
  if (backend === "intel") {
    path = "/sys/devices/system/cpu/intel_pstate/no_turbo"
    value = enabled ? "0" : "1"
  } else if (backend === "cpufreq") {
    path = "/sys/devices/system/cpu/cpufreq/boost"
    value = enabled ? "1" : "0"
  } else {
    throw new Error("Unsupported CPU boost interface")
  }
  // Only the fixed kernel path is written; no user text enters this command.
  return ["pkexec", "/usr/bin/bash", "-c", "printf " + value + " > " + path]
}
