/* Tailscaled WebUI v3.0 — clean rebuild.
   One exec per poll, single state object, event delegation. */

'use strict';

/* ===== helpers ===== */
var $ = function (id) { return document.getElementById(id); };
var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return '&#' + c.charCodeAt(0) + ';'; }); };
var ip4 = function (p) { return (p && p.TailscaleIPs && p.TailscaleIPs[0]) || ''; };

/* ===== environment ===== */
var ENV = 'export PATH=/data/adb/tailscale/bin:/data/adb/tailscale/scripts:/data/adb/magisk:/data/adb/ksu/bin:/system/bin:$PATH; export HOME=/data/adb/tailscale; ';
var SERVICE = '/data/adb/tailscale/scripts/tailscaled.service';
var MODPROP = '/data/adb/modules/magisk-tailscaled/module.prop';
var LOGFILE = '/data/adb/tailscale/run/tailscaled.log';
var GITHUB = 'https://github.com/TheWildJames/Wild_Tailscale';
var UPDATE_JSON = GITHUB + '/raw/main/update.json';

/* ===== mock bridge (?mock=1) ===== */
var isMock = location.search.indexOf('mock') !== -1;
if (isMock) {
  var MOCK = {
    BackendState: 'Running', Health: [],
    Self: { HostName: 'pixel8', OS: 'android', TailscaleIPs: ['100.64.0.1', 'fd7a:115c:a1e0::1'] },
    Peer: {
      a: { HostName: 'desktop', TailscaleIPs: ['100.64.0.2'], Online: true },
      b: { HostName: 'vps-exit', TailscaleIPs: ['100.64.0.3'], Online: true, ExitNode: true }
    }
  };
  var MOCK_PREFS = { CorpDNS: true, RouteAll: false, AdvertiseRoutes: [], ExitNodeAllowLANAccess: false, ShieldsUp: false, RunSSH: false, ExitNodeID: '' };
  window.ksu = {
    exec: function (cmd, opts, cb) {
      var out = '';
      if (cmd.indexOf('@@M2') !== -1) out = '@@M2\n1.104.2\n@@M3\n' + JSON.stringify(MOCK) + '\n@@M4\n' + JSON.stringify(MOCK_PREFS) + '\n@@M5\nOK';
      else if (/version=.*module.prop/.test(cmd)) out = 'version=v9.9.9\n';
      else if (/versionCode=.*module.prop/.test(cmd)) out = '99900\n';
      else if (/NOBOOT/.test(cmd)) out = 'OK\n';
      else if (/tailscale login/.test(cmd)) out = 'https://login.tailscale.com/a/mock123\n';
      else if (/tail /.test(cmd)) out = 'mock log line 1\nmock log line 2\n';
      else out = 'RC=0\n';
      setTimeout(function () { window[cb](0, out, ''); }, 50);
    },
    toast: function () {}
  };
}

/* ===== exec wrapper ===== */
var cbN = 0, pollVersion = '';
function exec(cmd, timeoutMs) {
  timeoutMs = timeoutMs || 20000;
  return new Promise(function (resolve) {
    if (typeof ksu === 'undefined' || !ksu.exec) { resolve({ errno: -1, stdout: '', stderr: 'no bridge' }); return; }
    var settled = false, timer = null, name = '__cb' + (++cbN);
    function done(r) { if (settled) return; settled = true; if (timer) clearTimeout(timer); resolve(r); }
    window[name] = function (errno, stdout, stderr) {
      try { delete window[name]; } catch (e) { window[name] = undefined; }
      done({ errno: errno || 0, stdout: stdout || '', stderr: stderr || '' });
    };
    timer = setTimeout(function () { try { delete window[name]; } catch (e) {} done({ errno: -1, stdout: '', stderr: 'timeout' }); }, timeoutMs);
    try { ksu.exec(cmd, '{}', name); }
    catch (e) { try { delete window[name]; } catch (e2) {} done({ errno: -1, stdout: '', stderr: String(e) }); }
  });
}

/* ===== snackbar ===== */
var snackTimer = null;
function snack(msg) {
  $('snackbar-text').textContent = msg;
  $('snackbar').hidden = false;
  if (snackTimer) clearTimeout(snackTimer);
  snackTimer = setTimeout(function () { $('snackbar').hidden = true; }, 3000);
}

/* ===== single state object ===== */
var S = {
  status: null, prefs: null,
  daemonUp: false, busy: false, busyMsg: '',
  bootOn: true, loginUrl: '', hostnameSet: false
};
function isRunning() { return S.status && S.status.BackendState === 'Running'; }
function needsLogin() { return S.daemonUp && S.status && (S.status.BackendState === 'NeedsLogin' || S.status.BackendState === 'NoState'); }

/* ===== DOM helpers ===== */
function setText(id, s) { var el = $(id); if (el && el.textContent !== s) el.textContent = s; }
function setHidden(id, h) { var el = $(id); if (el && el.hidden !== !!h) el.hidden = !!h; }
function setSwitch(id, on) { var el = $(id); if (!el) return; if (on) el.setAttribute('selected', ''); else el.removeAttribute('selected'); }

/* ===== poll — one exec, @@M markers ===== */
function poll() {
  var cmd = ENV +
    'echo @@M2; tailscale version 2>/dev/null | head -n 1; ' +
    'echo @@M3; tailscale status --json 2>/dev/null; ' +
    'echo @@M4; tailscale debug prefs --json 2>/dev/null; ' +
    'echo @@M5; [ -e /data/adb/tailscale/NOBOOT ] && echo NB || echo OK; ' +
    'echo @@M6';
  return exec(cmd, 20000).then(function (r) {
    var out = String(r.stdout);
    function between(a, b) {
      var i = out.indexOf('@@' + a), j = out.indexOf('@@' + b);
      if (i < 0) return '';
      return (j >= 0 ? out.slice(i + a.length + 3, j) : out.slice(i + a.length + 3)).trim();
    }
    var ver = between('M2', 'M3');
    var statusStr = between('M3', 'M4');
    var prefsStr = between('M4', 'M5');
    var bootStr = between('M5', 'M6');

    if (ver) { pollVersion = ver; }
    try { S.status = statusStr ? JSON.parse(statusStr) : null; } catch (e) { S.status = null; }
    S.daemonUp = !!S.status;
    try { S.prefs = prefsStr ? JSON.parse(prefsStr) : null; } catch (e) { S.prefs = null; }
    S.bootOn = bootStr !== 'NB';

    render();
  }).catch(function () { render(); });
}

/* ===== adaptive poll loop ===== */
var lastAction = 0, pollTimer = null;
function schedulePoll(delay) {
  if (pollTimer) clearTimeout(pollTimer);
  pollTimer = setTimeout(function () {
    pollTimer = null;
    if (document.visibilityState !== 'visible') { schedulePoll(2000); return; }
    poll().then(function () {
      schedulePoll(Date.now() - lastAction < 30000 ? 4000 : 15000);
    });
  }, delay);
}
function bump() { lastAction = Date.now(); }

/* ===== render ===== */
var peersSig = '', exitSig = '';
function render() {
  var st = S.status, on = isRunning(), login = needsLogin();

  /* status dot */
  $('status-dot').className = 'status-dot ' + (S.busy ? 'wait' : on ? 'on' : 'off');

  /* status text */
  if (S.busy) { setText('status-state', S.busyMsg); setText('status-sub', ''); }
  else if (!S.daemonUp) { setText('status-state', 'Stopped'); setText('status-sub', 'tailscaled is not running'); }
  else if (on) { setText('status-state', 'Connected'); setText('status-sub', S.bootOn ? 'Auto-reconnects on boot' : ''); }
  else if (login) { setText('status-state', 'Not logged in'); setText('status-sub', 'Tap Log in to authenticate'); }
  else { setText('status-state', 'Not connected'); setText('status-sub', 'Tap Connect to join your tailnet'); }
  setHidden('status-spinner', !S.busy);

  /* action button */
  var btn = $('action-btn');
  if (S.busy) { btn.textContent = S.busyMsg || 'Working…'; btn.disabled = true; }
  else if (login) { btn.textContent = 'Log in'; btn.disabled = false; }
  else if (on) { btn.textContent = 'Disconnect'; btn.disabled = false; }
  else { btn.textContent = 'Connect'; btn.disabled = false; }

  /* login card */
  if (login && st && st.AuthURL) S.loginUrl = String(st.AuthURL);
  if (!login && !S.busy) S.loginUrl = '';
  setHidden('login-card', !S.loginUrl);
  if (S.loginUrl) setText('login-url', S.loginUrl);

  /* health */
  var health = st && st.Health && st.Health.length ? st.Health : null;
  setHidden('health-card', !health);
  if (health) $('health-list').innerHTML = health.map(function (h) { return '<div class="health-item">' + esc(h) + '</div>'; }).join('');

  /* info card */
  var s = st && st.Self;
  setHidden('info-card', !(on && s));
  if (on && s) {
    setText('kv-ip4', (s.TailscaleIPs && s.TailscaleIPs[0]) || '—');
    setText('kv-ip6', (s.TailscaleIPs && s.TailscaleIPs[1]) || '—');
    setText('kv-exit', st.ExitNodeStatus ? ((st.ExitNodeStatus.TailscaleIPs && st.ExitNodeStatus.TailscaleIPs[0]) || 'in use') : 'none');
    setText('kv-host', s.HostName || '—');
    setText('kv-version', pollVersion || '—');
  }

  /* devices */
  var showPeers = on && st && st.Peer && Object.keys(st.Peer).length > 0;
  setHidden('devices-card', !showPeers);
  if (showPeers) {
    var peers = Object.keys(st.Peer).map(function (k) { return st.Peer[k]; });
    peers.sort(function (a, b) { return (b.Online === true) - (a.Online === true) || String(a.HostName).localeCompare(String(b.HostName)); });
    var sig = peers.map(function (p) { return [p.HostName || '', p.Online ? 1 : 0, ip4(p), p.ExitNode ? 1 : 0].join('|'); }).join(';');
    if (sig !== peersSig) {
      peersSig = sig;
      $('peers-list').innerHTML = peers.map(function (p) {
        return '<div class="peer-row">' +
          '<div class="peer-dot' + (p.Online ? ' on' : '') + '"></div>' +
          '<div class="peer-name">' + esc(p.HostName || '?') + (p.ExitNode ? ' <small>exit</small>' : '') + '</div>' +
          '<span class="peer-ip">' + esc(ip4(p)) + '</span>' +
          '<button class="ip-copy" data-ip="' + esc(ip4(p)) + '" title="Copy IP">\u29c9</button></div>';
      }).join('');
    }
  } else { peersSig = ''; }

  /* exit node picker */
  var exitPeers = (on && st && st.Peer) ? Object.keys(st.Peer).map(function (k) { return st.Peer[k]; }).filter(function (p) { return p.ExitNode; }) : [];
  exitPeers.sort(function (a, b) { return (b.Online === true) - (a.Online === true) || String(a.HostName).localeCompare(String(b.HostName)); });
  setHidden('exit-card', !(on && exitPeers.length));
  if (on && exitPeers.length) {
    var activeExitIp = (st.ExitNodeStatus && st.ExitNodeStatus.TailscaleIPs && st.ExitNodeStatus.TailscaleIPs[0]) || '';
    var rows = '<div class="exit-row" data-exit="">' +
      '<div class="peer-dot' + (activeExitIp ? '' : ' on') + '"></div>' +
      '<div class="exit-name">None<small>Direct connection</small></div>' +
      '<span class="exit-check">' + (activeExitIp ? '' : '✓') + '</span></div>';
    rows += exitPeers.map(function (p) {
      var ip = ip4(p), active = activeExitIp && ip === activeExitIp;
      return '<div class="exit-row" data-exit="' + esc(ip) + '">' +
        '<div class="peer-dot' + (p.Online ? ' on' : '') + '"></div>' +
        '<div class="exit-name">' + esc(p.HostName || '?') + '<small>' + esc(ip) + (p.Online ? '' : ' · offline') + '</small></div>' +
        '<span class="exit-check">' + (active ? '✓' : '') + '</span></div>';
    }).join('');
    if (rows !== exitSig) { exitSig = rows; $('exit-list').innerHTML = rows; }
  } else { exitSig = ''; }

  /* settings switches */
  setSwitch('sw-boot', S.bootOn);

  /* hostname */
  if (on && !S.hostnameSet) setHostname();

  /* live status in module.prop description — status only, no marketing text */
  maybeUpdateDesc();
}

/* ===== module.prop status writer =====
   Mirrors the VPN state into the manager's module list so you can see
   ⚡/⚠/⛔ at a glance without opening the WebUI. Writes only on change. */
var lastDescKey = null;
var DESC_MSG = {
  stopped: '\u26d4 Stopped',
  connected: '\u26a1 VPN connected',
  login: '\u26a0 Login required',
  starting: '\u23f3 Starting',
  disconnected: '\u26d4 VPN disconnected',
  machineauth: '\u23f3 Machine auth'
};
function maybeUpdateDesc() {
  if (isMock) return;
  var st = S.status, key;
  if (!S.daemonUp) key = 'stopped';
  else if (st && st.BackendState === 'Running') key = 'connected';
  else if (st && (st.BackendState === 'NeedsLogin' || st.BackendState === 'NoState')) key = 'login';
  else if (st && st.BackendState === 'Starting') key = 'starting';
  else if (st && st.BackendState === 'Stopped') key = 'disconnected';
  else if (st && st.BackendState === 'NeedsMachineAuth') key = 'machineauth';
  else return;
  if (key === lastDescKey) return;
  lastDescKey = key;
  var T = new Date().toTimeString().slice(0, 5);
  var desc = '[ \u23f2 ' + T + ' | ' + DESC_MSG[key] + ' ]';
  exec(ENV + 'sed -i "s/^description=.*/description=' + desc + '/" ' + MODPROP + ' 2>/dev/null; echo OK', 8000);
}

/* ===== doctor ===== */
function runDoctor() {
  setHidden('log-overlay', false);
  setText('log-content', 'Running diagnostics…\n');
  if (logTimer) { clearInterval(logTimer); logTimer = null; }
  var cmd = ENV +
    'echo "=== tailscale status ==="; ' +
    'tailscale status 2>&1; ' +
    'echo; echo "=== tailscale netcheck ==="; ' +
    'timeout 15 tailscale netcheck 2>&1; ' +
    'echo; echo "=== tailscale version ==="; ' +
    'tailscale version 2>&1; ' +
    'echo; echo "=== daemon check ==="; ' +
    'timeout 5 tailscale status --json 2>/dev/null | head -c 200; echo; ' +
    'echo; echo "=== done ==="';
  exec(cmd, 30000).then(function (r) {
    setText('log-content', r.stdout || 'Doctor failed — no output');
  });
}

/* ===== actions ===== */
function setBusy(msg) { S.busy = true; S.busyMsg = msg; bump(); render(); }
function clearBusy() { S.busy = false; S.busyMsg = ''; render(); }

function doAction() {
  if (S.busy) return;
  if (needsLogin()) { doLogin(); return; }
  if (isRunning()) { doDisconnect(); return; }
  doConnect();
}

function doConnect() {
  setBusy('Starting…');
  /* Build tailscale up flags from stored prefs so settings persist
     across reboots — bare `tailscale up` resets to defaults. */
  var prefs = S.prefs || {};
  var dns = prefs.CorpDNS !== false ? 'true' : 'false';
  var routes = prefs.RouteAll === true ? 'true' : 'false';
  var exitAdv = (String(prefs.AdvertiseRoutes || '').indexOf('0.0.0.0/0') !== -1) ? 'true' : 'false';
  var lan = prefs.ExitNodeAllowLANAccess === true ? 'true' : 'false';
  var shields = prefs.ShieldsUp === true ? 'true' : 'false';
  var ssh = prefs.RunSSH === true ? 'true' : 'false';
  var upCmd = 'tailscale up --accept-dns=' + dns +
    ' --accept-routes=' + routes +
    ' --advertise-exit-node=' + exitAdv +
    ' --exit-node-allow-lan-access=' + lan +
    ' --shields-up=' + shields +
    ' --ssh=' + ssh;
  setTimeout(function () {
    exec(ENV + 'EXIT=$(cat /data/adb/tailscale/exitnode 2>/dev/null); ' + SERVICE + ' start >/dev/null 2>&1; R=$?; sleep 2; timeout 15 ' + upCmd + ' ${EXIT:+--exit-node=$EXIT} >/dev/null 2>&1 || true; echo RC=$R', 60000)
      .then(function (r) {
        clearBusy();
        snack(/RC=0/.test(r.stdout) ? 'Connected' : 'Start failed');
        poll();
      });
  }, 0);
}

function doDisconnect() {
  setBusy('Stopping…');
  setTimeout(function () {
    exec(ENV + 'tailscale down >/dev/null 2>&1; echo RC=$?', 30000)
      .then(function (r) {
        clearBusy();
        snack(/RC=0/.test(r.stdout) ? 'Disconnected' : 'Stop failed');
        poll();
      });
  }, 0);
}

function doLogin() {
  if (S.status && S.status.AuthURL) { S.loginUrl = String(S.status.AuthURL); render(); return; }
  setBusy('Generating URL…');
  setHidden('login-card', false);
  setText('login-url', 'Generating login URL…');
  setTimeout(function () {
    exec(ENV + "timeout 15 tailscale login 2>&1 | grep -oE 'https://[^ ]+' | head -1", 25000)
      .then(function (r) {
        S.busy = false; S.busyMsg = '';
        S.loginUrl = String(r.stdout).trim();
        if (S.loginUrl) { render(); snack('Login URL ready'); }
        else { setText('login-url', 'Could not get URL'); snack('Login failed'); }
      });
  }, 0);
}

function confirmLogout() {
  setHidden('logout-overlay', true);
  setBusy('Logging out…');
  setTimeout(function () {
    exec(ENV + 'tailscale logout >/dev/null 2>&1; echo RC=$?', 30000)
      .then(function (r) {
        clearBusy();
        snack(/RC=0/.test(r.stdout) ? 'Logged out' : 'Logout failed');
        poll();
      });
  }, 0);
}

function doRestart() {
  setBusy('Restarting…');
  setTimeout(function () {
    exec(ENV + SERVICE + ' restart >/dev/null 2>&1; echo RC=$?', 30000)
      .then(function (r) {
        clearBusy();
        snack(/RC=0/.test(r.stdout) ? 'Restarted' : 'Restart failed');
        poll();
      });
  }, 0);
}

function toggleBoot() {
  if (S.busy) return;
  setBusy('Saving…');
  setTimeout(function () {
    var cmd = S.bootOn ? ENV + 'touch /data/adb/tailscale/NOBOOT; echo OK' : ENV + 'rm -f /data/adb/tailscale/NOBOOT; echo OK';
    exec(cmd, 8000).then(function () {
      S.bootOn = !S.bootOn;
      clearBusy();
      snack(S.bootOn ? 'Will start on boot' : "Won't start on boot");
    });
  }, 0);
}

/* ===== exit node ===== */
function setExitNode(ip) {
  if (S.busy) return;
  if (!S.daemonUp) { snack('Start Tailscale first'); return; }
  setBusy('Applying…');
  setTimeout(function () {
    var persist = ip ? 'echo -n "' + ip + '" > /data/adb/tailscale/exitnode 2>/dev/null; ' : 'rm -f /data/adb/tailscale/exitnode 2>/dev/null; ';
    exec(ENV + 'tailscale set --exit-node=' + ip + ' 2>&1; R=$?; ' + persist + 'echo RC=$R', 20000)
      .then(function (r) {
        clearBusy();
        var rc = (String(r.stdout).match(/RC=(\d+)/) || [])[1];
        snack(rc === '0' ? (ip ? 'Exit node: ' + ip : 'Direct connection') : 'Failed (RC=' + rc + ')');
        poll();
      });
  }, 0);
}

/* ===== hostname ===== */
function setHostname() {
  exec(ENV + 'getprop ro.product.model 2>/dev/null', 8000).then(function (r) {
    var model = String(r.stdout).trim();
    if (!model || model === 'localhost') return;
    exec(ENV + 'tailscale set --hostname=' + model + ' 2>&1; echo RC=$?', 15000).then(function (r) {
      if (/RC=0/.test(r.stdout)) S.hostnameSet = true;
    });
  });
}

/* ===== logs ===== */
var logTimer = null;
function openLogs() {
  setHidden('log-overlay', false);
  loadLogs();
  logTimer = setInterval(loadLogs, 5000);
}
function closeLogs() {
  setHidden('log-overlay', true);
  if (logTimer) { clearInterval(logTimer); logTimer = null; }
}
function loadLogs() {
  exec(ENV + 'tail -n 200 ' + LOGFILE + " 2>/dev/null || echo '(no daemon log)'", 12000)
    .then(function (r) { setText('log-content', r.stdout.trim() || '(empty)'); });
}
function copyLogs() {
  var text = $('log-content').textContent || '';
  try { navigator.clipboard.writeText(text).then(function () { snack('Logs copied'); }); }
  catch (e) { exec(ENV + "echo '" + text.replace(/'/g, "'\\''") + "' | toybox tr -d '\n' | wl clipboard 2>/dev/null || echo '" + text.slice(0, 200) + "'"); snack('Copy — check snackbar'); }
}
function shareLogs() {
  var text = $('log-content').textContent || '';
  /* Write to temp file and share via Android intent */
  exec(ENV + "cat > /data/local/tmp/ts-logs.txt << 'LOGEOF'\n" + text + "\nLOGEOF\n" +
       'am start -a android.intent.action.SEND -t text/plain --eu android.intent.extra.TEXT "$(cat /data/local/tmp/ts-logs.txt)" 2>/dev/null || ' +
       'am start -a android.intent.action.VIEW -d "file:///data/local/tmp/ts-logs.txt" -t text/plain 2>/dev/null; echo SHARED', 15000)
    .then(function () { snack('Sharing logs…'); });
}

/* ===== update check ===== */
var currentVersionCode = '';
function checkUpdate() {
  setText('update-current', 'Checking…');
  fetch(UPDATE_JSON, { cache: 'no-cache' })
    .then(function (r) { return r.text(); })
    .then(function (text) {
      setText('update-current', '');
      try {
        var info = JSON.parse(text);
        var remote = parseInt(info.versionCode, 10) || 0;
        var local = parseInt(currentVersionCode, 10) || 0;
        if (remote > local) {
          setText('update-current', 'v' + (info.version || '?') + ' available');
          snack('Update available: ' + info.version + ' — opening releases');
          setTimeout(function () { exec(ENV + 'am start -a android.intent.action.VIEW -d ' + GITHUB + '/releases >/dev/null 2>&1'); }, 1000);
        } else {
          setText('update-current', 'Up to date (v' + (info.version || '?') + ')');
          snack('You are on the latest version');
        }
      } catch (e) {
        snack('Failed to parse update info');
      }
    })
    .catch(function () {
      setText('update-current', '');
      snack("Can't reach GitHub — opening releases in browser");
      exec(ENV + 'am start -a android.intent.action.VIEW -d ' + GITHUB + '/releases >/dev/null 2>&1');
    });
}

/* ===== navigation ===== */
function navTo(page) {
  document.querySelectorAll('.page').forEach(function (p) {
    if (p.dataset.page === page) p.setAttribute('data-active', ''); else p.removeAttribute('data-active');
  });
  document.querySelectorAll('.nav-item').forEach(function (n) {
    if (n.dataset.page === page) n.setAttribute('data-active', ''); else n.removeAttribute('data-active');
  });
}

/* ===== wire events ===== */
function wire() {
  document.querySelectorAll('.nav-item').forEach(function (n) {
    n.addEventListener('click', function () { navTo(n.dataset.page); });
  });

  $('action-btn').addEventListener('click', doAction);
  $('open-url-btn').addEventListener('click', function () {
    exec(ENV + 'am start -a android.intent.action.VIEW -d "' + S.loginUrl + '" >/dev/null 2>&1');
    snack('Opening browser…');
  });
  $('copy-url-btn').addEventListener('click', function () {
    try { navigator.clipboard.writeText(S.loginUrl).then(function () { snack('Copied'); }); }
    catch (e) { snack(S.loginUrl); }
  });

  $('peers-list').addEventListener('click', function (e) {
    var btn = e.target.closest('.ip-copy');
    if (!btn) return;
    var ip = btn.getAttribute('data-ip');
    if (!ip) return;
    try { navigator.clipboard.writeText(ip).then(function () { snack('Copied ' + ip); }); }
    catch (err) { snack(ip); }
  });
  $('row-boot').addEventListener('click', toggleBoot);
  $('exit-list').addEventListener('click', function (e) {
    var row = e.target.closest('.exit-row');
    if (!row) return;
    setExitNode(row.getAttribute('data-exit') || '');
  });
  var bootSw = $('sw-boot');
  if (bootSw) bootSw.addEventListener('change', function () {
    if (S.busy) { render(); return; }
    toggleBoot();
  });

  $('row-restart').addEventListener('click', doRestart);
  $('row-logout').addEventListener('click', function () { setHidden('logout-overlay', false); });
  $('logout-cancel-btn').addEventListener('click', function () { setHidden('logout-overlay', true); });
  $('logout-confirm-btn').addEventListener('click', confirmLogout);

  $('row-logs').addEventListener('click', openLogs);
  $('row-doctor').addEventListener('click', runDoctor);
  $('log-close-btn').addEventListener('click', closeLogs);
  $('log-copy-btn').addEventListener('click', copyLogs);
  $('log-share-btn').addEventListener('click', shareLogs);
  $('row-update').addEventListener('click', checkUpdate);
  $('row-github').addEventListener('click', function () {
    exec(ENV + 'am start -a android.intent.action.VIEW -d ' + GITHUB + ' >/dev/null 2>&1');
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') { closeLogs(); setHidden('logout-overlay', true); }
  });

  window.addEventListener('pageshow', function () { schedulePoll(200); });
  window.addEventListener('focus', function () { schedulePoll(200); });
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') schedulePoll(200); });
}

/* ===== boot ===== */
function boot() {
  wire();
  exec(ENV + 'grep "^version=" ' + MODPROP + ' 2>/dev/null | head -1 | cut -d= -f2', 8000).then(function (r) {
    var v = r.stdout.trim();
    if (v) setText('version-text', v);
  });
  exec(ENV + 'grep "^versionCode=" ' + MODPROP + ' 2>/dev/null | head -1 | cut -d= -f2', 8000).then(function (r) {
    currentVersionCode = r.stdout.trim();
    if (currentVersionCode) setText('update-current', 'Current: v' + currentVersionCode.replace(/^0+/, ''));
  });
  schedulePoll(0);
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
else boot();
