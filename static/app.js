// max admin panel.  No build step: this file is served verbatim and
// runs against the JSON API in Max.Admin.  Alpine drives the DOM,
// uPlot draws the time series.
//
// Auth: the API needs a bearer token when one is configured, but a
// <script> tag can't carry a header — so the static assets are public
// (they hold no data) and the token lives in localStorage, added to
// every fetch here.  A 401 drops back to the token gate.

function admin() {
  return {
    // The nav is the README's pipeline diagram folded into a list:
    // the ledger and its projections first, the machinery that runs
    // them below, the knobs last.  The digit is a live keyboard
    // accelerator, not decoration.
    nav: [
      { name: '状态', tabs: [{ id: 'overview', name: '概览', key: '1', icon: 'dashboard' }] },
      { name: '账本', tabs: [
        { id: 'timeline', name: '消息账本', key: '2', icon: 'book' },
        { id: 'context', name: '上下文', key: '3', icon: 'stack-2' },
        { id: 'memories', name: '记忆', key: '4', icon: 'brain' },
      ] },
      { name: '运行', tabs: [
        { id: 'tasks', name: '任务', key: '5', icon: 'activity' },
        { id: 'calls', name: '调用', key: '6', icon: 'api' },
        { id: 'logs', name: '日志', key: '7', icon: 'terminal-2' },
      ] },
      { name: '配置', tabs: [
        { id: 'groups', name: '群设置', key: '8', icon: 'adjustments' },
        { id: 'skills', name: '技能', key: '9', icon: 'sparkles' },
      ] },
    ],
    get tabsFlat() {
      return this.nav.flatMap((g) => g.tabs);
    },
    tab: 'overview',

    // Desktop offcanvas and the mobile sheet are separate states, as
    // in shadcn's useSidebar(): `open` vs `openMobile`.
    sidebarOpen: localStorage.getItem('max-admin-sidebar') !== 'closed',
    mobileOpen: false,
    isMobile: false,

    conversations: [],
    convFilter: '',
    needToken: false,
    tokenInput: '',
    gateErr: '',
    err: '',
    clock: '',

    overview: { profiles: [], effort_levels: [] },
    // 90 days are fetched once and the range picker slices them in the
    // browser, so switching windows is instant and costs the database
    // nothing.  The stat cards read the newest two days out of the same
    // rows rather than asking again.
    usageRows: [],
    msgRows: [],
    ranges: [
      { v: 90, label: '90 天' },
      { v: 30, label: '30 天' },
      { v: 7, label: '7 天' },
    ],
    range: { usage: 30, msgs: 30 },
    // The one conversation the ledger views share.  Set in the rail
    // (or any of the views), remembered across sessions.
    focus: localStorage.getItem('max-admin-focus') || '',
    groups: [],
    memories: [],
    tasks: [],
    quota: null,
    quotaErr: '',
    endpoints: [],
    timeline: {
      group: '',
      loaded: false,
      conversation_id: null,
      title: null,
      endpoints: [],
      work_summary: {},
      items: [],
      latest_conversation_seq: null,
      timeline_revision: 0,
    },
    timelineMedia: {},
    timelineAbort: null,
    ctx: {
      loaded: false,
      status: { summary: {}, conversations: [], maintenance_leases: [], capture_workers: [] },
      captures: [],
      compartments: [],
      plans: [],
      embeddings: { corpora: [] },
      integrity: null,
      recallQuery: '',
      recall: null,
      memoryId: '',
      memory: null,
    },
    // The context view is six tables of the same pipeline seen from
    // six angles; the DataTable's tab bar is what keeps it one page
    // rather than a scroll.
    // Outbound health and upstream health share one DataTable on the
    // overview: both answer "is the plumbing open".
    ovTab: 'endpoints',
    ctxTab: 'coverage',
    ctxTabs: [
      { v: 'coverage', label: '覆盖' },
      { v: 'capture', label: 'capture' },
      { v: 'compartments', label: '分格' },
      { v: 'plans', label: '计划' },
      { v: 'embedding', label: 'embedding' },
      { v: 'probe', label: '诊断' },
    ],
    // Column headings double as the per-field labels the mobile card
    // layout puts in front of each value.
    fieldLabel: { debug: 'debug', sticker: '表情', proactive: '主动说话' },
    mem: { scope: 'group', id: '', loaded: false },
    memPage: 0,
    memPageSize: 20,
    charts: {},

    personaEdit: null,
    personaDraft: '',
    get personaEditGroup() {
      return this.groups.find((g) => g.group_id === this.personaEdit) || null;
    },

    skills: [],
    skillq: { group: '' },
    skillOpenId: null,
    skillDraft: {},
    skillNew: null,
    get skillOpenRow() {
      return this.skills.find((s) => s.id === this.skillOpenId) || null;
    },

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
    callsDone: false,
    callSources: ['turn', 'wrapup', 'intent', 'supplement', 'historian', 'memory-dream', 'memx', 'memx-compact', 'memx-dream', 'caption'],
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
      // Relative, so the panel works wherever it is mounted: at the
      // server's root, or under a reverse-proxy prefix that strips
      // itself (`location /max/ { proxy_pass http://…:7700/; }`).
      // Every asset href is relative for the same reason — which is
      // why the mount point must keep its trailing slash.
      const res = await fetch('api' + path, Object.assign({}, opts, { headers }));
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

      // useIsMobile(): shadcn's MOBILE_BREAKPOINT is 768.
      const mq = matchMedia('(max-width: 767px)');
      this.isMobile = mq.matches;
      mq.addEventListener('change', (e) => {
        this.isMobile = e.matches;
        this.closeMobile();
      });

      try {
        await this.loadOverview();
      } catch (e) {
        if (e.message === 'unauthorized') return; // gate is showing
        this.err = String(e.message);
      }
      this.loadConversations().catch(() => {});
      // Deep-link support: #groups etc., so a phone bookmark can land
      // straight on the page you actually check.
      const h = location.hash.slice(1);
      if (this.tabsFlat.some((t) => t.id === h)) this.tab = h;
      this.load(this.tab);
    },

    // The rail carries a live clock — it is the one part of the frame
    // that would otherwise be a still photograph of a running system.
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

    // ── the shell ─────────────────────────────────────────────────

    icon(name, cls) {
      const i = window.ICONS[name];
      if (!i) return '';
      const paint = i.fill
        ? 'fill="currentColor" stroke="none"'
        : 'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
      return '<svg class="icon ' + (cls || '') + '" viewBox="0 0 24 24" ' + paint + '>' + i.d + '</svg>';
    },

    currentTab() {
      return this.tabsFlat.find((t) => t.id === this.tab) || { name: 'max' };
    },

    toggleSidebar() {
      if (this.isMobile) {
        this.mobileOpen = !this.mobileOpen;
        document.body.style.overflow = this.mobileOpen ? 'hidden' : '';
      } else {
        this.sidebarOpen = !this.sidebarOpen;
        localStorage.setItem('max-admin-sidebar', this.sidebarOpen ? 'open' : 'closed');
      }
    },

    closeMobile() {
      this.mobileOpen = false;
      document.body.style.overflow = '';
    },

    // What a nav item is carrying that you might want to know before
    // you click it: work in flight, and work that is stuck.
    badge(id) {
      const h = this.overview.health || {};
      switch (id) {
        case 'tasks':
          return { n: this.overview.running_tasks || 0, tone: 'busy' };
        case 'logs':
          return { n: h.warn_logs || 0, tone: 'busy' };
        case 'timeline':
          return { n: (h.failed_deliveries || 0) + (h.media_parked || 0), tone: 'bad' };
        case 'context':
          return { n: h.failed_captures || 0, tone: 'bad' };
        default:
          return { n: 0, tone: '' };
      }
    },

    accountName() {
      const a = (this.overview.accounts || [])[0];
      if (!a) return 'max';
      return a.display_name || a.platform + ' ' + a.native_account_id;
    },

    refresh() {
      this.loadOverview().catch((e) => (this.err = String(e.message)));
      this.loadConversations().catch(() => {});
      this.load(this.tab);
    },

    forgetToken() {
      localStorage.removeItem('max-admin-token');
      location.reload();
    },

    // ── the conversation switcher ─────────────────────────────────

    async loadConversations() {
      this.conversations = await this.api('/conversations');
    },

    // The switcher opens whether or not the endpoint answers: a bot
    // still running a binary from before /api/conversations existed
    // gets an empty list and the numeric fallback, not an error.
    reloadConversations() {
      this.loadConversations().catch(() => {});
    },

    convName(c) {
      if (c.title) return c.title;
      if (c.kind === 'direct' || (c.legacy_group_id != null && c.legacy_group_id < 0)) {
        return '私聊 ' + Math.abs(c.legacy_group_id ?? c.conversation_id);
      }
      return '群 ' + (c.legacy_group_id ?? c.conversation_id);
    },

    focusTitle() {
      if (!this.focus) return '选择会话';
      const c = this.conversations.find((x) => String(x.legacy_group_id) === String(this.focus));
      return c ? this.convName(c) : this.gname(this.focus);
    },

    filteredConversations() {
      const q = this.convFilter.trim().toLowerCase();
      if (!q) return this.conversations;
      return this.conversations.filter(
        (c) =>
          this.convName(c).toLowerCase().includes(q) ||
          String(c.legacy_group_id).includes(q)
      );
    },

    pickConversation(c) {
      this.focus = c ? String(c.legacy_group_id ?? '') : '';
      this.convFilter = '';
      if (this.$refs.switcher) this.$refs.switcher.open = false;
      this.focusChanged();
      // A picked conversation means you want to look at it — but "all
      // conversations" is a window only the context view has, and the
      // ledger has nothing to show without one.
      if (!c) {
        if (this.tab === 'timeline') this.go('context');
        return;
      }
      if (!['timeline', 'context', 'memories'].includes(this.tab)) this.go('timeline');
    },

    // Digits switch views, `/` lands in the visible view's filter,
    // Escape leaves an input.  Nothing fires while you type.
    keys(e) {
      // SIDEBAR_KEYBOARD_SHORTCUT = "b".
      if (e.key === 'b' && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        this.toggleSidebar();
        return;
      }
      if (e.key === 'Escape' && this.mobileOpen) {
        this.closeMobile();
        return;
      }
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const t = e.target;
      if (t && ['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName)) {
        if (e.key === 'Escape') t.blur();
        return;
      }
      if (e.key >= '1' && e.key <= '9') {
        const dest = this.tabsFlat[Number(e.key) - 1];
        if (dest) {
          e.preventDefault();
          this.go(dest.id);
        }
      } else if (e.key === '/') {
        const section = [...document.querySelectorAll('main section')].find(
          (s) => s.offsetParent !== null
        );
        const input = section && (section.querySelector('input.search') || section.querySelector('input'));
        if (input) {
          e.preventDefault();
          input.focus();
        }
      }
    },

    go(id) {
      if (id !== 'timeline') this.stopTimelineTail();
      this.tab = id;
      history.replaceState(null, '', '#' + id);
      this.load(id);
    },

    load(id) {
      const fn = {
        overview: () => this.loadOverviewView(),
        groups: () => this.loadGroups(),
        timeline: () => (this.focus ? this.loadTimeline(false) : null),
        context: () => this.loadContext(),
        memories: () => {
          if (!this.mem.id && this.mem.scope === 'group' && this.focus) this.mem.id = this.focus;
          return this.mem.id ? this.loadMemories() : null;
        },
        tasks: () => this.loadTasks(),
        calls: () => this.loadCalls(),
        logs: () => this.reloadLogs(),
        skills: () => this.loadSkills(),
      }[id];
      if (fn) Promise.resolve(fn()).catch((e) => (this.err = String(e.message)));
    },

    // A rail change re-reads whichever ledger view is on screen; a
    // change made inside a view leaves the reload to that view's own
    // submit, so Enter doesn't fetch twice.
    focusChanged(fromView = false) {
      localStorage.setItem('max-admin-focus', this.focus);
      if (fromView) return;
      if (this.tab === 'timeline' && this.focus) this.load('timeline');
      else if (this.tab === 'context') this.load('context');
    },

    // ── loaders ───────────────────────────────────────────────────

    async loadOverview() {
      this.overview = await this.api('/overview');
    },

    async loadOverviewView() {
      await Promise.all([this.loadCharts(), this.loadQuota(), this.loadEndpoints()]);
    },

    async loadQuota() {
      try {
        this.quota = await this.api('/quota');
        this.quotaErr = '';
      } catch (e) {
        if (e.message === 'unauthorized') throw e;
        // 502 when cli-proxy is down: keep the section, show the why.
        this.quota = null;
        this.quotaErr = String(e.message);
      }
    },

    async loadEndpoints() {
      this.endpoints = await this.api('/platforms/status');
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
      this.memPage = 0;
    },

    async loadTasks() {
      this.tasks = await this.api('/tasks');
    },

    // ── canonical timeline ────────────────────────────────────────

    async loadTimeline(tail = false) {
      if (!this.focus) return;
      if (!tail) this.stopTimelineTail();
      const group = this.focus;
      const after = tail ? this.timeline.latest_conversation_seq : null;
      const query = new URLSearchParams({ limit: '200' });
      if (after != null) query.set('after', String(after));
      const page = await this.api(
        '/platforms/timeline/' + encodeURIComponent(group) + '?' + query.toString()
      );
      if (group !== this.focus) return;
      if (tail) {
        if (page.items.length) this.timeline.items.push(...page.items);
        Object.assign(this.timeline, {
          conversation_id: page.conversation_id,
          title: page.title,
          endpoints: page.endpoints,
          work_summary: page.work_summary,
          latest_conversation_seq: page.latest_conversation_seq,
          timeline_revision: page.timeline_revision,
          loaded: true,
        });
      } else {
        this.releaseTimelineMedia();
        Object.assign(this.timeline, page, { group, loaded: true });
      }
      await this.loadTimelineMedia(page.items);
      if (!tail) this.startTimelineTail(group);
    },

    stopTimelineTail() {
      if (this.timelineAbort) this.timelineAbort.abort();
      this.timelineAbort = null;
    },

    startTimelineTail(group) {
      this.stopTimelineTail();
      const controller = new AbortController();
      this.timelineAbort = controller;
      this.tailTimeline(group, controller).catch((e) => {
        if (e.name !== 'AbortError') this.err = String(e.message);
      });
    },

    async tailTimeline(group, controller) {
      while (this.tab === 'timeline' && this.focus === group && !controller.signal.aborted) {
        const after = this.timeline.latest_conversation_seq == null ? 0 : this.timeline.latest_conversation_seq;
        const query = new URLSearchParams({
          after: String(after),
          revision: String(this.timeline.timeline_revision || 0),
          limit: '200',
        });
        try {
          const page = await this.api(
            '/platforms/timeline/' + encodeURIComponent(group) + '/wait?' + query.toString(),
            { signal: controller.signal }
          );
          if (controller.signal.aborted || this.tab !== 'timeline' || this.focus !== group) return;
          if (page.replace) {
            this.releaseTimelineMedia();
            Object.assign(this.timeline, page, { group, loaded: true });
          } else {
            if (page.items.length) this.timeline.items.push(...page.items);
            Object.assign(this.timeline, {
              conversation_id: page.conversation_id,
              title: page.title,
              endpoints: page.endpoints,
              work_summary: page.work_summary,
              latest_conversation_seq: page.latest_conversation_seq,
              timeline_revision: page.timeline_revision,
              loaded: true,
            });
          }
          await this.loadTimelineMedia(page.items);
        } catch (e) {
          if (controller.signal.aborted || e.name === 'AbortError' || e.message === 'unauthorized') return;
          this.err = String(e.message);
          await new Promise((resolve) => setTimeout(resolve, 1000));
        }
      }
    },

    // Blob media sits behind the same bearer token as everything
    // else, so an <img src> can't reach it: fetch with the header,
    // hold an object URL, release on replace.
    async loadTimelineMedia(items) {
      const urls = [];
      for (const item of items) {
        for (const node of item.body.nodes || []) {
          if (node.thumbnail && node.thumbnail.startsWith('/api/blobs/')) urls.push(node.thumbnail);
        }
      }
      await Promise.all(
        [...new Set(urls)].map(async (url) => {
          if (this.timelineMedia[url]) return;
          const headers = this.token ? { Authorization: 'Bearer ' + this.token } : {};
          const response = await fetch(url, { headers });
          if (!response.ok) throw new Error('media ' + response.status);
          this.timelineMedia[url] = URL.createObjectURL(await response.blob());
        })
      );
    },

    releaseTimelineMedia() {
      Object.values(this.timelineMedia).forEach((url) => URL.revokeObjectURL(url));
      this.timelineMedia = {};
    },

    timelineMediaSrc(node) {
      if (!node.thumbnail) return '';
      return this.timelineMedia[node.thumbnail] || (node.thumbnail.startsWith('/api/') ? '' : node.thumbnail);
    },

    nodeSummary(node) {
      switch (node.type) {
        case 'text': return node.text;
        case 'mention': {
          const ids = (node.identities || []).map((i) => i.platform + ':' + i.native_user_id).join(', ');
          return '@' + node.display + (ids ? ' (' + ids + ')' : '');
        }
        case 'emote': return '[emote ' + node.platform + ':' + node.native_id + (node.name ? ' ' + node.name : '') + ']';
        case 'media': return '[' + node.kind + (node.description ? ': ' + node.description : node.name ? ': ' + node.name : '') + ']';
        case 'card': return '[card: ' + [node.tag, node.title, node.url].filter(Boolean).join(' · ') + ']';
        case 'forward': return '[forward → ' + (node.children || []).map((id) => '#' + id).join(', ') + ']';
        case 'unsupported': return '[unsupported ' + node.source + ': ' + node.description + ']';
        default: return '[' + node.type + ']';
      }
    },

    // A tab badge counts the rows behind the tab, the way the block's
    // does.  What is *wrong* in there is the rail badge's job — one
    // number per meaning, or neither can be read at a glance.
    ctxCount(v) {
      const n = {
        coverage: this.ctx.status.conversations,
        capture: this.ctx.captures,
        compartments: this.ctx.compartments,
        plans: this.ctx.plans,
        embedding: this.ctx.embeddings.corpora,
      }[v];
      return n ? n.length : 0;
    },

    // Memories are the one list that grows without bound — a group
    // that has been running a year has hundreds — so it is the one
    // that pages.
    memPageCount() {
      return Math.max(1, Math.ceil(this.memories.length / this.memPageSize));
    },
    memRows() {
      const start = this.memPage * this.memPageSize;
      return this.memories.slice(start, start + this.memPageSize);
    },

    // ── unbounded context / memory operations ───────────────────

    contextQuery(extra = {}) {
      const p = new URLSearchParams(extra);
      if (this.focus) p.set('group', this.focus);
      const query = p.toString();
      return query ? '?' + query : '';
    },

    async loadContext() {
      const suffix = this.contextQuery();
      const [status, captures, compartments, plans, embeddings, integrity] = await Promise.all([
        this.api('/context/status' + suffix),
        this.api('/context/captures' + this.contextQuery({ limit: '100' })),
        this.api('/context/compartments' + this.contextQuery({ limit: '100' })),
        this.api('/context/plans' + this.contextQuery({ limit: '50' })),
        this.api('/context/embeddings' + suffix),
        this.api('/context/integrity' + suffix),
      ]);
      Object.assign(this.ctx, { status, captures, compartments, plans, embeddings, integrity, loaded: true });
    },

    async contextRecall() {
      if (!this.focus || !this.ctx.recallQuery.trim()) return;
      this.ctx.recall = await this.api(
        '/context/recall' + this.contextQuery({ q: this.ctx.recallQuery.trim(), limit: '10' })
      );
    },

    async contextMemory() {
      if (!this.ctx.memoryId) return;
      this.ctx.memory = await this.api('/context/memories/' + encodeURIComponent(this.ctx.memoryId));
    },

    async contextRebuild(compartmentId = null) {
      if (!this.focus) return;
      const what = compartmentId == null ? '这个会话的全部 active compartments' : 'compartment #' + compartmentId;
      if (!confirm('重新构建 ' + what + '?\n\n旧版本会继续服务,直到新版本完整发布。')) return;
      await this.api('/context/rebuild', {
        method: 'POST',
        body: JSON.stringify({
          conversation_id: Number(this.focus),
          compartment_id: compartmentId,
        }),
      });
      await this.loadContext();
    },

    async contextReindex(corpora) {
      if (!this.focus) return;
      if (!confirm('清空这个会话的 ' + corpora.join(', ') + ' vectors 并交给 embedding worker 重建?')) return;
      await this.api('/context/reindex', {
        method: 'POST',
        body: JSON.stringify({ conversation_id: Number(this.focus), corpora }),
      });
      await this.loadContext();
    },

    // ── llm calls ─────────────────────────────────────────────────

    async loadCalls(more = false) {
      const p = new URLSearchParams();
      if (this.callq.source) p.set('source', this.callq.source);
      if (this.callq.group) p.set('group', this.callq.group);
      if (this.callq.failed) p.set('failed', '1');
      if (more && this.calls.length) p.set('before', String(this.calls[this.calls.length - 1].id));
      const s = p.toString();
      const page = await this.api('/calls' + (s ? '?' + s : ''));
      if (more) this.calls.push(...page);
      else this.calls = page;
      this.callsDone = page.length < 50;
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

    openPersona(g) {
      this.personaEdit = g.group_id;
      this.personaDraft = g.persona || '';
    },

    async savePersona() {
      const g = this.personaEditGroup;
      if (!g) return;
      const text = this.personaDraft.trim();
      await this.patch(g, { persona: text ? this.personaDraft : null });
      this.personaEdit = null;
    },

    // The API archives rather than deletes — versions and provenance
    // survive, which is the memory system's whole contract.
    async archiveMemory(m) {
      if (!confirm('归档这条记忆?(记录和出处保留,只是不再生效)\n\n' + m.content)) return;
      try {
        await this.api('/memories/' + m.id, { method: 'DELETE' });
        this.memories = this.memories.filter((x) => x.id !== m.id);
      } catch (e) {
        this.err = String(e.message);
      }
    },

    async kill(t) {
      if (!confirm('kill ' + t.id + '?')) return;
      await this.api('/tasks/' + encodeURIComponent(t.id), { method: 'DELETE' });
      await this.loadTasks();
    },

    // ── skills ────────────────────────────────────────────────────

    async loadSkills() {
      const s = this.skillq.group ? '?group=' + encodeURIComponent(this.skillq.group) : '';
      this.skills = await this.api('/skills' + s);
      this.skillOpenId = null;
    },

    openSkill(s) {
      if (this.skillOpenId === s.id) {
        this.skillOpenId = null;
        return;
      }
      this.skillOpenId = s.id;
      if (!s.builtin) {
        this.skillDraft = {
          name: s.name,
          description: s.description,
          group_id: s.group_id == null ? '' : String(s.group_id),
          enabled: s.enabled,
          body: s.body,
        };
      }
    },

    skillPayload(d) {
      return {
        name: d.name.trim(),
        group_id: String(d.group_id).trim() === '' ? null : Number(d.group_id),
        description: d.description.trim(),
        body: d.body,
        enabled: !!d.enabled,
      };
    },

    async saveSkill() {
      const id = this.skillOpenId;
      try {
        await this.api('/skills/' + id, {
          method: 'PATCH',
          body: JSON.stringify(this.skillPayload(this.skillDraft)),
        });
        await this.loadSkills();
      } catch (e) {
        this.err = String(e.message); // 校验错误是中文的,原样给人看
      }
    },

    async createSkill() {
      try {
        await this.api('/skills', {
          method: 'POST',
          body: JSON.stringify(this.skillPayload(this.skillNew)),
        });
        this.skillNew = null;
        await this.loadSkills();
      } catch (e) {
        this.err = String(e.message);
      }
    },

    async deleteSkill(s) {
      if (!confirm('删掉 skill ' + s.name + '?\n\n被它遮蔽的同名 builtin(如果有)会重新生效。')) return;
      try {
        await this.api('/skills/' + s.id, { method: 'DELETE' });
        this.skillOpenId = null;
        await this.loadSkills();
      } catch (e) {
        this.err = String(e.message);
      }
    },

    newSkill() {
      this.skillNew = { name: '', group_id: this.skillq.group || '', description: '', body: '', enabled: true };
    },

    // A builtin is baked into the binary; the way to change it is a
    // same-name DB row, which shadows it at registry level.
    shadowSkill(s) {
      this.skillNew = {
        name: s.name,
        group_id: this.skillq.group || '',
        description: s.description,
        body: s.body,
        enabled: true,
      };
      this.skillOpenId = null;
      window.scrollTo({ top: 0 });
    },

    // ── charts ────────────────────────────────────────────────────

    async loadCharts() {
      const [usage, msgs] = await Promise.all([
        this.api('/usage?days=90'),
        this.api('/stats/messages?days=90'),
      ]);
      this.usageRows = usage;
      this.msgRows = msgs;
      this.drawCharts();
    },

    setRange(which, v) {
      this.range[which] = Number(v);
      this.$nextTick(() => this.drawCharts());
    },

    rangeWords(which) {
      return '最近 ' + this.range[which] + ' 天';
    },

    // The newest day present is "today": the server buckets in its own
    // timezone, and re-deriving the boundary from the client's clock
    // would drop or duplicate a day around midnight.
    daysBack(rows, days) {
      let newest = '';
      for (const r of rows) if (r.day > newest) newest = r.day;
      if (!newest) return [];
      const cut = isoDay(new Date(Date.parse(newest + 'T00:00:00') - (days - 1) * 86400000));
      return rows.filter((r) => r.day >= cut);
    },

    drawCharts() {
      const c = palette();

      // Token spend splits by what the tokens were, not by who spent
      // them: prompt vs completion is the axis that decides the bill.
      //
      // They differ by two orders of magnitude — prompt runs ~15M a
      // day against completion's ~400k — so they are two small
      // multiples with a synced cursor rather than one stack or one
      // chart with two y-axes.  Completion, the number you watch for
      // runaway replies, keeps a scale of its own.
      //
      // Inside prompt the split that matters is cache: two thirds of
      // every prompt is usually a re-read of context the provider
      // already holds, and it is billed differently.  That is a real
      // part-of-whole, so it stacks.
      const u = this.daysBack(this.usageRows, this.range.usage);
      const tok = sumByDay(u, ['prompt_tokens', 'cached_prompt_tokens', 'completion_tokens']);
      const [xs, prompt, cachedTok, completion] = tok;

      // Drawn total-first so the cached band paints over the top of
      // it: two bands, no blended overlap.
      this.plot('chart-prompt', 'prompt', [xs, prompt, cachedTok], [
        { label: '新读入', stroke: c.s1, fill: wash(c.s1, 0.20, 0.06) },
        { label: '缓存命中', stroke: c.s1, fill: wash(c.s1, 0.62, 0.40) },
      ], {
        height: 170,
        sync: 'usage',
        tip: (i) => ({
          rows: [
            { name: '新读入', colour: c.s1, alpha: 0.35, val: compact(prompt[i] - cachedTok[i]) },
            { name: '缓存命中', colour: c.s1, alpha: 1, val: compact(cachedTok[i]) },
          ],
          foot: 'prompt 合计 ' + compact(prompt[i]),
        }),
      });
      this.plot('chart-completion', 'completion', [xs, completion], [
        { label: 'completion', stroke: c.s2, fill: wash(c.s2, 0.34, 0.04) },
      ], {
        height: 120,
        sync: 'usage',
        tip: (i) => ({ rows: [{ name: 'completion', colour: c.s2, alpha: 1, val: compact(completion[i]) }] }),
      });

      // Messages split the way the prompt itself splits them: only
      // chat rows reach the model, so the chart answers "is the bot
      // talking, or just being operated" — command, debug and system
      // fold into one operations series.  Both are counts of the same
      // thing, so here the stack is the whole point.
      const m = chatOps(this.daysBack(this.msgRows, this.range.msgs));
      const [mxs, chat, ops] = m;
      const total = chat.map((v, i) => v + ops[i]);
      this.plot('chart-msgs', 'msgs', [mxs, total, chat], [
        { label: '操作', stroke: c.s2, fill: wash(c.s2, 0.34, 0.04) },
        { label: '对话', stroke: c.s1, fill: wash(c.s1, 0.34, 0.04) },
      ], {
        height: 240,
        tip: (i) => ({
          rows: [
            { name: '操作', colour: c.s2, alpha: 1, val: ops[i].toLocaleString() },
            { name: '对话', colour: c.s1, alpha: 1, val: chat[i].toLocaleString() },
          ],
          foot: '合计 ' + total[i].toLocaleString() + ' 条',
        }),
      });
    },

    // Totals under each small multiple's caption — the chart shows the
    // shape, the caption answers "how much, over the window I picked".
    rangeTotal(field) {
      const rows = this.daysBack(this.usageRows, this.range.usage);
      return compact(rows.reduce((n, r) => n + (r[field] || 0), 0));
    },
    msgTotal(chat) {
      const rows = this.daysBack(this.msgRows, this.range.msgs);
      return rows
        .filter((r) => (r.kind === 'chat') === chat)
        .reduce((n, r) => n + (r.count || 0), 0)
        .toLocaleString();
    },

    // ── stat cards ────────────────────────────────────────────────
    // "Today" is the newest day present in the rows (the server
    // buckets in its own timezone; guessing the client's would lie
    // at midnight edges).  Delta compares the two newest days.

    statCards() {
      const tokDays = byDay(this.usageRows, (r) => r.prompt_tokens + r.completion_tokens);
      const tokLast = tokDays[tokDays.length - 1];
      const tokPrev = tokDays[tokDays.length - 2];
      const prompt = byDay(this.usageRows, (r) => r.prompt_tokens);
      const completion = byDay(this.usageRows, (r) => r.completion_tokens);

      const msgDays = byDay(this.msgRows, (r) => r.count);
      const msgLast = msgDays[msgDays.length - 1];
      const msgPrev = msgDays[msgDays.length - 2];
      const chat = byDay(this.msgRows.filter((r) => r.kind === 'chat'), (r) => r.count);
      const chatLast = msgLast && chat.find((d) => d.day === msgLast.day);

      const h = this.overview.health || {};
      const stuck = (h.failed_deliveries || 0) + (h.media_parked || 0) + (h.failed_captures || 0);

      return [
        {
          label: '今日 token',
          value: tokLast ? compact(tokLast.v) : '-',
          delta: tokLast ? deltaPct(tokLast.v, tokPrev && tokPrev.v) : null,
          up: tokLast && tokPrev ? tokLast.v >= tokPrev.v : null,
          foot1: tokLast
            ? 'prompt ' + compact(prompt[prompt.length - 1].v) +
              ' · completion ' + compact(completion[completion.length - 1].v)
            : '还没有数据',
          foot2: '对比前一日',
        },
        {
          label: '今日消息',
          value: msgLast ? msgLast.v.toLocaleString() : '-',
          delta: msgLast ? deltaPct(msgLast.v, msgPrev && msgPrev.v) : null,
          up: msgLast && msgPrev ? msgLast.v >= msgPrev.v : null,
          foot1: msgLast
            ? '对话 ' + (chatLast ? chatLast.v : 0) +
              ' · 操作 ' + (msgLast.v - (chatLast ? chatLast.v : 0))
            : '还没有数据',
          foot2: '对比前一日',
        },
        {
          label: '在跑任务',
          value: String(this.overview.running_tasks ?? 0),
          delta: null,
          up: null,
          foot1: (this.overview.groups ?? 0) + ' 个会话有记录',
          foot2: 'kill 在任务页',
        },
        {
          // Work that is stuck, not work that is queued: a delivery
          // that failed, media parked after too many attempts, a
          // capture run that gave up.
          label: '待处理',
          value: String(stuck),
          delta: null,
          up: null,
          foot1: stuck
            ? '投递 ' + (h.failed_deliveries || 0) +
              ' · 媒体 ' + (h.media_parked || 0) +
              ' · capture ' + (h.failed_captures || 0)
            : '没有卡住的工作',
          foot2: (h.warn_logs || 0) + ' 条 warn 在缓冲区',
        },
      ];
    },

    // uPlot takes a pixel size, so the chart is rebuilt on resize (and
    // whenever the tab is reopened) against the current container
    // width.  Cheap at this data volume; the redraw is debounced so a
    // dragged window edge doesn't rebuild on every frame.  A scheme
    // flip rebuilds too — the series colours are read from CSS at
    // draw time.
    plot(elId, key, data, seriesDefs, opts = {}) {
      const el = document.getElementById(elId);
      if (!el) return;
      if (this.charts[key]) {
        this.charts[key].destroy();
        delete this.charts[key];
      }
      // No data at all is the normal state of a fresh install, and of
      // any window where nothing happened.  Say so instead of drawing
      // an axis pair around nothing.
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

      // ChartTooltipContent: a small card naming the day and reading
      // out every band, instead of uPlot's legend table.
      const tip = document.createElement('div');
      tip.className = 'chart-tooltip';
      el.appendChild(tip);
      // A synced cursor moves both multiples, but the pointer is only
      // ever over one of them — so a tooltip speaks only for the chart
      // being pointed at.  Bound to the container, which outlives the
      // uPlot instance a redraw replaces.
      if (!el.dataset.bound) {
        el.dataset.bound = '1';
        el.addEventListener('pointerenter', () => { el.dataset.over = '1'; });
        el.addEventListener('pointerleave', () => { delete el.dataset.over; });
      }

      const axis = {
        stroke: c.dim,
        ticks: { show: false },
        font: '11.5px ' + sansStack(),
      };
      // The shadcn area: a spline through the points, a gradient wash
      // under it, a clean 2px line, and no resting markers — the dot
      // appears under the cursor.
      const spline = uPlot.paths.spline();
      const series = seriesDefs.map((s) =>
        Object.assign({ width: 2, paths: spline, points: { show: false } }, s)
      );
      const axes = [
        // Just M/D.  uPlot's default stacks a year row underneath,
        // which is noise for a window that never spans one — and it
        // reserves 50px of height for the privilege; one row of
        // labels needs 28.  Whole days only: the data is daily, so
        // sub-day tick candidates would repeat a label.
        Object.assign({}, axis, {
          size: 28,
          grid: { show: false },          // CartesianGrid vertical={false}
          incrs: [86400, 2 * 86400, 3 * 86400, 5 * 86400, 7 * 86400, 14 * 86400, 28 * 86400],
          values: (_u, splits) => splits.map((v) => fmtDay(new Date(v * 1000))),
        }),
        Object.assign({}, axis, {
          size: 46,
          grid: { stroke: c.line, width: 1 },
          values: (_u, splits) => splits.map(compact),
        }),
      ];
      const cursor = { y: false, points: { size: 7 } };
      // The two usage multiples share one crosshair: the question is
      // always "that day — how much of each".
      if (opts.sync) cursor.sync = { key: opts.sync };
      this.charts[key] = new uPlot(
        {
          width: el.clientWidth,
          height: opts.height || 210,
          // Room for the first and last x tick to sit inside the plot
          // rather than being clipped by the card's padding.
          padding: [8, 10, 0, 0],
          cursor,
          legend: { show: false },
          // A stack starts at zero or the bands lie about their size.
          scales: { x: { time: true }, y: { range: (_u, _min, max) => [0, max * 1.05 || 1] } },
          series: [{}].concat(series),
          axes,
          hooks: {
            setCursor: [
              (u) => {
                const i = u.cursor.idx;
                if (i == null || !el.dataset.over || !opts.tip) {
                  tip.style.display = 'none';
                  return;
                }
                const t = opts.tip(i);
                tip.innerHTML =
                  '<div class="label">' + fmtDay(new Date(data[0][i] * 1000)) + '</div>' +
                  t.rows.map(tipRow).join('') +
                  (t.foot ? '<div class="foot">' + t.foot + '</div>' : '');
                tip.style.display = 'block';
                const x = u.valToPos(data[0][i], 'x');
                const w = tip.offsetWidth;
                tip.style.left = Math.min(Math.max(x - w / 2, 2), el.clientWidth - w - 2) + 'px';
                tip.style.top = '4px';
              },
            ],
          },
        },
        data,
        el
      );
      if (!this._chartsBound) {
        this._chartsBound = true;
        let t;
        const redraw = () => {
          clearTimeout(t);
          t = setTimeout(() => this.tab === 'overview' && this.drawCharts(), 150);
        };
        addEventListener('resize', redraw);
        matchMedia('(prefers-color-scheme: light)').addEventListener('change', redraw);
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
      if (secs == null) return '-';
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
// the scheme was at load.  Series use the chart steps of the two
// hues; axes use the text tokens.
function palette() {
  const s = getComputedStyle(document.documentElement);
  const v = (n) => s.getPropertyValue(n).trim();
  return { s1: v('--chart-1'), s2: v('--chart-2'), dim: v('--muted-foreground'), line: v('--border') };
}

function sansStack() {
  return getComputedStyle(document.documentElement).getPropertyValue('--sans').trim();
}

// A colour at an alpha, for the tooltip swatches.
function hexA(colour, a) {
  return 'rgba(' + toRGB(colour).join(',') + ',' + a + ')';
}

// The shadcn area look: a vertical wash from the line colour down to
// almost nothing.  uPlot evaluates fill functions at draw time, so the
// gradient tracks resizes and scheme flips for free — but it also asks
// once before the first layout, when the bbox is still NaN; that call
// gets a flat colour instead.
//
// The stops are composited against the surface rather than left
// translucent: a stacked chart paints the upper band first and the
// lower band over it, and two alpha washes would blend into a third
// colour exactly where the reader is trying to tell them apart.
function wash(colour, top, bottom) {
  return (u) => {
    const bg = surface(u.root);
    const box = u.bbox;
    if (!isFinite(box.top) || !isFinite(box.height) || box.height <= 0) return blend(colour, bg, top);
    const g = u.ctx.createLinearGradient(0, box.top, 0, box.top + box.height);
    g.addColorStop(0, blend(colour, bg, top));
    g.addColorStop(1, blend(colour, bg, bottom));
    return g;
  };
}

// What is actually behind the chart: the first ancestor that paints
// one.  An unset background computes to rgba(0,0,0,0) in every engine,
// which is how "keeps looking" is spelled.
function surface(el) {
  for (let n = el; n; n = n.parentElement) {
    const bg = getComputedStyle(n).backgroundColor;
    if (bg && bg !== 'transparent' && !/^rgba\(0,\s*0,\s*0,\s*0\)$/.test(bg)) return toRGB(bg);
  }
  return [255, 255, 255];
}

// The tokens are oklch and getComputedStyle hands them back that way,
// but blending needs channels — so let the browser resolve the colour
// by painting one pixel with it.  Cached: a redraw asks for the same
// three colours every time, and an invalid string would silently
// resolve to the black left in fillStyle.
const rgbCache = new Map();
function toRGB(css) {
  let hit = rgbCache.get(css);
  if (hit) return hit;
  const c = document.createElement('canvas');
  c.width = c.height = 1;
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.fillStyle = '#000';
  ctx.fillStyle = css;
  ctx.fillRect(0, 0, 1, 1);
  const d = ctx.getImageData(0, 0, 1, 1).data;
  hit = [d[0], d[1], d[2]];
  rgbCache.set(css, hit);
  return hit;
}

// `colour` at `a` over `bg`, flattened.
function blend(colour, bg, a) {
  const fg = toRGB(colour);
  return 'rgb(' + fg.map((v, i) => Math.round(v * a + bg[i] * (1 - a))).join(',') + ')';
}

function tipRow(r) {
  return (
    '<div class="row"><span class="dot" style="background:' + hexA(r.colour, r.alpha) + '"></span>' +
    '<span class="name">' + r.name + '</span><span class="val">' + r.val + '</span></div>'
  );
}

function isoDay(d) {
  return (
    d.getFullYear() + '-' +
    String(d.getMonth() + 1).padStart(2, '0') + '-' +
    String(d.getDate()).padStart(2, '0')
  );
}

// Newest-last [{day, v}] with `f` summed per day.
function byDay(rows, f) {
  const days = new Map();
  for (const r of rows) days.set(r.day, (days.get(r.day) || 0) + (f(r) || 0));
  return [...days.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([day, v]) => ({ day, v }));
}

// "+12.5%" / "-3%" against the previous day, null when there is
// nothing to compare against.
function deltaPct(now, prev) {
  if (prev == null || prev === 0) return null;
  const d = ((now - prev) / prev) * 100;
  const r = Math.abs(d) >= 10 ? Math.round(d) : d.toFixed(1);
  return (d >= 0 ? '+' : '') + r + '%';
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

// chat vs everything-else per day.  Absent days read as 0 on both
// series so a quiet kind draws a floor rather than a gap.
function chatOps(rows) {
  const days = new Map();
  for (const r of rows) {
    let acc = days.get(r.day);
    if (!acc) days.set(r.day, (acc = [0, 0]));
    acc[r.kind === 'chat' ? 0 : 1] += r.count || 0;
  }
  return frame(days, (sorted) => [0, 1].map((i) => sorted.map(([, v]) => v[i])));
}
