import csrfFetch from '../../lib/api/csrf_fetch'

// Wake at the server's earliest notice deadline; retry offline tabs without
// restoring stale items locally. Destroy also invalidates in-flight responses.
export default class NoticeRefresh {
  constructor(url, apply) {
    this.url = url
    this.apply = apply
  }

  schedule(date) {
    const deadline = Date.parse(date)
    if (!Number.isFinite(deadline) || this.stopped || (Number.isFinite(this.deadline) && this.deadline <= deadline)) return
    clearTimeout(this.timer)
    this.deadline = deadline
    this.timer = setTimeout(() => this.refresh(), this.delayUntil(deadline))
  }

  delayUntil(deadline) {
    // Absolute server deadlines may still be pending when the client's clock is
    // ahead. Bound successful retries as well as network-failure retries.
    this.minimumDelay = this.lastDeadline === deadline ? Math.min(this.minimumDelay * 2, 60000) : 1000
    this.lastDeadline = deadline
    // Browser timers overflow beyond a signed 32-bit delay (about 25 days).
    return Math.min(2147483647, Math.max(this.minimumDelay, deadline - Date.now()))
  }

  async refresh() {
    this.deadline = null
    try {
      const response = await csrfFetch(this.url, { headers: { Accept: 'application/json' }, cache: 'no-store' })
      if (!response.ok) throw new Error('Notice refresh failed')
      const data = await response.json()
      if (this.stopped) return
      await this.apply(data.items)
      this.schedule(data.refresh_at)
    } catch {
      this.schedule(new Date(Date.now() + 60000).toISOString())
    }
  }

  destroy() {
    this.stopped = true
    clearTimeout(this.timer)
  }
}
