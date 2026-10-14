let currentAudio = null;
let subtitleTimer = null;
let playToken = 0;
let stopped = false;
const subtitle = document.getElementById('subtitle');

// Captured under a different name on purpose. Declaring a function called
// GetParentResourceName would overwrite the native FiveM injects and then call
// itself forever.
const RES = (typeof GetParentResourceName === 'function')
  ? GetParentResourceName() : 'rs-aidoc';

function post(name, body) {
  fetch(`https://${RES}/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(body || {})
  }).catch(() => {});
}

function hideSubtitle(){
  subtitle.classList.remove('show');
  if (subtitleTimer) clearTimeout(subtitleTimer);
  subtitleTimer = null;
}

window.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.action === 'stop') {
    stopped = true;                  // invalidate in-flight callbacks without consuming Lua's next token
    if (currentAudio) { currentAudio.pause(); currentAudio = null; }
    hideSubtitle();
    return;
  }
  if (data.action !== 'play' || !data.file) return;

  const token = Number(data.token);
  if (!Number.isSafeInteger(token) || token <= playToken) return;
  playToken = token;
  stopped = false;
  if (currentAudio) currentAudio.pause();
  hideSubtitle();
  currentAudio = new Audio(data.file);
  currentAudio.volume = Math.max(0, Math.min(1, Number(data.volume ?? 0.75)));

  // Lua waits on these so one line can finish before the next begins.
  // A stale token means this clip was already superseded -- ignore it, or a
  // late 'ended' from an old line would release the wait for the new one.
  currentAudio.addEventListener('loadedmetadata', () => {
    if (token !== playToken || stopped) return;
    const ms = Math.round((currentAudio.duration || 0) * 1000);
    post('audioMeta', { token, duration: ms });
    // Captions are tied to the clip's real length, not an arbitrary 5.2s cutoff.
    if (data.subtitle && Number.isFinite(ms) && ms > 0) {
      if (subtitleTimer) clearTimeout(subtitleTimer);
      subtitleTimer = setTimeout(hideSubtitle, ms + 350);
    }
  });

  let settled = false;
  const finish = (reason) => {
    if (token !== playToken || stopped || settled) return;
    settled = true;
    if (subtitleTimer) clearTimeout(subtitleTimer);
    subtitleTimer = null;
    hideSubtitle();
    if (reason === 'ended' && currentAudio) currentAudio = null;
    post('audioEnded', { token, reason });
  };

  currentAudio.addEventListener('ended', () => finish('ended'));
  // A missing or unreadable file must still release the waiter, otherwise the
  // treatment sequence would stall until its timeout every single time.
  currentAudio.addEventListener('error', () => finish('error'));

  currentAudio.play().then(() => {
    if (token === playToken && !stopped) post('audioStarted', { token });
  }).catch(() => finish('blocked'));

  if (data.subtitle) {
    subtitle.textContent = data.subtitle;
    subtitle.classList.add('show');
    if (subtitleTimer) clearTimeout(subtitleTimer);
    // Failsafe for unreadable audio; metadata updates this to true clip length.
    subtitleTimer = setTimeout(hideSubtitle, Math.max(1000, Number(data.subtitleMs || 15000)));
  }
});
