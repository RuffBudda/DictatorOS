// Chromium opens its first tab (and restores old ones) before this extension
// has loaded, so those show Chromium's own new tab page instead of ours.
// Send any such tab to chrome://newtab once, which our override now handles.
const BUILTIN_NTP = /^chrome:\/\/(new-tab-page|newtab)\/?$/;
const retried = new Set();

function fix(tab) {
  if (!tab || !tab.url || !BUILTIN_NTP.test(tab.url) || retried.has(tab.id)) return;
  retried.add(tab.id);  // once per tab, so this can never loop
  chrome.tabs.update(tab.id, { url: "chrome://newtab/" });
}

chrome.tabs.query({}, (tabs) => tabs.forEach(fix));
chrome.tabs.onUpdated.addListener((id, info, tab) => { if (info.url) fix(tab); });
chrome.tabs.onRemoved.addListener((id) => retried.delete(id));
