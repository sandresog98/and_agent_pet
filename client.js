/**
 * Headless Client half of dsh-session-notifier.
 *
 * The bell UI was removed. This module stays mounted in `shell.overlay` only to
 * read the live Client session sources and publish a compact snapshot for the
 * native Windows companion. It renders nothing.
 */
window.__ModuleLoader__.load({
  id: 'dsh-session-notifier',
  factory(require) {
    const React = require('react');
    const identitySelector = (state) => state;
    const MAX_ALERTS = 8;

    function statusEntries(status) {
      if (!status) return [];
      if (typeof status.entries === 'function') return [...status.entries()];
      if (typeof status === 'object') return Object.entries(status);
      return [];
    }

    function statusGet(status, sessionId) {
      if (!status) return undefined;
      if (typeof status.get === 'function') return status.get(sessionId);
      return status[sessionId];
    }

    function toolCategory(name) {
      if (name === 'read') return 'read';
      if (name === 'read_image') return 'readImage';
      if (name === 'grep' || name === 'glob' || name.endsWith('_inspect')) return 'search';
      if (name === 'write') return 'write';
      if (name === 'edit' || name === 'apply_patch') return 'edit';
      if (['bash', 'pwsh', 'exec_command', 'write_stdin'].includes(name) || name.startsWith('terminal_')) return 'commands';
      if (name === 'run_code') return 'code';
      if (name === 'web_search') return 'webSearch';
      if (name === 'web_fetch') return 'webFetch';
      if (name === 'subagent' || name.startsWith('subagent_')) return 'subagents';
      if (['todo_write', 'create_goal', 'update_goal', 'get_goal'].includes(name)) return 'plan';
      if (name === 'ask_user_question' || name === 'request_user_input') return 'questions';
      return 'tools';
    }

    function pickActivitySession(sessions, status) {
      let main = null;
      let running = null;
      for (const [sessionId, entry] of statusEntries(status)) {
        if (!entry || typeof entry !== 'object') continue;
        const row = sessions && sessions.byId ? sessions.byId[sessionId] : undefined;
        if (row && row.retainedBy && row.retainedBy.mainView > 0) main = sessionId;
        if (entry.running === true && running === null) running = sessionId;
      }
      if (main !== null) {
        const mainEntry = statusGet(status, main);
        if (mainEntry && mainEntry.running === true) return main;
      }
      return running ?? main;
    }

    function sameActivity(left, right) {
      if (left === right) return true;
      if (!left || !right) return false;
      return left.kind === right.kind && left.tool === right.tool;
    }

    function clip(value, max) {
      const text = String(value ?? '').replace(/\s+/g, ' ').trim();
      return text.length > max ? `${text.slice(0, max - 1)}…` : text;
    }

    function sessionTitle(sessions, sessionId) {
      const row = sessions && sessions.byId ? sessions.byId[sessionId] : undefined;
      const title = row ? (row.displayTitle || row.title) : undefined;
      return clip(typeof title === 'string' && title.trim() !== '' ? title : String(sessionId), 90);
    }

    function pendingKind(pending) {
      if (pending && pending.kind === 'approval') return 'approval';
      if (pending && pending.kind === 'plan-review') return 'planReview';
      return 'question';
    }

    function pendingPreview(pending) {
      if (!pending) return '';
      if (pending.kind === 'approval') {
        return typeof pending.toolName === 'string' ? clip(pending.toolName, 80) : '';
      }
      const questions = Array.isArray(pending.questions) ? pending.questions : [];
      const first = questions[0];
      if (first && typeof first === 'object') {
        const text = first.header || first.question;
        if (typeof text === 'string' && text.trim() !== '') return clip(text, 110);
      }
      return '';
    }

    function buildSnapshot(sessions, status) {
      const alerts = [];
      let runningCount = 0;
      let pendingCount = 0;
      let completedCount = 0;

      for (const [sessionId, entry] of statusEntries(status)) {
        if (!entry || typeof entry !== 'object') continue;
        if (entry.running === true) runningCount += 1;
        if (entry.pendingInteraction) {
          pendingCount += 1;
          alerts.push({
            sessionId,
            title: sessionTitle(sessions, sessionId),
            kind: pendingKind(entry.pendingInteraction),
            preview: pendingPreview(entry.pendingInteraction),
            at: Date.now(),
            read: false,
          });
        }
        if (entry.completionUnread === true) {
          completedCount += 1;
          alerts.push({
            sessionId,
            title: sessionTitle(sessions, sessionId),
            kind: 'completed',
            preview: '',
            at: Date.now(),
            read: false,
          });
        }
      }

      alerts.sort((left, right) => {
        const leftRank = left.kind === 'completed' ? 1 : 0;
        const rightRank = right.kind === 'completed' ? 1 : 0;
        return leftRank - rightRank;
      });

      return {
        runningCount,
        pendingCount,
        completedCount,
        alerts: alerts.slice(0, MAX_ALERTS),
      };
    }

    function SessionStateBridge(props) {
      const sessions = props.useSessions(identitySelector);
      const sessionStatus = props.useSessionStatus(identitySelector);
      const [heartbeat, setHeartbeat] = React.useState(0);
      const [pageFocused, setPageFocused] = React.useState(() => (
        typeof document === 'undefined' || typeof document.hasFocus !== 'function' || document.hasFocus()
      ));
      const [activity, setActivity] = React.useState(null);
      const activitySessionId = pickActivitySession(sessions, sessionStatus);
      const activityRunning = activitySessionId === null
        ? false
        : statusGet(sessionStatus, activitySessionId)?.running === true;

      React.useEffect(() => {
        if (activitySessionId === null || typeof props.readActivity !== 'function') {
          setActivity(null);
          return undefined;
        }
        const update = () => {
          let next = null;
          try {
            next = props.readActivity(activitySessionId, activityRunning);
          } catch (error) {
            next = null;
          }
          setActivity((previous) => (sameActivity(previous, next) ? previous : next));
        };
        update();
        const interval = window.setInterval(update, activityRunning ? 500 : 2000);
        return () => window.clearInterval(interval);
      }, [activitySessionId, activityRunning, props.readActivity]);

      React.useEffect(() => {
        const interval = window.setInterval(() => {
          setHeartbeat((value) => value + 1);
        }, 10000);
        return () => window.clearInterval(interval);
      }, []);

      React.useEffect(() => {
        if (typeof window === 'undefined') return undefined;
        const onFocus = () => setPageFocused(true);
        const onBlur = () => setPageFocused(false);
        window.addEventListener('focus', onFocus);
        window.addEventListener('blur', onBlur);
        return () => {
          window.removeEventListener('focus', onFocus);
          window.removeEventListener('blur', onBlur);
        };
      }, []);

      React.useEffect(() => {
        const timer = window.setTimeout(() => {
          try {
            const snapshot = buildSnapshot(sessions, sessionStatus);
            const payload = {
              version: 1,
              updatedAt: Date.now(),
              ...snapshot,
              muted: false,
              focused: pageFocused,
              activity: activity ? activity.kind : null,
              activityTool: activity ? activity.tool : '',
              error: activity ? activity.kind === 'error' : false,
            };
            const url = new URL('/dsh-session-notifier/state', window.location.origin);
            url.searchParams.set('data', JSON.stringify(payload));
            fetch(url.toString(), {
              method: 'GET',
              cache: 'no-store',
              credentials: 'same-origin',
            }).catch(() => {
              // The native companion is optional.
            });
          } catch (error) {
            // A page without an HTTP origin has no native companion bridge.
          }
        }, 120);
        return () => window.clearTimeout(timer);
      }, [sessions, sessionStatus, heartbeat, pageFocused, activity]);

      return null;
    }

    function readActivity(ctx) {
      return (sessionId, running) => {
        const binding = ctx.sessions.binding(sessionId);
        if (!binding || !binding.eventSource || typeof binding.eventSource.getSnapshot !== 'function') {
          return running ? { kind: 'thinking', tool: '' } : null;
        }
        const entries = binding.eventSource.getSnapshot()?.entries ?? [];
        const active = new Map();
        let error = false;

        for (const entry of entries) {
          const event = entry && entry.event ? entry.event : entry;
          if (!event || typeof event !== 'object') continue;
          if (event.type === 'turn/start') {
            active.clear();
            error = false;
            continue;
          }
          if (event.type === 'turn/end') {
            active.clear();
            error = event.data && event.data.reason && event.data.reason.kind === 'error';
            continue;
          }
          if (event.type === 'tool/call' || event.type === 'tool/ptc-dispatch-start') {
            const name = event.data && event.data.name;
            const callId = event.data && (event.data.callId ?? event.data.subCallId);
            if (typeof name === 'string' && callId !== undefined) {
              active.set(String(callId), { name, at: Number(event.time) || 0 });
            }
            continue;
          }
          if (event.type === 'tool/result' || event.type === 'tool/ptc-dispatch-result') {
            const callId = event.data
              && ((event.data.message && event.data.message.source && event.data.message.source.callId)
                ?? event.data.callId
                ?? event.data.subCallId);
            if (callId !== undefined) active.delete(String(callId));
          }
        }

        if (error) return { kind: 'error', tool: '' };
        if (!running) return null;

        let latest = null;
        for (const tool of active.values()) {
          if (latest === null || tool.at >= latest.at) latest = tool;
        }
        if (latest !== null) return { kind: toolCategory(latest.name), tool: latest.name };
        return { kind: 'thinking', tool: '' };
      };
    }

    return {
      inject: ['slots', 'uiSession', 'sessions'],
      apply(ctx) {
        const activityReader = readActivity(ctx);
        ctx.slots.inject('shell.overlay', () => ctx.slots.register({
          name: 'shell.overlay',
          id: 'dsh-session-notifier',
          order: 50,
          inject: () => ({ readActivity: activityReader }),
        }, SessionStateBridge));
      },
    };
  },
});
