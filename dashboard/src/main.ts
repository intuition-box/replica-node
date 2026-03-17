import './style.css'

const POLL_INTERVAL = 2000
const LERP_INTERVAL = 50
const PHASES = ['downloading', 'extracting', 'starting', 'syncing', 'synced'] as const

type Phase = typeof PHASES[number] | 'installing' | 'error'

interface Status {
  phase: Phase
  progress?: number
  downloadedBytes?: number
  totalBytes?: number
  downloadedGB?: number
  totalGB?: number
  localBlock?: number
  officialBlock?: number
  blockDiff?: number
  blocksPerMinute?: number
  message?: string
  updatedAt?: string
}

let status: Status = { phase: 'installing' }

// Smooth animation state
let displayBytes = 0
let targetBytes = 0
let totalBytes = 0
let lerpHandle = 0

// ETA tracking
let prevBytes = 0
let prevTime = 0
let bytesPerSec = 0

function startLerp() {
  if (lerpHandle) return
  lerpHandle = window.setInterval(() => {
    if (Math.abs(targetBytes - displayBytes) < 1000) {
      displayBytes = targetBytes
    } else {
      displayBytes += (targetBytes - displayBytes) * 0.15
    }
    updateDownloadDisplay()
  }, LERP_INTERVAL)
}

function updateDownloadDisplay() {
  const el = document.getElementById('dl-progress')
  if (!el) return

  const pct = totalBytes > 0 ? (displayBytes / totalBytes) * 100 : 0
  const dlGB = displayBytes / 1_073_741_824
  const tGB = totalBytes / 1_073_741_824

  const fill = el.querySelector<HTMLDivElement>('.fill')
  const sizeLabel = el.querySelector<HTMLSpanElement>('.dl-size')
  const pctLabel = el.querySelector<HTMLSpanElement>('.dl-pct')

  if (fill) fill.style.width = `${pct}%`
  if (sizeLabel) sizeLabel.textContent = `${dlGB.toFixed(2)} / ${tGB.toFixed(1)} GB`
  if (pctLabel) pctLabel.textContent = `${pct.toFixed(1)}%`

  const etaEl = document.getElementById('dl-eta')
  if (etaEl && bytesPerSec > 0) {
    const remaining = totalBytes - displayBytes
    const secsLeft = Math.max(0, Math.round(remaining / bytesPerSec))
    const finishAt = new Date(Date.now() + secsLeft * 1000)
    etaEl.textContent = `~${fmtDuration(secsLeft)} left \u00b7 done at ~${finishAt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`
  }
}

function fmtDuration(secs: number): string {
  if (secs < 60) return `${secs}s`
  const m = Math.floor(secs / 60)
  const s = secs % 60
  if (m < 60) return `${m}min ${s.toString().padStart(2, '0')}s`
  const h = Math.floor(m / 60)
  const rm = m % 60
  return `${h}h ${rm.toString().padStart(2, '0')}min`
}

async function fetchStatus(): Promise<Status> {
  const res = await fetch('/api/status')
  return res.json()
}

function fmt(n: number | undefined): string {
  if (n === undefined || n === null) return '\u2014'
  return n.toLocaleString('en-US')
}

function hex(n: number | undefined): string {
  if (n === undefined || n === null) return ''
  return '0x' + n.toString(16)
}

function stepperHTML(current: Phase): string {
  const steps = PHASES
  let passedCurrent = false

  return `<div class="stepper">${steps.map((step, i) => {
    let cls = ''
    if (step === current) {
      cls = current === 'synced' ? 'done' : 'active'
      passedCurrent = true
    } else if (!passedCurrent) {
      cls = 'done'
    }

    const line = i < steps.length - 1
      ? `<div class="step-line ${!passedCurrent || step === current ? 'done' : ''}"></div>`
      : ''

    return `<div class="step ${cls}"><div class="dot"></div><div class="label">${step}</div></div>${line}`
  }).join('')}</div>`
}

function downloadingHTML(): string {
  return `
    <div class="phase-title">Downloading snapshot</div>
    <div class="progress-bar-wrapper" id="dl-progress">
      <div class="progress-bar"><div class="fill" style="width: 0%"></div></div>
      <div class="progress-info">
        <span class="dl-size">0.00 / 0.0 GB</span>
        <span class="dl-pct">0.0%</span>
      </div>
    </div>
    <div class="dl-eta" id="dl-eta"></div>
  `
}

function extractingHTML(): string {
  return `
    <div class="spinner"></div>
    <div class="phase-title">Extracting snapshot</div>
    <div class="phase-message">This may take a few minutes</div>
  `
}

function startingHTML(s: Status): string {
  return `
    <div class="spinner"></div>
    <div class="phase-title">Starting node</div>
    <div class="phase-message">${s.message || 'Waiting for Nitro to respond...'}</div>
  `
}

function blocksHTML(s: Status): string {
  const isSynced = s.phase === 'synced'
  const diffClass = (s.blockDiff ?? 0) === 0 ? 'zero' : 'behind'
  const dotClass = isSynced ? 'synced' : 'syncing'
  const label = isSynced ? 'In sync' : 'Syncing'

  return `
    <div class="grid">
      <div class="card official">
        <div class="card-label">Official RPC</div>
        <div class="block-number">${fmt(s.officialBlock)}</div>
        <div class="block-hex">${hex(s.officialBlock)}</div>
      </div>
      <div class="card replica">
        <div class="card-label">Replica</div>
        <div class="block-number">${fmt(s.localBlock)}</div>
        <div class="block-hex">${hex(s.localBlock)}</div>
      </div>
    </div>
    <div class="sync-bar">
      <div class="sync-indicator">
        <div class="sync-dot ${dotClass}"></div>
        ${label}
      </div>
      <div class="sync-diff">
        Diff: <span class="val ${diffClass}">${fmt(s.blockDiff)}</span>
        ${s.blocksPerMinute ? ` &middot; ${fmt(s.blocksPerMinute)} blk/min` : ''}
      </div>
    </div>
  `
}

function errorHTML(s: Status): string {
  return `<div class="error-box">${s.message || 'An error occurred'}</div>`
}

function phaseContent(s: Status): string {
  switch (s.phase) {
    case 'installing': return `<div class="spinner"></div><div class="phase-title">Initializing</div>`
    case 'downloading': return downloadingHTML()
    case 'extracting': return extractingHTML()
    case 'starting': return startingHTML(s)
    case 'syncing': return blocksHTML(s)
    case 'synced': return blocksHTML(s)
    case 'error': return errorHTML(s)
    default: return `<div class="spinner"></div><div class="phase-title">${s.phase}</div>`
  }
}

let lastPhase: Phase | null = null

function render() {
  const activePhase = status.phase === 'installing' ? 'downloading' : status.phase
  const time = status.updatedAt
    ? new Date(status.updatedAt).toLocaleTimeString()
    : '\u2014'

  // Only rebuild DOM when phase changes, otherwise update in-place
  if (lastPhase !== status.phase) {
    lastPhase = status.phase
    document.querySelector<HTMLDivElement>('#app')!.innerHTML = `
      <header>
        <h1><span>Intuition L3</span> \u2014 Replica Node</h1>
        <div class="badge">Chain 1155 \u00b7 Arbitrum Nitro</div>
      </header>

      ${stepperHTML(activePhase as Phase)}

      <div class="phase-content">
        ${phaseContent(status)}
      </div>

      <div class="footer">
        Updated <span id="update-time">${time}</span>
      </div>
    `
  }

  // Update time
  const timeEl = document.getElementById('update-time')
  if (timeEl) timeEl.textContent = time

  // Update download animation target
  if (status.phase === 'downloading') {
    const newBytes = status.downloadedBytes ?? 0
    const now = Date.now()

    // Calculate speed from delta between polls
    if (prevTime > 0 && newBytes > prevBytes) {
      const elapsed = (now - prevTime) / 1000
      if (elapsed > 0) {
        const speed = (newBytes - prevBytes) / elapsed
        // Smooth the speed estimate
        bytesPerSec = bytesPerSec > 0 ? bytesPerSec * 0.7 + speed * 0.3 : speed
      }
    }
    prevBytes = newBytes
    prevTime = now

    targetBytes = newBytes
    totalBytes = status.totalBytes ?? 34_000_000_000
    startLerp()
    updateDownloadDisplay()
  } else {
    if (lerpHandle) {
      clearInterval(lerpHandle)
      lerpHandle = 0
    }
  }
}

async function poll() {
  try {
    status = await fetchStatus()
  } catch {
    // keep last known status
  }
  render()
}

render()
poll()
setInterval(poll, POLL_INTERVAL)
