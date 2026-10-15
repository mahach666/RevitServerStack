'use strict';

/* Revit Server Stack control panel, front-end.
   No dependencies: the panel must run from a plain file server with no
   network access and no npm install. */

const TOKEN = document.querySelector('meta[name="panel-token"]').content;

const state = {
  status: null,
  health: { versions: {}, proxy: false },
  healthLoaded: false,
  config: null,
  contexts: [],
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

const STATE_LABEL = {
  running: 'Работает',
  starting: 'Запускается',
  stopped: 'Остановлен',
  absent: 'Не создан',
  error: 'Ошибка',
  unknown: 'Неизвестно',
};

const $ = (id) => document.getElementById(id);
const esc = (value) => String(value === undefined || value === null ? '' : value)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

/* ------------------------------------------------------------------ api -- */

async function api(path, options = {}) {
  const init = {
    method: options.method || 'GET',
    headers: { 'X-Panel-Token': TOKEN },
  };
  if (options.body !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(options.body);
  }

  let response;
  try {
    response = await fetch(path, init);
  } catch (err) {
    throw new Error('Панель недоступна — окно PowerShell закрыто?');
  }

  let data = null;
  try {
    data = await response.json();
  } catch (err) {
    throw new Error(`Некорректный ответ панели (HTTP ${response.status}).`);
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
  close.setAttribute('aria-label', 'Скрыть');
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
      alertBox(result.error || 'Не удалось выполнить операцию.', 'error', 9000);
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
  let note;
  if (data.finishedReason === 'cancelled') {
    note = '\n— операция прервана пользователем —\n';
  } else if (data.finishedReason === 'detached') {
    note = '\n— процесс завершился, пока панель была перезапущена; код возврата неизвестен, см. вывод выше —\n';
  } else if (data.exitCode === 0) {
    note = '\n— готово (код возврата 0) —\n';
  } else if (data.exitCode === null || data.exitCode === undefined) {
    note = '\n— завершено, код возврата неизвестен —\n';
  } else {
    note = `\n— ошибка: код возврата ${data.exitCode} —\n`;
  }
  const logEl = $('log');
  // The Windows engine does not create a missing bind source, and the daemon's own wording is easy to misread.
  if (data.exitCode && logEl.textContent.indexOf('bind source path does not exist') >= 0) {
    note += 'Папка моделей не найдена на машине, где работает Docker. Docker для Windows сам её не создаёт: создайте папку и запустите версию снова.\n';
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
      host.appendChild(pill('Docker Desktop не запущен', 'bad', 'запустить',
        () => runAction('engine', 'start-desktop')));
    }
  }

  // For an engine on another machine the pill names that machine, and the
  // buttons that drive Docker Desktop make no sense.
  const win = status.windowsEngine;
  const winName = win.remote ? `${win.host}, ${win.context}` : win.context;
  if (win.reachable) {
    host.appendChild(pill(`Windows-движок (${winName})`, 'ok'));
  } else {
    host.appendChild(pill(`Windows-движок недоступен (${winName}): ${win.error || ''}`, 'bad',
      win.remote ? null : 'переключить', win.remote ? null : () => runAction('engine', 'switch-windows')));
  }
  if (win.hostInvalid) {
    host.appendChild(pill('Адрес Windows-сервера не определён, укажите его в настройках', 'warn'));
  }

  const proxyEngine = status.proxyEngine;
  const proxyContextName = proxyEngine.context || 'текущий';
  const proxyName = proxyEngine.remote ? `${proxyEngine.host}, ${proxyContextName}` : proxyContextName;
  if (proxyEngine.reachable) {
    host.appendChild(pill(`Linux-движок (${proxyName})`, 'ok'));
  } else {
    host.appendChild(pill(`Linux-движок недоступен (${proxyName})`, 'warn'));
  }
  if (proxyEngine.hostInvalid) {
    host.appendChild(pill('Адрес Linux-движка не определён, укажите его в настройках', 'warn'));
  }

  host.appendChild(pill(`Обновлено ${status.checkedAt}`, 'idle', 'обновить', refreshStatus));
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
  let stateLabel = STATE_LABEL[stateKey] || stateKey;
  // "Container up" is not "server ready": IIS inside needs a while to answer.
  // Only say so once a probe has actually run, or a freshly loaded page would
  // slander a perfectly healthy server.
  if (stateKey === 'running' && state.healthLoaded && health && !health.ready) {
    stateKey = 'starting';
    stateLabel = 'Работает, веб ещё не отвечает';
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
  meta.innerHTML = `
    <dt>Состояние</dt><dd>${esc(version.statusText)}</dd>
    <dt>Порт</dt><dd>${esc(version.hostPort)}</dd>
    <dt>Образ</dt><dd>${version.imageBuilt
      ? esc(version.imageName)
      : '<span class="muted">не собран — первая сборка качает ~5 ГБ (20–45 мин)</span>'}</dd>
    <dt>Модели</dt><dd>${esc(version.dataDir)}${state.status.windowsEngine.remote
      ? (version.dataDirOk
        ? ' <span class="muted">(на сервере)</span>'
        : ' <span class="warn-text">(нужен полный путь на сервере, например D:\\RevitServerData\\rs' + esc(version.year) + ')</span>')
      : ''}</dd>
    <dt>Revit</dt><dd>${version.revitClients
      ? 'порт 808 опубликован — клиенты Revit смогут подключиться'
      : '<span class="warn-text">порт 808 не опубликован — Revit подключиться не сможет (включите в настройках)</span>'}</dd>
    ${openUrl ? `<dt>Адрес</dt><dd><a class="link" href="${esc(openUrl)}" target="_blank" rel="noopener">${esc(openUrl)}</a></dd>` : ''}`;
  card.appendChild(meta);

  const actions = document.createElement('div');
  actions.className = 'card-actions';

  const engineDown = !state.status.windowsEngine.reachable;

  if (version.state === 'running') {
    actions.appendChild(actionButton('Остановить', () => runAction(target, 'stop'),
      { disabled: busy || engineDown }));
    actions.appendChild(actionButton('Перезапустить', () => runAction(target, 'restart'),
      { disabled: busy || engineDown }));
  } else {
    actions.appendChild(actionButton(version.imageBuilt ? 'Запустить' : 'Собрать и запустить',
      () => {
        if (version.imageBuilt) return runAction(target, 'up');
        return runAction(target, 'build',
          `Образ Revit Server ${version.year} ещё не собран.\n\nСборка скачает около 5 ГБ и займёт 20–45 минут. Начать?`);
      },
      { disabled: busy || engineDown, className: 'btn-primary' }));
  }

  actions.appendChild(actionButton('Пересобрать', () => runAction(target, 'build',
    `Пересобрать образ Revit Server ${version.year}?\n\nЭто может занять 20–45 минут. Модели в папке с данными не затрагиваются.`),
    { disabled: busy || engineDown, title: 'docker compose up -d --build' }));

  if (version.state !== 'absent' && version.state !== 'unknown') {
    actions.appendChild(actionButton('Удалить контейнер', () => runAction(target, 'down',
      `Удалить контейнер rs${version.year}?\n\nМодели в папке ${version.dataDir} останутся на месте — удаляется только контейнер.`),
      { disabled: busy || engineDown, className: 'btn-danger' }));
  }

  if (openUrl) {
    actions.appendChild(actionButton('Открыть', () => window.open(openUrl, '_blank', 'noopener')));
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
  let stateLabel = STATE_LABEL[stateKey] || stateKey;
  if (stateKey === 'running' && state.healthLoaded && !state.health.proxy) {
    stateKey = 'starting';
    stateLabel = 'Работает, веб ещё не отвечает';
  }

  card.innerHTML = `
    <div class="card-head">
      <div class="card-title">Обратный прокси</div>
      <span class="badge ${esc(stateKey)}"><span class="dot"></span>${esc(stateLabel)}</span>
    </div>
    <dl class="card-meta">
      <dt>Состояние</dt><dd>${esc(proxy.statusText)}</dd>
      <dt>Порт</dt><dd>${esc(proxy.port)}</dd>
      <dt>Назначение</dt><dd>Все версии на одном порту — в Revit можно подключаться по имени компьютера без порта</dd>
    </dl>`;

  const actions = document.createElement('div');
  actions.className = 'card-actions';

  if (proxy.state === 'running') {
    actions.appendChild(actionButton('Остановить', () => runAction('proxy', 'stop'), { disabled: busy || engineDown }));
    actions.appendChild(actionButton('Перезапустить', () => runAction('proxy', 'restart'), { disabled: busy || engineDown }));
  } else {
    actions.appendChild(actionButton('Запустить', () => runAction('proxy', 'up'),
      { disabled: busy || engineDown, className: 'btn-primary' }));
  }
  if (proxy.state !== 'absent' && proxy.state !== 'unknown') {
    actions.appendChild(actionButton('Удалить контейнер', () => runAction('proxy', 'down',
      'Удалить контейнер revit-proxy?'), { disabled: busy || engineDown, className: 'btn-danger' }));
  }
  if (proxy.state === 'running') {
    actions.appendChild(actionButton('Открыть', () => window.open(proxy.url, '_blank', 'noopener')));
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
    $('foot-info').textContent = `Проект: ${data.panel.repoRoot}`;
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
      throw new Error('Панель вернула настройки в неожиданном виде. Перезапустите Start-Panel.cmd.');
    }
    state.config = data.config;
    state.contexts = data.contexts || [];
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
      <label>Порт
        <input type="number" min="1" max="65535" data-field="hostPort" data-index="${index}" value="${esc(version.hostPort)}">
      </label>
      <label>Папка с моделями
        <input type="text" data-field="dataDir" data-index="${index}" value="${esc(version.dataDir)}">
      </label>
      <label class="check" title="Публикует порт 808 (net.tcp). Без него Revit не подключится. Порт фиксирован в протоколе, поэтому его может занимать только одна версия.">
        <input type="checkbox" data-field="revitClients" data-index="${index}" ${version.revitClients ? 'checked' : ''}>
        <span>порт&nbsp;808 для&nbsp;Revit</span>
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
  $('windows-host').placeholder = engines ? `по контексту: ${engines.windows.detectedHost}` : '';
  $('proxy-host').placeholder = engines ? `по контексту: ${engines.proxy.detectedHost}` : '';
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

async function saveSettings() {
  const errorsBox = $('settings-errors');
  if (!state.config) {
    errorsBox.hidden = false;
    errorsBox.innerHTML = '<ul><li>Настройки не загружены — сохранять нечего. Закройте окно и откройте его заново.</li></ul>';
    return;
  }
  try {
    const data = await api('/api/config', { method: 'POST', body: collectSettings() });
    if (!data.ok) {
      errorsBox.hidden = false;
      errorsBox.innerHTML = `<ul>${(data.errors || ['Не удалось сохранить настройки.'])
        .map((e) => `<li>${esc(e)}</li>`).join('')}</ul>`;
      return;
    }
    state.config = data.config;
    $('settings-modal').hidden = true;
    clearAlerts();
    (data.notes || []).forEach((note) => alertBox(note, 'info', 12000));
    alertBox('Настройки сохранены, compose-файлы перегенерированы.', 'success', 6000);
    refreshStatus();
  } catch (err) {
    errorsBox.hidden = false;
    errorsBox.innerHTML = `<ul><li>${esc(err.message)}</li></ul>`;
  }
}

async function addContext() {
  const errorsBox = $('settings-errors');
  const name = $('remote-name').value.trim();
  const endpoint = $('remote-endpoint').value.trim();
  try {
    const data = await api('/api/context', { method: 'POST', body: { name, endpoint } });
    errorsBox.hidden = true;
    state.contexts = data.contexts || state.contexts;
    $('context-list').innerHTML = state.contexts
      .map((contextName) => `<option value="${esc(contextName)}"></option>`).join('');
    $('remote-name').value = '';
    $('remote-endpoint').value = '';
    $('settings-note').textContent = `Контекст «${name}» добавлен. Выберите его в поле «Контекст Windows-контейнеров».`;
  } catch (err) {
    errorsBox.hidden = false;
    errorsBox.innerHTML = `<ul><li>${esc(err.message)}</li></ul>`;
  }
}

/* ----------------------------------------------------------------- wire -- */

$('btn-start-all').onclick = () => runAction('all', 'up');
$('btn-stop-all').onclick = () => runAction('all', 'stop',
  'Остановить все версии Revit Server и прокси?');
$('btn-settings').onclick = openSettings;
$('btn-close-settings').onclick = () => { $('settings-modal').hidden = true; };
$('btn-cancel-settings').onclick = () => { $('settings-modal').hidden = true; };
$('btn-save-settings').onclick = saveSettings;
$('btn-add-context').onclick = addContext;
$('btn-clear-log').onclick = () => { $('log').textContent = ''; };

$('btn-cancel-job').onclick = async () => {
  if (!state.activeJobId) return;
  if (!window.confirm('Прервать выполняющуюся операцию?')) return;
  try {
    await api('/api/job/cancel', { method: 'POST', body: { id: state.activeJobId } });
  } catch (err) {
    alertBox(err.message, 'error', 9000);
  }
};

$('btn-shutdown').onclick = async () => {
  if (!window.confirm('Закрыть панель управления?\n\nЗапущенные контейнеры продолжат работать.')) return;
  try { await api('/api/shutdown', { method: 'POST', body: {} }); } catch (err) { /* expected */ }
  clearAlerts();
  alertBox('Панель остановлена. Эту вкладку можно закрыть.', 'info');
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

refreshStatus().then(refreshHealth);
refreshJobs();
startPolling();
