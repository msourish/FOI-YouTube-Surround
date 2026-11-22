'use strict';
const statusLabel = document.getElementById('status');
const toggle = document.getElementById('toggle');
let busy = false;

async function refresh(change = false) {
  if (busy) return;
  busy = true;
  try {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    const result = await browser.tabs.sendMessage(tab.id, { kind: change ? 'foi-popup-toggle' : 'foi-popup-status' });
    if (!result?.supported) throw new Error();
    statusLabel.textContent = !result.enabled && result.mode === 'off' && result.detail === 'Use YouTube audio'
      ? 'YouTube audio' : result.detail;
    toggle.textContent = result.enabled ? 'Use YouTube audio' : 'Play in 5.1';
    toggle.disabled = false;
  } catch {
    statusLabel.textContent = 'Open a YouTube watch page and allow this extension on youtube.com.';
    toggle.disabled = true;
  } finally {
    busy = false;
  }
}
toggle.addEventListener('click', () => refresh(true));
refresh();
setInterval(() => refresh(), 800);
