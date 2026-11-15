import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SCRIPT = path.join(HERE, 'dsh-badge.ps1')
const STATE = path.join(tmpdir(), 'dsh-badge-state.json')
const CANCEL = path.join(tmpdir(), 'dsh-badge-cancel.txt')

export const name = 'dsh-badge'
export const inject = ['tools']

/** 启动角标；已有的同名角标会被新实例顶掉（脚本内部按 pid 文件处理）。 */
function launch(seconds, extras = []) {
  if (!existsSync(SCRIPT)) {
    return { ok: false, error: `找不到脚本：${SCRIPT}` }
  }
  const args = [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT,
    '-StateFile', STATE, '-Seconds', String(seconds), ...extras
  ]
  // 注意：不要用 detached:true —— Windows 上它和 windowsHide 一起用会让
  // PowerShell 建不出控制台直接退出。unref() 已经能让子进程活过父进程。
  const child = spawn('powershell.exe', args, {
    stdio: 'ignore',
    windowsHide: true,
  })
  child.unref()
  return { ok: true, pid: child.pid, stateFile: STATE }
}

async function writeState(patch) {
  let current = {}
  try {
    current = JSON.parse(await readFile(STATE, 'utf8'))
  } catch {
    current = {}
  }
  const next = { ...current, ...patch }
  await writeFile(STATE, JSON.stringify(next), 'utf8')
  return next
}

const TONE = ['busy', 'waiting', 'error', 'done']
const ANCHOR = ['BottomRight', 'BottomLeft', 'TopRight', 'TopLeft', 'BottomCenter']

function textResult(text) {
  return [{ type: 'text', text }]
}

const showTool = {
  name: 'badge_show',
  description:
    '在屏幕角落显示「正在操作」状态角标，告诉用户 AI 现在在干什么。开始操作桌面/浏览器前调用；之后用 badge_update 更新进度，结束时用 badge_hide。角标默认点击穿透、不进截图。',
  parameters: {
    type: 'object',
    properties: {
      title: { type: 'string', description: '标题，一句话说明在做什么' },
      detail: { type: 'string', description: '副标题，当前这一步的细节' },
      step: { type: 'integer', description: '当前第几步（配合 total 显示进度条）' },
      total: { type: 'integer', description: '一共几步' },
      seconds: { type: 'integer', description: '无心跳时的自动隐藏秒数，默认 600' },
      anchor: { type: 'string', enum: ANCHOR, description: '贴在哪个角，默认 BottomRight' },
      monitor: { type: 'integer', description: '显示器序号，0 是主屏' },
      opacity: { type: 'number', description: '不透明度 0-1，默认 0.92' },
      accent: { type: 'string', description: '主色，形如 #00D4FF' },
      lang: { type: 'string', enum: ['zh', 'en'], description: '界面语言' },
      clickable: {
        type: 'boolean',
        description: '让角标可点击并显示 × 按钮（会挡住角标那块区域的点击），配合 badge_cancelled 使用'
      },
    },
    required: ['title'],
    additionalProperties: false,
  },
  output: {
    schema: {
      type: 'object',
      properties: {
        ok: { type: 'boolean' },
        pid: { type: 'number' },
        stateFile: { type: 'string' },
        error: { type: 'string' },
      },
      additionalProperties: false,
    },
    render: (_args, value) =>
      textResult(value.ok ? `角标已显示（pid ${value.pid}）` : `角标启动失败：${value.error}`),
  },
  async execute(args) {
    const seconds = args.seconds ?? 600
    const extras = []
    if (args.anchor) extras.push('-Anchor', args.anchor)
    if (args.monitor !== undefined) extras.push('-Monitor', String(args.monitor))
    if (args.opacity !== undefined) extras.push('-Opacity', String(args.opacity))
    if (args.accent) extras.push('-Accent', args.accent)
    if (args.lang) extras.push('-Lang', args.lang)
    if (args.clickable) {
      extras.push('-Clickable', '-CancelFile', CANCEL)
      await rm(CANCEL, { force: true })
    }

    await writeState({
      title: args.title,
      detail: args.detail ?? '',
      step: args.step ?? 0,
      total: args.total ?? 0,
      tone: 'busy',
    })
    return launch(seconds, extras)
  },
}

const updateTool = {
  name: 'badge_update',
  description:
    '更新正在显示的角标：改标题、说明、步骤进度或状态色（busy / waiting / error / done）。每完成一步就调用一次，让用户看得见进展。',
  parameters: {
    type: 'object',
    properties: {
      title: { type: 'string', description: '新的标题' },
      detail: { type: 'string', description: '新的副标题' },
      step: { type: 'integer', description: '当前第几步' },
      total: { type: 'integer', description: '一共几步' },
      tone: { type: 'string', enum: TONE, description: '状态色' },
    },
    additionalProperties: false,
  },
  output: {
    schema: {
      type: 'object',
      properties: {
        ok: { type: 'boolean' },
        state: { type: 'object', additionalProperties: true },
      },
      additionalProperties: false,
    },
    render: (_args, value) =>
      textResult(value.ok ? `角标已更新：${value.state?.title ?? ''}` : '角标更新失败'),
  },
  async execute(args) {
    const patch = {}
    for (const key of ['title', 'detail', 'step', 'total', 'tone']) {
      if (args[key] !== undefined) patch[key] = args[key]
    }
    const state = await writeState(patch)
    return { ok: true, state }
  },
}

const hideTool = {
  name: 'badge_hide',
  description: '收起「正在操作」角标。任务结束后一定要调用，别让角标留在屏幕上。',
  parameters: { type: 'object', properties: {}, additionalProperties: false },
  output: {
    schema: {
      type: 'object',
      properties: { ok: { type: 'boolean' } },
      additionalProperties: false,
    },
    render: () => textResult('角标已收起'),
  },
  async execute() {
    if (existsSync(SCRIPT)) {
      const child = spawn(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, '-Stop'],
        { stdio: 'ignore', windowsHide: true },
      )
      child.unref()
    }
    return { ok: true }
  },
}

const cancelledTool = {
  name: 'badge_cancelled',
  description:
    '检查用户是否点了角标上的取消按钮。只有在 badge_show 时传了 clickable 才有意义；返回 true 就应当停止当前操作。',
  parameters: { type: 'object', properties: {}, additionalProperties: false },
  output: {
    schema: {
      type: 'object',
      properties: {
        cancelled: { type: 'boolean' },
        cancelFile: { type: 'string' },
      },
      additionalProperties: false,
    },
    render: (_args, value) => textResult(value.cancelled ? '用户点了取消' : '用户没有取消'),
  },
  async execute() {
    return { cancelled: existsSync(CANCEL), cancelFile: CANCEL }
  },
}

export function apply(ctx) {
  ctx.effect(function* () {
    yield ctx.tools.register(showTool)
    yield ctx.tools.register(updateTool)
    yield ctx.tools.register(hideTool)
    yield ctx.tools.register(cancelledTool)
  }, 'dsh-badge: tools')
}
