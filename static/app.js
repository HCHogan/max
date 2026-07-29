// max admin panel.  No build step: this file is served verbatim and
// runs against the JSON API in Max.Admin.  Alpine drives the DOM,
// uPlot draws the two time series.
//
// Auth: the API needs a bearer token when one is configured, but a
// <script> tag can't carry a header — so the static assets are public
// (they hold no data) and the token lives in localStorage, added to
// every fetch here.  A 401 drops back to the token gate.

function admin() {
  return {
    tabs: [
      { id: 'overview', name: '概览' },
      { id: 'groups', name: '群设置' },
      { id: 'memories', name: '记忆' },
      { id: 'perms', name: '权限' },
      { id: 'tasks', name: '任务' },
      { id: 'calls', name: '调用' },
      { id: 'logs', name: '日志' },
    ],
    tab: 'overview',
    needToken: false,
    tokenInput: '',
    gateErr: '',
    err: '',
    clock: '',

    overview: { profiles: [] },
    groups: [],
    memories: [],
    perms: [],
    tasks: [],
    // Column headings double as the per-field labels the mobile card
    // layout puts in front of each value.
    fieldLabel: { debug: 'debug', sticker: '表情', proactive: '主动说话' },
    mem: { scope: 'group', id: '', loaded: false },
    grant: { user_id: '', capability: '', scope_group_id: '', deny: false },
    charts: {},

    logs: [],
    logq: { level: '', domain: '', q: '' },
    domains: [],
    tailing: false,
    tailTimer: null,
    // Which lines are expanded — log entries by sequence number, calls
    // by "c<id>".  Kept out of the entries themselves so a refresh
    // doesn't collapse what you were reading.
    open: {},

    calls: [],
    callq: { source: '', group: '', failed: false },
    callSources: ['turn', 'wrapup', 'intent', 'supplement', 'memx', 'memx-compact', 'caption'],
    // Bodies, fetched per call on first open and kept for the session.
    detail: {},

    // ── plumbing ──────────────────────────────────────────────────

    get token() {
      return localStorage.getItem('max-admin-token') || '';
    },

    async api(path, opts = {}) {
      const headers = Object.assign({}, opts.headers);
      if (this.token) headers['Authorization'] = 'Bearer ' + this.token;
      if (opts.body) headers['Content-Type'] = 'application/json';
      const res = await fetch('/api' + path, Object.assign({}, opts, { headers }));
      if (res.status === 401) {
        this.needToken = true;
        throw new Error('unauthorized');
      }
      const body = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(body.error || res.status + ' ' + res.statusText);
      return body;
    },

    async boot() {
      this.tick();
      setInterval(() => this.tick(), 1000);
      try {
        await this.loadOverview();
      } catch (e) {
        if (e.message === 'unauthorized') return; // gate is showing
        this.err = String(e.message);
      }
      // Deep-link support: #groups etc., so a phone bookmark can land
      // straight on the page you actually check.
      const h = location.hash.slice(1);
      if (this.tabs.some((t) => t.id === h)) this.tab = h;
      this.load(this.tab);
    },

    // The log line carries a live clock — it is the one part of the
    // header that would otherwise be a still photograph of a running
    // system.
    tick() {
      const d = new Date();
      this.clock = [d.getHours(), d.getMinutes(), d.getSeconds()]
        .map((n) => String(n).padStart(2, '0'))
        .join(':');
      if (this.overview.uptime_seconds != null) this.overview.uptime_seconds++;
    },

    saveToken() {
      localStorage.setItem('max-admin-token', this.tokenInput.trim());
      this.gateErr = '';
      this.needToken = false;
      this.tokenInput = '';
      this.boot().catch(() => {
        this.gateErr = 'token 不对';
      });
    },

    go(id) {
      this.tab = id;
      history.replaceState(null, '', '#' + id);
      this.load(id);
    },

    load(id) {
      const fn = {
        overview: () => this.loadCharts(),
        groups: () => this.loadGroups(),
        memories: () => (this.mem.id ? this.loadMemories() : null),
        perms: () => this.loadPerms(),
        tasks: () => this.loadTasks(),
        calls: () => this.loadCalls(),
        logs: () => this.reloadLogs(),
      }[id];
      if (fn) Promise.resolve(fn()).catch((e) => (this.err = String(e.message)));
    },

    // ── loaders ───────────────────────────────────────────────────

    async loadOverview() {
      this.overview = await this.api('/overview');
    },

    async loadGroups() {
      this.groups = await this.api('/groups');
    },

    async loadMemories() {
      if (!this.mem.id) return;
      this.memories = await this.api(
        '/memories?scope=' + this.mem.scope + '&id=' + encodeURIComponent(this.mem.id)
      );
      this.mem.loaded = true;
    },

    async loadPerms() {
      this.perms = await this.api('/permissions');
    },

    async loadTasks() {
      this.tasks = await this.api('/tasks');
    },

    // ── llm calls ─────────────────────────────────────────────────

    async loadCalls() {
      const p = new URLSearchParams();
      if (this.callq.source) p.set('source', this.callq.source);
      if (this.callq.group) p.set('group', this.callq.group);
      if (this.callq.failed) p.set('failed', '1');
      const s = p.toString();
      this.calls = await this.api('/calls' + (s ? '?' + s : ''));
    },

    async openCall(c) {
      const k = 'c' + c.id;
      this.open[k] = !this.open[k];
      if (this.open[k] && !this.detail[c.id]) {
        this.detail[c.id] = await this.api('/calls/' + c.id);
      }
    },

    // A message's text, whichever shape it arrived in: plain content,
    // or the block list a multimodal turn sends (where the image is
    // already a placeholder by the time it reaches the database).
    msgText(m) {
      if (typeof m.content === 'string') return m.content;
      if (Array.isArray(m.content)) {
        return m.content
          .map((b) =>
            b.type === 'text'
              ? b.text
              : '[' + b.type + ' ' + ((b[b.type] && b[b.type].url) || '') + ']'
          )
          .join('\n');
      }
      // Assistant turns carrying tool calls have no content at all.
      return JSON.stringify(m, null, 2);
    },

    pretty(v) {
      return JSON.stringify(v, null, 2);
    },

    fmtMs(ms) {
      return ms >= 1000 ? (ms / 1000).toFixed(1) + 's' : ms + 'ms';
    },

    fmtBytes(n) {
      if (n >= 1048576) return (n / 1048576).toFixed(1) + 'MB';
      if (n >= 1024) return Math.round(n / 1024) + 'KB';
      return n + 'B';
    },

    // ── logs ──────────────────────────────────────────────────────

    logQueryString(after) {
      const p = new URLSearchParams();
      if (this.logq.level) p.set('level', this.logq.level);
      if (this.logq.domain) p.set('domain', this.logq.domain);
      if (this.logq.q) p.set('q', this.logq.q);
      if (after) p.set('after', after);
      const s = p.toString();
      return s ? '?' + s : '';
    },

    // A filter change replaces the view; tailing appends to it.  Two
    // paths because a filter that matches nothing new must still be
    // able to clear what a previous filter left on screen.
    async reloadLogs() {
      const r = await this.api('/logs' + this.logQueryString());
      this.logs = r.entries;
      // The domain picker is built from what has actually been logged
      // rather than a hardcoded list — the set grows with the code and
      // a stale list would quietly hide a subsystem.
      for (const e of r.entries) {
        if (e.domain && !this.domains.includes(e.domain)) this.domains.push(e.domain);
      }
      this.domains.sort();
    },

    async tailOnce() {
      const newest = this.logs.length ? this.logs[0].seq : null;
      const r = await this.api('/logs' + this.logQueryString(newest));
      if (r.entries.length) {
        this.logs = r.entries.concat(this.logs).slice(0, 500);
      }
    },

    tailToggled() {
      clearInterval(this.tailTimer);
      this.tailTimer = null;
      if (!this.tailing) return;
      // Two seconds: fast enough to watch a dispatch unfold, slow
      // enough that a phone left open on this tab isn't a load
      // generator.  Polling rather than a socket because the buffer
      // is a poll-shaped thing already — ask for everything after the
      // sequence number you have.
      this.tailTimer = setInterval(
        () => this.tailOnce().catch((e) => (this.err = String(e.message))),
        2000
      );
    },

    // Log fields render as the same key=value pairs the terminal
    // shows, so a line read here and a line read in journalctl are
    // recognisably the same line.
    kv(data) {
      if (!data || typeof data !== 'object' || Array.isArray(data)) return [];
      return Object.entries(data)
        .sort((a, b) => a[0].localeCompare(b[0]))
        .map(([k, v]) => [k, typeof v === 'string' ? v : JSON.stringify(v)]);
    },

    toggle(seq) {
      this.open[seq] = !this.open[seq];
    },

    fmtTime(s) {
      const d = new Date(s);
      return (
        String(d.getHours()).padStart(2, '0') + ':' +
        String(d.getMinutes()).padStart(2, '0') + ':' +
        String(d.getSeconds()).padStart(2, '0')
      );
    },

    // ── mutations ─────────────────────────────────────────────────

    async patch(g, fields) {
      try {
        const updated = await this.api('/groups/' + g.group_id + '/session', {
          method: 'PATCH',
          body: JSON.stringify(fields),
        });
        Object.assign(g, updated);
      } catch (e) {
        this.err = String(e.message);
        await this.loadGroups(); // the select is now lying; resync
      }
    },

    async delMemory(m) {
      if (!confirm('删掉这条记忆?\n\n' + m.content)) return;
      await this.api('/memories/' + m.id, { method: 'DELETE' });
      this.memories = this.memories.filter((x) => x.id !== m.id);
    },

    async addGrant() {
      const g = this.grant;
      this.perms = await this.api('/permissions', {
        method: 'POST',
        body: JSON.stringify({
          user_id: Number(g.user_id),
          capability: g.capability.trim(),
          scope_group_id: g.scope_group_id ? Number(g.scope_group_id) : null,
          deny: g.deny,
        }),
      });
      this.grant = { user_id: '', capability: '', scope_group_id: '', deny: false };
    },

    async delGrant(p) {
      await this.api('/permissions/' + p.id, { method: 'DELETE' });
      this.perms = this.perms.filter((x) => x.id !== p.id);
    },

    async kill(t) {
      if (!confirm('kill ' + t.id + '?')) return;
      await this.api('/tasks/' + t.id, { method: 'DELETE' });
      await this.loadTasks();
    },

    // ── charts ────────────────────────────────────────────────────

    async loadCharts() {
      const [usage, msgs] = await Promise.all([
        this.api('/usage?days=30'),
        this.api('/stats/messages?days=14'),
      ]);
      const c = palette();

      // Token spend splits by what the tokens were, not by who spent
      // them: prompt vs completion is the axis that decides the bill.
      //
      // They get separate scales because they differ by an order of
      // magnitude — prompt runs ~20k against completion's ~2k, and on
      // one axis completion is a flat line pinned to the floor, which
      // is exactly the number you want to watch for runaway replies.
      this.plot('chart-usage', 'usage', sumByDay(usage, ['prompt_tokens', 'completion_tokens']), [
        { label: 'prompt', stroke: c.info, scale: 'p', fill: fade(c.info) },
        { label: 'completion', stroke: c.warn, scale: 'c' },
      ], { right: 'c' });

      // Messages split by kind, because that is the distinction the
      // prompt itself makes: only `chat` rows reach the model, so a
      // merged line would hide whether the bot is talking or just
      // being operated.
      const m = pivotByDay(msgs, 'kind', 'count');
      const kindColour = { chat: c.info, command: c.dim, debug: c.warn };
      const kindLabel = { chat: '对话', command: '命令', debug: 'debug' };
      this.plot(
        'chart-msgs',
        'msgs',
        m.data,
        m.keys.map((k) => ({
          label: kindLabel[k] || k,
          stroke: kindColour[k] || c.dim,
          fill: k === 'chat' ? fade(c.info) : undefined,
        }))
      );
    },

    // uPlot takes a pixel size, so the chart is rebuilt on resize (and
    // whenever the tab is reopened) against the current container
    // width.  Cheap at this data volume; the redraw is debounced so a
    // dragged window edge doesn't rebuild on every frame.
    //
    // @opts.right names a scale to hang off a second, right-hand axis
    // for series whose magnitude would otherwise flatten them.
    plot(elId, key, data, seriesDefs, opts = {}) {
      const el = document.getElementById(elId);
      if (!el) return;
      if (this.charts[key]) {
        this.charts[key].destroy();
        delete this.charts[key];
      }
      // No series at all is the normal state of a fresh install, and
      // of any window where nothing happened: the message chart builds
      // one series per message kind seen, so an empty range gives it
      // none.  Say so instead of drawing an axis pair around nothing —
      // and note this used to read series[0] and throw, taking the
      // whole overview down with it.
      if (!seriesDefs.length || !data[0] || !data[0].length) {
        el.innerHTML = '';
        const p = document.createElement('p');
        p.className = 'empty';
        p.textContent = '这段时间没有数据。';
        el.appendChild(p);
        return;
      }
      el.innerHTML = '';
      const c = palette();
      const axis = {
        stroke: c.dim,
        grid: { stroke: c.rule, width: 1 },
        ticks: { show: false },
        font: '11px ' + monoStack(),
      };
      const series = seriesDefs.map((s) =>
        Object.assign({ width: 1.75, points: { size: 5, width: 0 } }, s)
      );
      const axes = [
        // Just M/D.  uPlot's default stacks a year row underneath,
        // which is noise for a window that never spans one.
        Object.assign({}, axis, {
          values: (_u, splits) => splits.map((v) => fmtDay(new Date(v * 1000))),
        }),
        Object.assign({}, axis, {
          scale: series[0].scale,
          size: 50,
          values: (_u, splits) => splits.map(compact),
        }),
      ];
      if (opts.right) {
        const rc = series.find((s) => s.scale === opts.right);
        axes.push(
          Object.assign({}, axis, {
            scale: opts.right,
            side: 1,
            size: 50,
            stroke: rc ? rc.stroke : c.dim,
            grid: { show: false },
            values: (_u, splits) => splits.map(compact),
          })
        );
      }
      this.charts[key] = new uPlot(
        {
          width: el.clientWidth,
          height: 210,
          // A vertical rule that snaps to the day under the pointer,
          // with the legend reading out that day's values — the whole
          // point of the chart is "how much on which day", and eyeing
          // a pixel against a gridline doesn't answer it.
          cursor: { y: false, points: { size: 7 } },
          legend: { live: true },
          scales: { x: { time: true } },
          series: [{ value: (_u, v) => (v == null ? '' : fmtDay(new Date(v * 1000))) }].concat(
            series.map((s) =>
              Object.assign({ value: (_u, v) => (v == null ? '—' : v.toLocaleString()) }, s)
            )
          ),
          axes,
        },
        data,
        el
      );
      if (!this._resizeBound) {
        this._resizeBound = true;
        let t;
        addEventListener('resize', () => {
          clearTimeout(t);
          t = setTimeout(() => this.tab === 'overview' && this.loadCharts(), 150);
        });
      }
    },

    // ── formatting ────────────────────────────────────────────────

    // Private chats ride the group pipeline as negative pseudo-groups
    // (chat with user u = group -u); show that rather than a bare
    // minus number nobody can place.
    gname(gid) {
      return gid < 0 ? '私聊 ' + -gid : String(gid);
    },

    fmtUptime(secs) {
      if (secs == null) return '—';
      const d = Math.floor(secs / 86400);
      const h = Math.floor((secs % 86400) / 3600);
      const m = Math.floor((secs % 3600) / 60);
      return d ? d + 'd' + h + 'h' : h ? h + 'h' + m + 'm' : m + 'm';
    },

    fmtDate(s) {
      if (!s) return '';
      const d = new Date(s);
      return (
        fmtDay(d) + ' ' +
        String(d.getHours()).padStart(2, '0') + ':' +
        String(d.getMinutes()).padStart(2, '0')
      );
    },

    // Session overrides are three-state: null means "no override, use
    // the config default", which a checkbox can't say.
    tri(v) {
      return v === null || v === undefined ? 'default' : v ? 'on' : 'off';
    },
    untri(s) {
      return s === 'default' ? null : s === 'on';
    },
  };
}

// ── helpers ──────────────────────────────────────────────────────

// The chart colours are the panel's colours, read back at draw time so
// a light/dark switch repaints correctly instead of baking in whatever
// the scheme was at load.
function palette() {
  const s = getComputedStyle(document.documentElement);
  const v = (n) => s.getPropertyValue(n).trim();
  return { info: v('--info'), warn: v('--warn'), dim: v('--dim'), rule: v('--rule') };
}

function monoStack() {
  return getComputedStyle(document.documentElement).getPropertyValue('--mono').trim();
}

// A wash under the primary line — enough to read the shape at a
// glance, faint enough that the second series stays legible over it.
function fade(colour) {
  return 'color-mix(in srgb, ' + colour + ' 14%, transparent)';
}

function fmtDay(d) {
  return d.getMonth() + 1 + '/' + d.getDate();
}

// 12_400 → "12.4k".  Token counts run long and the axis is narrow.
function compact(n) {
  if (n >= 1e6) return (n / 1e6).toFixed(n % 1e6 ? 1 : 0) + 'm';
  if (n >= 1e3) return (n / 1e3).toFixed(n % 1e3 && n < 1e4 ? 1 : 0) + 'k';
  return String(n);
}

// Column-major [xs, ...ys] with x in unix seconds — uPlot's input
// shape.  Days with no rows simply don't appear; the series stay
// aligned because every y is built from the same sorted day list.
function frame(days, seriesOf) {
  const sorted = [...days.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  return [sorted.map(([d]) => Date.parse(d + 'T00:00:00') / 1000)].concat(seriesOf(sorted));
}

// Sum the named fields per day, collapsing every other dimension.
function sumByDay(rows, fields) {
  const days = new Map();
  for (const r of rows) {
    let acc = days.get(r.day);
    if (!acc) days.set(r.day, (acc = fields.map(() => 0)));
    fields.forEach((f, i) => (acc[i] += r[f] || 0));
  }
  return frame(days, (sorted) => fields.map((_, i) => sorted.map(([, v]) => v[i])));
}

// One series per distinct value of `dim` (e.g. one line per message
// kind), summing `value` per day.  Absent combinations read as 0 so a
// kind that stops appearing draws a floor rather than a gap.
function pivotByDay(rows, dim, value) {
  const keys = [...new Set(rows.map((r) => r[dim]))].sort();
  const days = new Map();
  for (const r of rows) {
    let acc = days.get(r.day);
    if (!acc) days.set(r.day, (acc = Object.fromEntries(keys.map((k) => [k, 0]))));
    acc[r[dim]] += r[value] || 0;
  }
  return { keys, data: frame(days, (sorted) => keys.map((k) => sorted.map(([, v]) => v[k]))) };
}
