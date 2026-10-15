'use strict';

/* Revit Server Stack control panel, front-end.
   No dependencies: the panel must run from a plain file server with no
   network access and no npm install. All texts live in i18n/<language>.json. */

const TOKEN = document.querySelector('meta[name="panel-token"]').content;

const state = {
  status: null,
  health: { versions: {}, proxy: false },
  healthLoaded: false,
  config: null,
  contexts: [],
  engines: null,
  panel: null,
  runningJobs: [],
  activeJobId: null,
  logOffset: 0,
  logRunning: false,
  busy: new Set(),
  statusTimer: null,
  healthTimer: null,
  logTimer: null,
};

const $ = (id) => document.getElementById(id);
const esc = (value) => String(value === undefined || value === null ? '' : value)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

/* ----------------------------------------------------------------- i18n -- */

const i18n = { languages: [], code: 'en', texts: {}, fallback: {} };

// The text of a key in the current language, with {0}, {1} ... filled in.
// English stands in for a missing key, and the key itself for a missing catalog.
function t(key, ...args) {
  const has = (catalog) => Object.prototype.hasOwnProperty.call(catalog, key);
  let text = key;
  if (has(i18n.texts)) text = i18n.texts[key];
  else if (has(i18n.fallback)) text = i18n.fallback[key];
  return text.replace(/\{(\d+)\}/g, (whole, index) => (args[Number(index)] === undefined ? whole : String(args[Number(index)])));
}

// "pt-PT" gives "pt-BR", "zh-TW" gives "zh-CN", an unknown language gives null.
function matchLanguage(name) {
  if (!name) return null;
  const wanted = String(name).toLowerCase();
  const exact = i18n.languages.find((item) => item.code.toLowerCase() === wanted);
  if (exact) return exact.code;
  const base = wanted.split('-')[0];
  const found = i18n.languages.find((item) => item.code.toLowerCase() === base)
    || i18n.languages.find((item) => item.code.toLowerCase().split('-')[0] === base);
  return found ? found.code : null;
}

// What the user chose before, else what the browser asks for, else English.
function pickLanguage() {
  let saved = null;
  try { saved = window.localStorage.getItem('rss-lang'); } catch (err) { /* storage can be blocked */ }
  const asked = (navigator.languages && navigator.languages.length) ? navigator.languages : [navigator.language];
  for (const name of [saved].concat(Array.from(asked))) {
    const code = matchLanguage(name);
    if (code) return code;
  }
  return 'en';
}

async function loadCatalog(code) {
  const response = await fetch(`i18n/${encodeURIComponent(code)}.json`, { cache: 'no-store' });
  if (!response.ok) throw new Error(`i18n/${code}.json: HTTP ${response.status}`);
  return response.json();
}

// Fills every element that carries a data-i18n* attribute. The "html" variant
// is for catalog text with markup (<code>), never for data from the server.
function applyStaticTexts() {
  document.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
  document.querySelectorAll('[data-i18n-html]').forEach((el) => { el.innerHTML = t(el.dataset.i18nHtml); });
  document.querySelectorAll('[data-i18n-title]').forEach((el) => { el.title = t(el.dataset.i18nTitle); });
  document.querySelectorAll('[data-i18n-placeholder]').forEach((el) => { el.placeholder = t(el.dataset.i18nPlaceholder); });
  document.querySelectorAll('[data-i18n-aria-label]').forEach((el) => { el.setAttribute('aria-label', t(el.dataset.i18nAriaLabel)); });
  if (!state.activeJobId) $('log-title').textContent = t('log.hint');
  renderFooter();
}

async function setLanguage(code, remember) {
  let texts = i18n.fallback;
  if (code !== 'en') {
    try {
      texts = await loadCatalog(code);
    } catch (err) {
      code = 'en'; // a broken install must not leave the panel without texts
    }
  }
  i18n.code = code;
  i18n.texts = texts;
  document.documentElement.lang = code;
  $('lang').value = code;
  if (remember) {
    try { window.localStorage.setItem('rss-lang', code); } catch (err) { /* storage can be blocked */ }
  }
  applyStaticTexts();
  // The server words its messages in the language of the request, so the
  // status is fetched again rather than translated here.
  if (state.status) refreshStatus();
}

async function initLanguage() {
  const index = await fetch('i18n/index.json', { cache: 'no-store' });
  i18n.languages = await index.json();
  i18n.fallback = await loadCatalog('en');

  const select = $('lang');
  select.innerHTML = i18n.languages
    .map((item) => `<option value="${esc(item.code)}">${esc(item.name)}</option>`).join('');
  select.onchange = () => setLanguage(select.value, true);

  await setLanguage(pickLanguage(), false);
}

/* ------------------------------------------------------------------ api -- */

async function api(path, options = {}) {
  const init = {
    method: options.method || 'GET',
    headers: { 'X-Panel-Token': TOKEN, 'X-Panel-Lang': i18n.code },
  };
  if (options.body !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(options.body);
  }

  let response;
  try {
    response = await fetch(path, init);
  } catch (err) {
    throw new Error(t('err.panelDown'));
  }

  let data = null;
  try {
    data = await response.json();
  } catch (err) {
    throw new Error(t('err.badAnswer', response.status));
  }
  if (!response.ok && data && data.error) throw new Error(data.error);
  return data;
}

/* --------------------------------------------------------------- alerts -- */

function alertBox(message, kind = 'info', autoHideMs = 0) {
  const box = document.createElement('div');
  box.className = `alert ${kind}`;
  box.innerHTML = `<span>${esc(message)}</span>`;

  const close = document.createElement('button');
  close.className = 'close';
  close.type = 'button';
  close.textContent = '×';
  close.setAttribute('aria-label', t('alert.hide'));
  close.onclick = () => box.remove();
  box.appendChild(close);

  $('alerts').appendChild(box);
  if (autoHideMs > 0) setTimeout(() => box.remove(), autoHideMs);
  return box;
}

function clearAlerts() { $('alerts').innerHTML = ''; }

/* -------------------------------------------------------------- actions -- */

async function runAction(target, action, confirmText) {
  if (confirmText && !window.confirm(confirmText)) return;

  state.busy.add(target);
  renderCards();
  try {
    const result = await api('/api/action', { method: 'POST', body: { target, action } });

    if (target === 'all') {
      const failed = (result.results || []).filter((r) => r.result && !r.result.ok);
      if (failed.length) {
        alertBox(failed.map((r) => `${r.target}: ${r.result.error}`).join('; '), 'info', 9000);
      }
      const started = (result.results || []).filter((r) => r.result && r.result.ok);
      if (started.length) attachToJob(started[started.length - 1].result.jobId);
    } else if (result.ok && result.jobId) {
      attachToJob(result.jobId);
    } else if (!result.ok) {
      alertBox(result.error || t('err.operationFailed'), 'error', 9000);
      if (result.jobId) attachToJob(result.jobId);
    }
  } catch (err) {
    alertBox(err.message, 'error', 9000);
  } finally {
    state.busy.delete(target);
    refreshStatus();
  }
}

/* ------------------------------------------------------------ log panel -- */

function attachToJob(jobId) {
  if (!jobId) return;
  state.activeJobId = jobId;
  state.logOffset = 0;
  state.logRunning = true;
  $('log').textContent = '';
  pollLog();
  refreshJobs();
  if (state.logTimer) clearInterval(state.logTimer);
  state.logTimer = setInterval(pollLog, 1000);
}

async function pollLog() {
  if (!state.activeJobId) return;
  try {
    const data = await api(`/api/job?id=${encodeURIComponent(state.activeJobId)}&offset=${state.logOffset}`);
    if (data.id !== state.activeJobId) return;

    $('log-title').textContent = data.title || '';
    if (data.text) {
      const logEl = $('log');
      const atBottom = logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight < 40;
      logEl.textContent += data.text;
      state.logOffset = data.offset;
      if (atBottom) logEl.scrollTop = logEl.scrollHeight;
    }

    state.logRunning = !!data.running;
    $('btn-cancel-job').hidden = !data.running;

    if (!data.running) {
      stopLogPolling();
      appendFinishNote(data);
      refreshStatus();
      refreshJobs();
    }
  } catch (err) {
    stopLogPolling();
  }
}

function appendFinishNote(data) {
  let key;
  if (data.finishedReason === 'cancelled') key = 'jobnote.cancelled';
  else if (data.finishedReason === 'detached') key = 'jobnote.detached';
  else if (data.exitCode === 0) key = 'jobnote.done';
  else if (data.exitCode === null || data.exitCode === undefined) key = 'jobnote.unknown';
  else key = 'jobnote.failed';
  let note = `\n--- ${t(key, data.exitCode)} ---\n`;

  const logEl = $('log');
  // The Windows engine does not create a missing bind source, and the daemon's own wording is easy to misread.
  if (data.exitCode && logEl.textContent.indexOf('bind source path does not exist') >= 0) {
    note += `${t('jobnote.bindMissing')}\n`;
  }
  logEl.textContent += note;
  logEl.scrollTop = logEl.scrollHeight;
}

function stopLogPolling() {
  if (state.logTimer) { clearInterval(state.logTimer); state.logTimer = null; }
  state.logRunning = false;
  $('btn-cancel-job').hidden = true;
}

/* --------------------------------------------------------------- render -- */

function pill(label, kind, actionLabel, onAction) {
  const el = document.createElement('span');
  el.className = `pill ${kind}`;
  el.title = label;
  el.innerHTML = `<span class="dot"></span><span>${esc(label)}</span>`;
  if (actionLabel && onAction) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = actionLabel;
    btn.onclick = onAction;
    el.appendChild(btn);
  }
  return el;
}

function renderEngines() {
  const host = $('engines');
  host.innerHTML = '';
  const status = state.status;
  if (!status) return;

  // Docker Desktop matters only while one of the engines runs on this machine.
  if (status.usesLocalEngine) {
    if (status.dockerDesktop) {
      host.appendChild(pill('Docker Desktop', 'ok'));
    } else {
      host.appendChild(pill(t('engine.desktopDown'), 'bad', t('engine.start'),
        () => runAction('engine', 'start-desktop')));
    }
  }

  // For an engine on another machine the pill names that machine, and the
  // buttons that drive Docker Desktop make no sense.
  const win = status.windowsEngine;
  const winName = win.remote ? `${win.host}, ${win.context}` : win.context;
  if (win.reachable) {
    host.appendChild(pill(t('engine.windowsOk', winName), 'ok'));
  } else {
    host.appendChild(pill(t('engine.windowsDown', winName, win.error || ''), 'bad',
      win.remote ? null : t('engine.switch'), win.remote ? null : () => runAction('engine', 'switch-windows')));
  }
  if (win.hostInvalid) {
    host.appendChild(pill(t('engine.windowsHostInvalid'), 'warn'));
  }

  const proxyEngine = status.proxyEngine;
  const proxyContextName = proxyEngine.context || t('engine.currentContext');
  const proxyName = proxyEngine.remote ? `${proxyEngine.host}, ${proxyContextName}` : proxyContextName;
  if (proxyEngine.reachable) {
    host.appendChild(pill(t('engine.linuxOk', proxyName), 'ok'));
  } else {
    host.appendChild(pill(t('engine.linuxDown', proxyName), 'warn'));
  }
  if (proxyEngine.hostInvalid) {
    host.appendChild(pill(t('engine.linuxHostInvalid'), 'warn'));
  }

  host.appendChild(pill(t('engine.updated', status.checkedAt), 'idle', t('engine.refresh'), refreshStatus));
}

function actionButton(label, handler, opts = {}) {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = `btn btn-small${opts.className ? ' ' + opts.className : ''}`;
  btn.textContent = label;
  btn.disabled = !!opts.disabled;
  if (opts.title) btn.title = opts.title;
  btn.onclick = handler;
  return btn;
}

function renderVersionCard(version) {
  const target = `rs${version.year}`;
  const busy = state.busy.has(target) || isJobRunningFor(target);
  const health = state.health.versions ? state.health.versions[String(version.year)] : null;

  const card = document.createElement('div');
  card.className = `card${version.enabled ? '' : ' disabled'}`;

  let stateKey = version.state;
  let stateLabel = t(`state.${stateKey}`);
  // "Container up" is not "server ready": IIS inside needs a while to answer.
  // Only say so once a probe has actually run, or a freshly loaded page would
  // slander a perfectly healthy server.
  if (stateKey === 'running' && state.healthLoaded && health && !health.ready) {
    stateKey = 'starting';
    stateLabel = t('state.runningNoWeb');
  }

  const head = document.createElement('div');
  head.className = 'card-head';
  head.innerHTML = `
    <div class="card-title">Revit Server <span class="year">${version.year}</span></div>
    <span class="badge ${esc(stateKey)}"><span class="dot"></span>${esc(stateLabel)}</span>`;
  card.appendChild(head);

  const meta = document.createElement('dl');
  meta.className = 'card-meta';
  const openUrl = pickOpenUrl(version);
  let modelsNote = '';
  if (state.status.windowsEngine.remote) {
    modelsNote = version.dataDirOk
      ? ` <span class="muted">${esc(t('card.onServer'))}</span>`
      : ` <span class="warn-text">${esc(t('card.needServerPath', `D:\\RevitServerData\\rs${version.year}`))}</span>`;
  }
  meta.innerHTML = `
    <dt>${esc(t('card.state'))}</dt><dd>${esc(version.statusText)}</dd>
    <dt>${esc(t('card.port'))}</dt><dd>${esc(version.hostPort)}</dd>
    <dt>${esc(t('card.image'))}</dt><dd>${version.imageBuilt
      ? esc(version.imageName)
      : `<span class="muted">${esc(t('card.imageMissing'))}</span>`}</dd>
    <dt>${esc(t('card.models'))}</dt><dd>${esc(version.dataDir)}${modelsNote}</dd>
    <dt>${esc(t('card.revit'))}</dt><dd>${version.revitClients
      ? esc(t('card.port808On'))
      : `<span class="warn-text">${esc(t('card.port808Off'))}</span>`}</dd>
    ${openUrl ? `<dt>${esc(t('card.address'))}</dt><dd><a class="link" href="${esc(openUrl)}" target="_blank" rel="noopener">${esc(openUrl)}</a></dd>` : ''}`;
  card.appendChild(meta);

  const actions = document.createElement('div');
  actions.className = 'card-actions';

  const engineDown = !state.status.windowsEngine.reachable;

  if (version.state === 'running') {
    actions.appendChild(actionButton(t('btn.stop'), () => runAction(target, 'stop'),
      { disabled: busy || engineDown }));
    actions.appendChild(actionButton(t('btn.restart'), () => runAction(target, 'restart'),
      { disabled: busy || engineDown }));
  } else {
    actions.appendChild(actionButton(version.imageBuilt ? t('btn.start') : t('btn.buildStart'),
      () => {
        if (version.imageBuilt) return runAction(target, 'up');
        return runAction(target, 'build', t('confirm.build', version.year));
      },
      { disabled: busy || engineDown, className: 'btn-primary' }));
  }

  actions.appendChild(actionButton(t('btn.rebuild'), () => runAction(target, 'build',
    t('confirm.rebuild', version.year)),
    { disabled: busy || engineDown, title: 'docker compose up -d --build' }));

  if (version.state !== 'absent' && version.state !== 'unknown') {
    actions.appendChild(actionButton(t('btn.remove'), () => runAction(target, 'down',
      t('confirm.remove', version.year, version.dataDir)),
      { disabled: busy || engineDown, className: 'btn-danger' }));
  }

  if (openUrl) {
    actions.appendChild(actionButton(t('btn.open'), () => window.open(openUrl, '_blank', 'noopener')));
  }

  card.appendChild(actions);
  return card;
}

function pickOpenUrl(version) {
  if (version.state !== 'running') return null;
  const proxy = state.status.proxy;
  if (proxy.enabled && proxy.state === 'running' && version.enabled) return version.proxyUrl;
  return version.directUrl;
}

function renderProxyCard() {
  const proxy = state.status.proxy;
  const busy = state.busy.has('proxy') || isJobRunningFor('proxy');
  const engineDown = !state.status.proxyEngine.reachable;

  const card = document.createElement('div');
  card.className = `card proxy${proxy.enabled ? '' : ' disabled'}`;

  let stateKey = proxy.state;
  let stateLabel = t(`state.${stateKey}`);
  if (stateKey === 'running' && state.healthLoaded && !state.health.proxy) {
    stateKey = 'starting';
    stateLabel = t('state.runningNoWeb');
  }

  card.innerHTML = `
    <div class="card-head">
      <div class="card-title">${esc(t('card.proxyTitle'))}</div>
      <span class="badge ${esc(stateKey)}"><span class="dot"></span>${esc(stateLabel)}</span>
    </div>
    <dl class="card-meta">
      <dt>${esc(t('card.state'))}</dt><dd>${esc(proxy.statusText)}</dd>
      <dt>${esc(t('card.port'))}</dt><dd>${esc(proxy.port)}</dd>
      <dt></dt><dd>${esc(t('card.proxyPurpose'))}</dd>
    </dl>`;

  const actions = document.createElement('div');
  actions.className = 'card-actions';

  if (proxy.state === 'running') {
    actions.appendChild(actionButton(t('btn.stop'), () => runAction('proxy', 'stop'), { disabled: busy || engineDown }));
    actions.appendChild(actionButton(t('btn.restart'), () => runAction('proxy', 'restart'), { disabled: busy || engineDown }));
  } else {
    actions.appendChild(actionButton(t('btn.start'), () => runAction('proxy', 'up'),
      { disabled: busy || engineDown, className: 'btn-primary' }));
  }
  if (proxy.state !== 'absent' && proxy.state !== 'unknown') {
    actions.appendChild(actionButton(t('btn.remove'), () => runAction('proxy', 'down',
      t('confirm.removeProxy')), { disabled: busy || engineDown, className: 'btn-danger' }));
  }
  if (proxy.state === 'running') {
    actions.appendChild(actionButton(t('btn.open'), () => window.open(proxy.url, '_blank', 'noopener')));
  }

  card.appendChild(actions);
  return card;
}

function isJobRunningFor(target) {
  if (!state.status || !state.runningJobs) return false;
  return state.runningJobs.some((job) => job.target === target);
}

function renderCards() {
  if (!state.status) return;
  const host = $('cards');
  host.innerHTML = '';
  state.status.versions.forEach((version) => host.appendChild(renderVersionCard(version)));
  host.appendChild(renderProxyCard());
}

function renderFooter() {
  $('foot-info').textContent = state.panel ? t('foot.project', state.panel.repoRoot) : '';
}

function renderJobs(jobs) {
  const host = $('jobs');
  host.innerHTML = '';
  jobs.slice(0, 8).forEach((job) => {
    const row = document.createElement('button');
    row.type = 'button';
    row.className = `job-row${job.id === state.activeJobId ? ' active' : ''}`;

    let mark = '⏳';
    if (job.finishedAt) {
      if (job.finishedReason === 'cancelled') mark = '⛔';
      else if (job.exitCode === 0) mark = '✔';
      else if (job.exitCode === null || job.exitCode === undefined) mark = '•';
      else mark = '✖';
    }

    row.innerHTML = `<span>${mark}</span>
      <span class="job-title">${esc(job.title)}</span>
      <span class="job-time">${esc(job.startedAtText || '')}</span>`;
    row.onclick = () => {
      state.activeJobId = job.id;
      state.logOffset = 0;
      $('log').textContent = '';
      pollLog();
      if (!job.finishedAt && !state.logTimer) state.logTimer = setInterval(pollLog, 1000);
      renderJobs(jobs);
    };
    host.appendChild(row);
  });
}

/* -------------------------------------------------------------- refresh -- */

async function refreshStatus() {
  try {
    const data = await api('/api/status');
    state.status = data.status;
    state.runningJobs = data.runningJobs || [];
    state.panel = data.panel;
    renderEngines();
    renderCards();
    renderFooter();
  } catch (err) {
    $('engines').innerHTML = '';
    $('engines').appendChild(pill(err.message, 'bad'));
  }
}

async function refreshHealth() {
  if (!state.status) return;
  try {
    const data = await api('/api/health');
    state.health = data.health;
    state.healthLoaded = true;
    renderCards();
  } catch (err) { /* health is advisory only */ }
}

async function refreshJobs() {
  try {
    const data = await api('/api/jobs');
    renderJobs(data.jobs || []);
  } catch (err) { /* ignore */ }
}

/* ------------------------------------------------------------- settings -- */

async function openSettings() {
  try {
    const data = await api('/api/config');
    // Never open an unpopulated form: a blank dialog looks like real settings
    // and saving it would look like the user cleared everything.
    if (!data.config || !data.config.proxy || !Array.isArray(data.config.versions)) {
      throw new Error(t('settings.unexpected'));
    }
    state.config = data.config;
    state.contexts = Array.isArray(data.contexts) ? data.contexts : [];
    state.engines = data.engines || null;
    fillSettings();
    $('settings-modal').hidden = false;
  } catch (err) {
    alertBox(err.message, 'error', 9000);
  }
}

function fillSettings() {
  const config = state.config;

  const host = $('settings-versions');
  host.innerHTML = '';
  config.versions.forEach((version, index) => {
    const row = document.createElement('div');
    row.className = 'settings-row';
    row.innerHTML = `
      <label class="check">
        <input type="checkbox" data-field="enabled" data-index="${index}" ${version.enabled ? 'checked' : ''}>
        <span>RS ${esc(version.year)}</span>
      </label>
      <label><span>${esc(t('settings.port'))}</span>
        <input type="number" min="1" max="65535" data-field="hostPort" data-index="${index}" value="${esc(version.hostPort)}">
      </label>
      <label><span>${esc(t('settings.dataDir'))}</span>
        <input type="text" data-field="dataDir" data-index="${index}" value="${esc(version.dataDir)}">
      </label>
      <label class="check" title="${esc(t('settings.port808Hint'))}">
        <input type="checkbox" data-field="revitClients" data-index="${index}" ${version.revitClients ? 'checked' : ''}>
        <span>${esc(t('settings.port808'))}</span>
      </label>`;
    host.appendChild(row);
  });

  $('proxy-enabled').checked = !!config.proxy.enabled;
  $('proxy-port').value = config.proxy.port;
  $('proxy-image').value = config.proxy.image;
  $('windows-context').value = config.windowsContext;
  $('proxy-context').value = config.proxyContext || '';
  $('compose-project').value = config.composeProject;
  $('windows-host').value = config.windowsHost || '';
  $('proxy-host').value = config.proxyHost || '';
  const engines = state.engines;
  $('windows-host').placeholder = engines ? t('settings.detected', engines.windows.detectedHost) : '';
  $('proxy-host').placeholder = engines ? t('settings.detected', engines.proxy.detectedHost) : '';
  $('remote-name').value = '';
  $('remote-endpoint').value = '';
  $('panel-port').value = config.panelPort;
  $('auto-open').checked = !!config.autoOpenBrowser;

  $('context-list').innerHTML = state.contexts
    .map((name) => `<option value="${esc(name)}"></option>`).join('');

  $('settings-errors').hidden = true;
  $('settings-note').textContent = '';
}

function collectSettings() {
  const config = JSON.parse(JSON.stringify(state.config));

  $('settings-versions').querySelectorAll('[data-field]').forEach((input) => {
    const version = config.versions[Number(input.dataset.index)];
    const field = input.dataset.field;
    if (field === 'enabled') version.enabled = input.checked;
    else if (field === 'revitClients') version.revitClients = input.checked;
    else if (field === 'hostPort') version.hostPort = Number(input.value);
    else version.dataDir = input.value.trim();
  });

  config.proxy.enabled = $('proxy-enabled').checked;
  config.proxy.port = Number($('proxy-port').value);
  config.proxy.image = $('proxy-image').value.trim();
  config.windowsContext = $('windows-context').value.trim();
  config.proxyContext = $('proxy-context').value.trim();
  config.composeProject = $('compose-project').value.trim();
  config.windowsHost = $('windows-host').value.trim();
  config.proxyHost = $('proxy-host').value.trim();
  config.panelPort = Number($('panel-port').value);
  config.autoOpenBrowser = $('auto-open').checked;
  return config;
}

function showSettingsErrors(messages) {
  const errorsBox = $('settings-errors');
  errorsBox.hidden = false;
  errorsBox.innerHTML = `<ul>${messages.map((message) => `<li>${esc(message)}</li>`).join('')}</ul>`;
}

async function saveSettings() {
  if (!state.config) {
    showSettingsErrors([t('settings.notLoaded')]);
    return;
  }
  try {
    const data = await api('/api/config', { method: 'POST', body: collectSettings() });
    if (!data.ok) {
      showSettingsErrors(data.errors || [t('settings.saveFailed')]);
      return;
    }
    state.config = data.config;
    $('settings-modal').hidden = true;
    clearAlerts();
    (data.notes || []).forEach((note) => alertBox(note, 'info', 12000));
    alertBox(t('settings.saved'), 'success', 6000);
    refreshStatus();
  } catch (err) {
    showSettingsErrors([err.message]);
  }
}

async function addContext() {
  const name = $('remote-name').value.trim();
  const endpoint = $('remote-endpoint').value.trim();
  try {
    const data = await api('/api/context', { method: 'POST', body: { name, endpoint } });
    $('settings-errors').hidden = true;
    state.contexts = Array.isArray(data.contexts) ? data.contexts : state.contexts;
    $('context-list').innerHTML = state.contexts
      .map((contextName) => `<option value="${esc(contextName)}"></option>`).join('');
    $('remote-name').value = '';
    $('remote-endpoint').value = '';
    $('settings-note').textContent = t('settings.contextAdded', name);
  } catch (err) {
    showSettingsErrors([err.message]);
  }
}

/* ----------------------------------------------------------------- wire -- */

$('btn-start-all').onclick = () => runAction('all', 'up');
$('btn-stop-all').onclick = () => runAction('all', 'stop', t('confirm.stopAll'));
$('btn-settings').onclick = openSettings;
$('btn-close-settings').onclick = () => { $('settings-modal').hidden = true; };
$('btn-cancel-settings').onclick = () => { $('settings-modal').hidden = true; };
$('btn-save-settings').onclick = saveSettings;
$('btn-add-context').onclick = addContext;
$('btn-clear-log').onclick = () => { $('log').textContent = ''; };

$('btn-cancel-job').onclick = async () => {
  if (!state.activeJobId) return;
  if (!window.confirm(t('confirm.cancelJob'))) return;
  try {
    await api('/api/job/cancel', { method: 'POST', body: { id: state.activeJobId } });
  } catch (err) {
    alertBox(err.message, 'error', 9000);
  }
};

$('btn-shutdown').onclick = async () => {
  if (!window.confirm(t('confirm.shutdown'))) return;
  try { await api('/api/shutdown', { method: 'POST', body: {} }); } catch (err) { /* expected */ }
  clearAlerts();
  alertBox(t('shutdown.done'), 'info');
  if (state.statusTimer) clearInterval(state.statusTimer);
  if (state.healthTimer) clearInterval(state.healthTimer);
  stopLogPolling();
};

$('settings-modal').addEventListener('click', (event) => {
  if (event.target === $('settings-modal')) $('settings-modal').hidden = true;
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && !$('settings-modal').hidden) $('settings-modal').hidden = true;
});

// Stop polling while the tab is hidden so a backgrounded panel is not
// hammering docker every three seconds.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    if (state.statusTimer) { clearInterval(state.statusTimer); state.statusTimer = null; }
    if (state.healthTimer) { clearInterval(state.healthTimer); state.healthTimer = null; }
  } else {
    startPolling();
    refreshStatus();
  }
});

function startPolling() {
  if (!state.statusTimer) state.statusTimer = setInterval(refreshStatus, 3000);
  if (!state.healthTimer) {
    state.healthTimer = setInterval(() => { refreshHealth(); refreshJobs(); }, 15000);
  }
}

// The texts come first: every render below needs them.
initLanguage().then(() => {
  refreshStatus().then(refreshHealth);
  refreshJobs();
  startPolling();
});
