'use strict';

const HOST = 'studio.foi.youtubesurround';
const STATE_KEY = 'surroundOwner';
const bridge = browser.runtime;
const READY = new Set(['ready', 'playing', 'paused']);
const VIDEO_ID = /^[a-zA-Z0-9_-]{11}$/;
let owner;
let pending = Promise.resolve();

// Tab handoffs, muting and session changes must complete in order.
function ordered(job) {
  const result = pending.then(job);
  pending = result.catch(() => {});
  return result;
}

function isYouTube(url) {
  try {
    const page = new URL(url);
    return page.protocol === 'https:' && ['youtube.com', 'www.youtube.com'].includes(page.hostname);
  } catch {
    return false;
  }
}

async function getOwner() {
  if (owner === undefined) {
    const saved = await browser.storage.local.get(STATE_KEY);
    owner = saved[STATE_KEY] || null;
  }
  return owner;
}

async function save() {
  if (owner) await browser.storage.local.set({ [STATE_KEY]: owner });
  else await browser.storage.local.remove(STATE_KEY);
}

async function native(message) {
  let timer;
  // Launching the companion on its first use can take longer than an ordinary heartbeat.
  const timeout = message.op === 'sync' && !message.armed ? 6500 : 2200;
  try {
    return await Promise.race([
      bridge.sendNativeMessage(HOST, message),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('The surround helper did not respond.')), timeout);
      })
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function stopNative(active) {
  if (!active?.session) return;
  try {
    await native({ op: 'stop', session: active.session, videoId: active.videoId });
  } catch {
    // The native playback lease also stops audio if Safari closes mid-request.
  }
}

async function restoreTab(active) {
  if (!active?.mutedByUs) return;
  try {
    await browser.tabs.update(active.tabId, { muted: false });
  } catch {
    // A tab that just closed no longer has audio to restore.
  }
  active.mutedByUs = false;
}

async function release(active, notify = false) {
  if (!active) return;
  await stopNative(active);
  await restoreTab(active);
  if (notify) {
    browser.tabs.sendMessage(active.tabId, { kind: 'foi-revoked', token: active.token }).catch(() => {});
  }
  owner = null;
  await save();
}

async function silenceTab(active) {
  const tab = await browser.tabs.get(active.tabId);
  if (tab.mutedInfo?.muted !== false) {
    throw new Error(tab.mutedInfo?.muted
      ? 'Unmute this Safari tab and try 5.1 again.'
      : 'Safari could not confirm the tab’s mute state.');
  }
  // Save ownership before changing Safari, so a restarted background can restore it.
  active.mutedByUs = true;
  await save();
  await browser.tabs.update(active.tabId, { muted: true });
  const confirmed = await browser.tabs.get(active.tabId);
  if (confirmed.mutedInfo?.muted !== true) throw new Error('Safari could not silence the stereo track.');
}

function playback(message, prepare = false) {
  const age = Math.max(0, Math.min(1.5, (Date.now() - message.sampledAt) / 1000));
  return {
    op: 'sync', session: message.session, videoId: message.videoId,
    time: message.time + (message.playing ? age * message.rate : 0),
    armed: !prepare, playing: message.playing === true,
    muted: message.muted === true,
    rate: message.rate, volume: message.volume
  };
}

function validPlayback(m) {
  return typeof m.session === 'string' && m.session.length <= 100 && VIDEO_ID.test(m.videoId) &&
    Number.isFinite(m.time) && m.time >= 0 && Number.isFinite(m.sampledAt) &&
    Number.isFinite(m.rate) && m.rate > 0 && m.rate <= 16 &&
    Number.isFinite(m.volume) && m.volume >= 0 && m.volume <= 1;
}

async function suspend(active) {
  await stopNative(active);
  await restoreTab(active);
  active.session = null;
  active.videoId = null;
  await save();
}

async function handle(message, sender) {
  if (!sender.tab || sender.frameId > 0 || !isYouTube(sender.url || sender.tab.url)) {
    return { state: 'error', message: 'Open a YouTube video in Safari.' };
  }
  let active = await getOwner();
  const tabId = sender.tab.id;
  const token = message.token;
  if (typeof token !== 'string' || token.length > 100) return { state: 'error' };

  if (message.kind === 'foi-enable') {
    if (active && active.tabId === tabId && active.token === token) return { state: 'enabled' };
    await release(active, true);
    owner = { tabId, token, session: null, videoId: null, mutedByUs: false };
    await save();
    return { state: 'enabled' };
  }

  if (!active || active.tabId !== tabId || active.token !== token) return { state: 'revoked' };
  if (message.kind === 'foi-disable') {
    await release(active);
    return { state: 'stopped' };
  }
  if (message.kind === 'foi-suspend') {
    if (!message.session || message.session === active.session) await suspend(active);
    return { state: 'stopped' };
  }
  if (message.kind !== 'foi-sync' || !validPlayback(message)) return { state: 'error' };

  try {
    if (active.session !== message.session || active.videoId !== message.videoId) {
      if (active.session) await suspend(active);
      active.session = message.session;
      active.videoId = message.videoId;
      await save();
    }
    if (!active.mutedByUs) {
      const prepared = await native(playback(message, true));
      if (!READY.has(prepared?.state)) {
        if (prepared?.state !== 'loading') await suspend(active);
        return prepared || { state: 'error', message: 'The surround helper is unavailable.' };
      }
      if (prepared.channels !== 6) throw new Error('The helper could not verify six audio channels.');
      await silenceTab(active);
    }
    const result = await native(playback(message));
    if (!READY.has(result?.state)) {
      // A buffer underrun or a helper restart must give the tab its own sound back.
      if (result?.state === 'loading') {
        await restoreTab(active);
        await save();
      } else {
        await suspend(active);
      }
    }
    return result || { state: 'error', message: 'The surround helper is unavailable.' };
  } catch (error) {
    await suspend(active);
    return { state: 'error', message: error.message || 'The surround helper is unavailable.' };
  }
}

bridge.onMessage.addListener((message, sender) => {
  if (!['foi-enable', 'foi-disable', 'foi-suspend', 'foi-sync'].includes(message?.kind)) return undefined;
  return ordered(() => handle(message, sender));
});

browser.tabs.onRemoved.addListener(tabId => {
  ordered(async () => {
    const active = await getOwner();
    if (active?.tabId === tabId) await release(active);
  });
});

browser.tabs.onUpdated.addListener((tabId, change) => {
  if (!change.url && change.status !== 'loading' && change.mutedInfo?.muted !== false) return;
  ordered(async () => {
    const active = await getOwner();
    if (active?.tabId !== tabId) return;
    if (change.status === 'loading' || (change.url && !isYouTube(change.url))) {
      await release(active, true);
    } else if (change.mutedInfo?.muted === false && active.mutedByUs) {
      // An explicit unmute in Safari returns control to the original player.
      const tab = await browser.tabs.get(tabId);
      if (tab.mutedInfo?.muted === false) await release(active, true);
    }
  });
});

// A browser restart can leave a restored tab muted after the native lease has expired.
bridge.onStartup.addListener(() => ordered(async () => {
  const active = await getOwner();
  if (active) await release(active, true);
}));
