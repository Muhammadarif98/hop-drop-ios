(() => {
  // Older Android WebViews lack individual transform properties; preserve desktop motion there too.
  if (!CSS.supports('scale', '1')) {
    const fallbackUrl = new URL(location.href); fallbackUrl.searchParams.set('fx', '2d'); history.replaceState(null, '', fallbackUrl);
    const animate = Element.prototype.animate;
    Element.prototype.animate = function (frames, options) {
      if (Array.isArray(frames) && frames.some(f => 'scale' in f || 'translate' in f || 'rotate' in f)) {
        const base = getComputedStyle(this).transform;
        frames = frames.map(original => {
          const f = { ...original }, parts = [];
          if ('translate' in f) { const values = String(f.translate).trim().split(/\s+/); parts.push(`translate(${values[0]},${values[1] || '0'})`); delete f.translate; }
          if ('rotate' in f) { parts.push(`rotate(${f.rotate})`); delete f.rotate; }
          if ('scale' in f) { parts.push(`scale(${f.scale})`); delete f.scale; }
          if (f.transform) parts.push(f.transform); else if (base !== 'none') parts.push(base);
          f.transform = parts.join(' '); return f;
        });
      }
      return animate.call(this, frames, options);
    };
  }
  const pending = new Map(), listeners = new Set(), themeListeners = new Set();
  let serial = 0, selectedTheme = 'system';
  const realMatchMedia = window.matchMedia.bind(window);
  const systemDark = realMatchMedia('(prefers-color-scheme: dark)');
  const dark = () => selectedTheme === 'dark' || (selectedTheme === 'system' && systemDark.matches);
  const darkQuery = { media: '(prefers-color-scheme: dark)', get matches() { return dark(); },
    addEventListener: (_type, fn) => themeListeners.add(fn), removeEventListener: (_type, fn) => themeListeners.delete(fn),
    addListener: fn => themeListeners.add(fn), removeListener: fn => themeListeners.delete(fn) };
  window.matchMedia = query => query === '(prefers-color-scheme: dark)' ? darkQuery : realMatchMedia(query);
  const setTheme = theme => {
    selectedTheme = ['light','dark','system'].includes(theme) ? theme : 'system';
    document.documentElement.dataset.theme = dark() ? 'dark' : 'light';
    for (const fn of themeListeners) fn({ matches: dark() });
  };
  systemDark.addEventListener('change', () => setTheme(selectedTheme));
  const call = (method, ...args) => new Promise((resolve, reject) => {
    const id = String(++serial); pending.set(id, { resolve, reject });
    try { window.webkit.messageHandlers.hop.postMessage({id,method,args}); }
    catch (error) { pending.delete(id); reject(error); }
  });
  window.hopAndroid = {
    complete(id, value, error) { const p = pending.get(id); if (!p) return; pending.delete(id); error ? p.reject(new Error(error)) : p.resolve(value); },
    emit(event) { for (const fn of listeners) { try { fn(event); } catch (error) { console.error(error); } } },
    setTheme,
  };
  window.hop = {
    getLanguage: () => call('getLanguage'), setLanguage: language => call('setLanguage',language),
    init: async () => { const state = await call('init'); setTheme(state.theme); if(state.stopped)requestAnimationFrame(()=>{document.getElementById('hintTitle').textContent='Sharing stopped';document.getElementById('hintSub').textContent='Tap the Hop logo to start sharing.';}); return state; },
    send: (id, paths) => call('send', id, paths), cancel: id => call('cancel', id),
    pick: async () => {
      if(await call('hasSharedFiles'))return call('pick','files');
      const source=await window.hopSourcePicker();return source?call('pick',source):[];
    }, replyToOffer: (id, accepted, trust) => call('offer', id, accepted, Boolean(trust)),
    reveal: target => call('reveal', target), openDownloads: () => call('downloads'),
    chooseDownloadDir: () => call('location'), rename: name => call('rename', name),
    forgetTrusted: () => call('forget'),
    setTheme: async theme => { const applied = await call('theme', theme); setTheme(applied); return applied; },
    pathForFile: () => null,
    onEvent: fn => { listeners.add(fn); call('ready'); return () => listeners.delete(fn); },
  };
  document.addEventListener('DOMContentLoaded', () => {
    document.querySelector('.brand').addEventListener('click', () => call('settings'));
    // Terminal notices behave like Android notifications. Never dismiss pending offers
    // or an active transfer. A timeout fallback handles WebViews with no animationend.
    const sheets = document.getElementById('sheets');
    const scheduled = new WeakSet();
    const dismiss = node => {
      if (!node.isConnected) return;
      node.classList.add('out');
      setTimeout(() => {
        node.remove();
        document.body.classList.toggle('has-sheet', sheets.children.length > 0);
      }, 400);
    };
    new MutationObserver(() => {
      for (const node of sheets.children) {
        if (scheduled.has(node) || !(node.classList.contains('toast') || node.classList.contains('done'))) continue;
        scheduled.add(node);
        setTimeout(() => dismiss(node), 3500);
      }
    }).observe(sheets, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
  });
  setTheme('system');
})();
