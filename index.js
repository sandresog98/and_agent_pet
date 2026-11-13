import { existsSync, readFileSync } from 'node:fs';
import { mkdir, rename, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const inject = ['webServer'];

const STATE_VERSION = 1;
const MAX_ALERTS = 8;
const MAX_URL_CHARS = 24_000;

function stateDirectory() {
  if (process.platform === 'darwin') {
    return join(homedir(), 'Library', 'Application Support', 'dsh-session-notifier');
  }
  if (process.platform === 'win32') {
    const base = process.env.LOCALAPPDATA ?? join(homedir(), 'AppData', 'Local');
    return join(base, 'dsh-session-notifier');
  }
  const base = process.env.XDG_STATE_HOME ?? join(homedir(), '.local', 'state');
  return join(base, 'dsh-session-notifier');
}

function clip(value, max) {
  return String(value ?? '')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, max);
}

function count(value) {
  return Number.isFinite(value) ? Math.max(0, Math.min(999, Math.trunc(value))) : 0;
}

function normalizeKind(value) {
  return value === 'approval' || value === 'question' || value === 'planReview' || value === 'completed'
    ? value
    : 'question';
}

const ACTIVITY_KINDS = new Set([
  'thinking',
  'read',
  'readImage',
  'search',
  'write',
  'edit',
  'commands',
  'code',
  'webSearch',
  'webFetch',
  'subagents',
  'plan',
  'questions',
  'tools',
  'error',
]);

function normalizeActivity(value) {
  return typeof value === 'string' && ACTIVITY_KINDS.has(value) ? value : null;
}

function normalizeState(input) {
  const alerts = Array.isArray(input?.alerts)
    ? input.alerts.slice(0, MAX_ALERTS).map((alert) => ({
      sessionId: clip(alert?.sessionId, 120),
      title: clip(alert?.title, 90),
      kind: normalizeKind(alert?.kind),
      preview: clip(alert?.preview, 120),
      at: Number.isFinite(alert?.at) ? alert.at : Date.now(),
      read: alert?.read === true,
    }))
    : [];

  return {
    version: STATE_VERSION,
    updatedAt: Date.now(),
    runningCount: count(input?.runningCount),
    pendingCount: count(input?.pendingCount),
    completedCount: count(input?.completedCount),
    muted: input?.muted === true,
    focused: input?.focused !== false,
    activity: normalizeActivity(input?.activity),
    activityTool: clip(input?.activityTool, 40),
    error: input?.error === true || input?.activity === 'error',
    alerts,
  };
}

function readOverlayManifest(packageDir) {
  const manifestPath = join(packageDir, 'overlay', 'platforms.json');
  if (!existsSync(manifestPath)) return undefined;
  try {
    return JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch (error) {
    console.warn('dsh-session-notifier: cannot read overlay/platforms.json', error);
    return undefined;
  }
}

function startNativeOverlay(ctx) {
  const packageDir = dirname(fileURLToPath(import.meta.url));
  const manifest = readOverlayManifest(packageDir);
  const platformSpec = manifest?.[process.platform]
    ?? (process.platform === 'win32'
      ? { supported: true, kind: 'powershell', entry: 'windows/dsh-session-notifier-overlay.ps1' }
      : undefined);

  if (platformSpec === undefined || platformSpec.supported !== true) {
    console.info(`dsh-session-notifier: no native overlay for ${process.platform}; web bridge remains active`);
    return;
  }
  if (typeof platformSpec.entry !== 'string' || platformSpec.entry.includes('..')) {
    console.warn('dsh-session-notifier: invalid overlay entry in platforms.json');
    return;
  }

  const overlayRoot = join(packageDir, 'overlay');
  const entryPath = join(overlayRoot, platformSpec.entry);
  if (!existsSync(entryPath)) {
    console.warn(`dsh-session-notifier: overlay entry is missing: ${entryPath}`);
    return;
  }

  let command;
  let args;
  if (platformSpec.kind === 'powershell') {
    command = process.env.SystemRoot
      ? join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
      : 'powershell.exe';
    args = [
      '-NoProfile',
      '-STA',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      entryPath,
    ];
  } else if (platformSpec.kind === 'executable') {
    command = entryPath;
    args = [];
  } else {
    console.warn(`dsh-session-notifier: unsupported overlay kind "${platformSpec.kind}"`);
    return;
  }

  let child;
  try {
    child = spawn(command, args, {
      stdio: 'ignore',
      windowsHide: true,
    });
  } catch (error) {
    console.error('dsh-session-notifier: cannot start native overlay', error);
    return;
  }

  child.on('error', (error) => {
    console.error('dsh-session-notifier: native overlay process failed', error);
  });
  child.unref();

  ctx.effect(() => () => {
    try {
      child.kill();
    } catch (error) {
      // The overlay may already have exited (for example because another instance owns the mutex).
    }
  }, 'dsh-session-notifier: native overlay process');
}

export function apply(ctx) {
  const dir = stateDirectory();
  const statePath = join(dir, 'state.json');
  const tempPath = `${statePath}.tmp`;
  let queue = Promise.resolve();

  const writeState = (state) => {
    queue = queue
      .then(async () => {
        await mkdir(dir, { recursive: true });
        await writeFile(tempPath, `${JSON.stringify(state, null, 2)}\n`, 'utf8');
        await rename(tempPath, statePath);
      })
      .catch((error) => {
        console.error('dsh-session-notifier: cannot write state file', error);
      });
    return queue;
  };

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: '/dsh-session-notifier/state',
    resource: async (request) => {
      const origin = request.headers.get('origin');
      const expected = ctx.webServer.getOrigin();
      if (origin !== null && origin !== expected) {
        return new Response('forbidden', { status: 403 });
      }
      if (request.url.length > MAX_URL_CHARS) {
        return new Response('payload too large', { status: 413 });
      }

      const url = new URL(request.url);
      const raw = url.searchParams.get('data');
      if (raw === null || raw === '') {
        return new Response('missing data', { status: 400 });
      }

      let parsed;
      try {
        parsed = JSON.parse(raw);
      } catch (error) {
        return new Response('invalid json', { status: 400 });
      }
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        return new Response('invalid state', { status: 400 });
      }

      const state = normalizeState(parsed);
      void writeState(state);
      return new Response(JSON.stringify({ ok: true, updatedAt: state.updatedAt }), {
        status: 200,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'no-store',
        },
      });
    },
  }), 'dsh-session-notifier: state route');

  startNativeOverlay(ctx);
  void writeState(normalizeState({}));
}
