(() => {
  'use strict';
  const api = browser.runtime;
  // Safari can reinject scripts into a live document. The DOM handshake also
  // covers separate isolated worlds that share the same YouTube player.
  const probeEvent = 'studio.foi.youtubesurround.probe';
  if (!document.dispatchEvent(new Event(probeEvent, { cancelable: true }))) return;
  document.addEventListener(probeEvent, event => event.preventDefault());
  const token = crypto.randomUUID();
  let enabled = false;
  let ownerReady = false;
  let navigating = false;
  let session = null;
  let videoId = null;
  let element = null;
  let player = null;
  let control = null;
  let notice = null;
  let noticeTimer;
  let pulseTimer;
  let busy = false;
  let queued = false;
  let buffering = false;
  let failedVideo = null;
  let generation = 0;
  let activation = 0;
  let presentation = { mode: 'off', detail: 'Use YouTube audio' };

  function currentId() {
    if (location.pathname !== '/watch') return null;
    const id = new URL(location.href).searchParams.get('v');
    return id && /^[\w-]{11}$/.test(id) ? id : null;
  }

  function send(kind, fields = {}) {
    return api.sendMessage({ kind, token, ...fields });
  }

  function draw() {
    if (!control) return;
    control.dataset.mode = presentation.mode;
    control.setAttribute('aria-pressed', String(enabled));
    if (!enabled) control.title = 'Play original 5.1 through FOI Monitor';
    else if (failedVideo === currentId()) control.title = presentation.detail + ' · Retry 5.1';
    else control.title = presentation.detail + ' · Click for YouTube audio';
    control.setAttribute('aria-label', 'FOI Surround. ' + control.title);
  }

  function show(mode, detail) {
    if (presentation.mode === mode && presentation.detail === detail) return;
    presentation = { mode, detail };
    draw();
    if (!player) return;
    if (!notice?.isConnected) {
      notice = document.createElement('div');
      notice.className = 'foi-surround-notice';
      notice.setAttribute('role', 'status');
      player.append(notice);
    }
    notice.textContent = detail;
    notice.hidden = false;
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => { if (notice) notice.hidden = true; }, mode === 'fallback' ? 7000 : 3000);
  }

  function playerNode() {
    const id = currentId();
    if (!id) return null;
    const players = [...document.querySelectorAll('[id="movie_player"]')];
    const present = players.filter(candidate => candidate.getClientRects().length &&
      candidate.querySelector('video.html5-main-video'));
    return present.find(candidate => candidate.closest('[video-id]')?.getAttribute('video-id') === id)
      || present[0] || null;
  }

  function discardCopies() {
    // YouTube may clone the whole controls container when switching layouts.
    // A clone carries the button ID/label but none of its JS event handlers.
    for (const other of document.querySelectorAll('.foi-surround-control')) {
      if (other === control) continue;
      if (other.dataset.foiOwner === token) {
        other.remove();
      } else if (!other.hidden) {
        // A button from an older installation can still have a live observer.
        // Hide that node in place so the old observer does not recreate it.
        other.hidden = true;
        other.removeAttribute('id');
        other.setAttribute('aria-hidden', 'true');
        other.tabIndex = -1;
      }
    }
  }

  function mount() {
    const next = playerNode();
    if (player !== next) {
      control?.remove();
      notice?.remove();
      notice = control = null;
      player = next;
      adObserver.disconnect();
      if (player) adObserver.observe(player, { attributes: true, attributeFilter: ['class'], attributeOldValue: true });
    }
    const gears = player?.querySelectorAll('.ytp-right-controls .ytp-settings-button') || [];
    const gear = [...gears].find(button => button.getClientRects().length);
    if (gear && !control) {
      control = document.createElement('button');
      control.type = 'button';
      control.id = 'foi-youtube-surround';
      control.dataset.foiOwner = token;
      control.className = 'ytp-button foi-surround-control';
      const ns = 'http://www.w3.org/2000/svg';
      const icon = document.createElementNS(ns, 'svg');
      icon.setAttribute('viewBox', '0 0 26 18');
      icon.setAttribute('aria-hidden', 'true');
      icon.setAttribute('focusable', 'false');
      const outline = document.createElementNS(ns, 'rect');
      for (const [key, value] of Object.entries({ x: 1.25, y: 1.25, width: 23.5, height: 15.5, rx: 3.5 })) {
        outline.setAttribute(key, value);
      }
      const digits = document.createElementNS(ns, 'path');
      digits.setAttribute('d', 'M11 5.7H6.8l-.4 3.1a3.6 3.6 0 0 1 1.8-.5c1.6 0 2.7.8 2.7 2.2s-1 2.4-2.6 2.4c-1 0-2-.4-2.7-1.1M13.7 12.5h.1M16 7.1l2.3-1.5v7');
      icon.append(outline, digits);
      control.append(icon);
      control.addEventListener('click', event => {
        event.preventDefault();
        event.stopPropagation();
        if (enabled && failedVideo === currentId()) {
          failedVideo = null;
          suspend();
          sync();
        } else {
          void toggle();
        }
      });
      draw();
    }
    // Move the live node, with its event handlers, when the player rebuilds.
    if (gear && control.nextElementSibling !== gear) gear.before(control);
    if (!gear) control?.remove();
    discardCopies();
    const video = player?.querySelector('video.html5-main-video') || null;
    if (video !== element) {
      if (element) {
        for (const name of mediaEvents) element.removeEventListener(name, onMedia);
        suspend();
      }
      element = video;
      buffering = false;
      if (element) for (const name of mediaEvents) element.addEventListener(name, onMedia);
    }
  }

  function suspend() {
    const previous = session;
    generation++;
    session = null;
    videoId = null;
    if (previous) send('foi-suspend', { session: previous }).catch(() => {});
  }

  function setOff(message = 'Using YouTube audio') {
    enabled = ownerReady = false;
    activation++;
    generation++;
    session = videoId = failedVideo = null;
    clearInterval(pulseTimer);
    pulseTimer = null;
    show('off', message);
    draw();
  }

  async function toggle() {
    if (enabled) {
      setOff();
      await send('foi-disable').catch(() => {});
      return;
    }
    if (!currentId()) return;
    enabled = true;
    const attempt = ++activation;
    failedVideo = null;
    show('checking', 'Checking for original 5.1…');
    try {
      const reply = await send('foi-enable');
      if (!enabled || activation !== attempt) return;
      if (reply?.state !== 'enabled') throw new Error(reply?.message || 'Safari could not start surround playback.');
      ownerReady = true;
      pulseTimer = setInterval(sync, 700);
      sync();
    } catch (error) {
      if (activation === attempt) setOff(error.message || 'Open the FOI YouTube Surround app and try again.');
    }
  }

  const mediaEvents = ['playing', 'play', 'pause', 'ended', 'seeking', 'seeked',
    'waiting', 'canplay', 'ratechange', 'volumechange', 'loadedmetadata', 'emptied'];

  function onMedia(event) {
    if (event.type === 'waiting' || event.type === 'emptied') buffering = true;
    if (['playing', 'canplay', 'seeked'].includes(event.type)) buffering = false;
    sync();
  }

  function isAd() {
    return player?.classList.contains('ad-showing') || player?.classList.contains('ad-interrupting');
  }

  async function sync() {
    if (!enabled || !ownerReady) return;
    if (busy) { queued = true; return; }
    mount();
    const id = currentId();
    const renderer = player?.closest('ytd-watch-flexy, ytd-watch-grid');
    const renderedId = renderer?.getAttribute('video-id');
    if (navigating || !id || !element || !element.isConnected || (renderedId && renderedId !== id) || isAd()) {
      suspend();
      if (enabled) show('waiting', isAd() ? 'YouTube audio during ads' : 'Waiting for the video');
      return;
    }
    if (failedVideo === id) return;
    if (element.readyState < 1 || !Number.isFinite(element.currentTime)) return;
    if (element.ended || element.duration === Infinity) {
      suspend();
      show('waiting', element.ended ? 'Video ended' : 'Using YouTube audio for this live stream');
      return;
    }
    if (videoId !== id || !session) {
      suspend();
      failedVideo = null;
      session = crypto.randomUUID();
      videoId = id;
      show('checking', 'Checking for original 5.1…');
    }
    const revision = generation;
    const sample = {
      session, videoId, time: element.currentTime,
      playing: !element.paused && !element.seeking && !buffering && element.readyState >= 3,
      muted: element.muted, rate: element.playbackRate, volume: element.volume, sampledAt: Date.now()
    };
    busy = true;
    try {
      const state = await send('foi-sync', sample);
      if (revision !== generation || !enabled) return;
      switch (state?.state) {
        case 'ready':
        case 'playing':
        case 'paused':
          show('on', 'Original 5.1 · FOI Monitor');
          break;
        case 'loading':
          show('checking', 'Checking for original 5.1…');
          break;
        case 'revoked':
          setOff();
          break;
        default:
          failedVideo = id;
          show('fallback', state?.message || '5.1 unavailable · Using YouTube audio');
          break;
      }
    } catch {
      if (revision === generation) {
        failedVideo = id;
        send('foi-suspend', { session }).catch(() => {});
        show('fallback', 'Surround helper unavailable · Using YouTube audio');
      }
    } finally {
      busy = false;
      if (queued) {
        queued = false;
        queueMicrotask(sync);
      }
    }
  }

  function UIState() {
    return { supported: Boolean(currentId()), enabled, ...presentation };
  }

  api.onMessage.addListener(message => {
    if (message?.kind === 'foi-popup-status') return Promise.resolve(UIState());
    if (message?.kind === 'foi-popup-toggle') return toggle().then(UIState);
    if (message?.kind === 'foi-revoked' && message.token === token) setOff('Using YouTube audio');
    return undefined;
  });

  document.addEventListener('yt-navigate-start', () => {
    navigating = true;
    suspend();
  });
  function arrived() {
    navigating = false;
    mount();
    sync();
  }
  document.addEventListener('yt-navigate-finish', arrived);
  document.addEventListener('yt-page-data-updated', arrived);
  window.addEventListener('popstate', arrived);
  window.addEventListener('pageshow', arrived);
  window.addEventListener('pagehide', () => {
    if (enabled) {
      setOff();
      send('foi-disable').catch(() => {});
    }
  });

  const adObserver = new MutationObserver(records => {
    const before = /(?:^|\s)ad-(?:showing|interrupting)(?:\s|$)/.test(records[0]?.oldValue || '');
    if (before === Boolean(isAd())) return;
    if (isAd()) suspend();
    sync();
  });

  // YouTube replaces the main video or controls during in-page navigation.
  let refreshTimer;
  const relevant = '.foi-surround-control,.ytp-right-controls,.ytp-settings-button,[id="movie_player"],video.html5-main-video';
  const observer = new MutationObserver(records => {
    if (refreshTimer || (!player && !currentId())) return;
    if (control?.isConnected && element?.isConnected && player?.isConnected && currentId()) {
      const rebuilt = records.some(record => Array.from(record.addedNodes).some(node =>
        node.nodeType === 1 && (node.matches(relevant) || node.querySelector(relevant))));
      if (!rebuilt) return;
    }
    refreshTimer = setTimeout(() => { refreshTimer = null; mount(); }, 60);
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  mount();
})();
