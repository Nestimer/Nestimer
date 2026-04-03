import React, { useState, useEffect, useCallback } from 'react'
import { useParams, Link } from 'react-router-dom'
import { api } from '../services/api'
import { generateTOTP, totpSecondsRemaining } from '../utils/totp'

function formatMinutes(m) {
  const h = Math.floor(m / 60)
  const min = Math.round(m % 60)
  if (h > 0) return `${h}h ${min}m`
  return `${min}m`
}

export default function DeviceDetailPage() {
  const { id } = useParams()
  const [device, setDevice] = useState(null)
  const [policy, setPolicy] = useState(null)
  const [usage, setUsage] = useState([])
  const [saving, setSaving] = useState(false)
  const [showToken, setShowToken] = useState(false)
  const [totpCode, setTotpCode] = useState(null)
  const [totpRemaining, setTotpRemaining] = useState(0)

  const load = useCallback(async () => {
    try {
      const [dev, pol, usg] = await Promise.all([
        api.getDevice(id),
        api.getPolicy(id),
        api.getUsage(id, 7),
      ])
      setDevice(dev)
      setPolicy(pol)
      setUsage(usg)
    } catch (e) { console.error(e) }
  }, [id])

  useEffect(() => { load() }, [load])

  // TOTP code generation
  useEffect(() => {
    if (!device?.shared_secret) return
    const update = async () => {
      try {
        const code = await generateTOTP(device.shared_secret)
        setTotpCode(code)
        setTotpRemaining(totpSecondsRemaining())
      } catch (e) { console.error('TOTP error:', e) }
    }
    update()
    const interval = setInterval(update, 1000)
    return () => clearInterval(interval)
  }, [device?.shared_secret])

  const savePolicy = async (updates) => {
    setSaving(true)
    try {
      const updated = await api.updatePolicy(id, updates)
      setPolicy(updated)
    } catch (e) { alert(e.message) }
    setSaving(false)
  }

  if (!device || !policy) return <div className="loading">Loading...</div>

  const todayUsage = usage.length > 0 ? usage[0] : null
  const usedMinutes = todayUsage ? todayUsage.total_minutes : 0
  const limitMinutes = policy.screen_time_limit_minutes || 120
  const usagePercent = limitMinutes > 0 ? Math.min(100, (usedMinutes / limitMinutes) * 100) : 0
  const barClass = usagePercent > 90 ? 'exceeded' : usagePercent > 70 ? 'warning' : 'ok'

  return (
    <div className="page">
      <Link to="/" className="back-link">&larr; All Devices</Link>

      <div className="header">
        <div>
          <h1>{device.name}</h1>
          <p style={{ color: '#86868b' }}>{device.child_name}</p>
        </div>
      </div>

      {/* Today's usage summary */}
      <div className="card">
        <h3>Today</h3>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
          <span style={{ fontSize: 32, fontWeight: 700 }}>{formatMinutes(usedMinutes)}</span>
          <span style={{ color: '#86868b' }}>of {formatMinutes(limitMinutes)}</span>
        </div>
        <div className="usage-bar">
          <div className={`usage-bar-fill ${barClass}`} style={{ width: `${usagePercent}%` }} />
        </div>
      </div>

      {/* Unlock code (TOTP) */}
      <h2 className="section-title">Unlock Code</h2>
      <div className="card">
        <p style={{ color: '#86868b', marginBottom: 12, fontSize: 14 }}>
          Tell this code to your child — unlocks for 30 minutes
        </p>
        {totpCode ? (
          <>
            <div style={{ fontSize: 48, fontWeight: 700, letterSpacing: 8, fontFamily: 'monospace', textAlign: 'center', padding: '12px 0' }}>
              {totpCode}
            </div>
            <div style={{ color: '#86868b', textAlign: 'center', marginTop: 8, fontSize: 13 }}>
              Valid for {Math.floor(totpRemaining / 60)}:{String(totpRemaining % 60).padStart(2, '0')}
            </div>
            <div style={{ height: 4, background: '#e5e5e5', borderRadius: 2, marginTop: 8 }}>
              <div style={{
                height: '100%', borderRadius: 2,
                background: '#007aff',
                width: `${(totpRemaining / 300) * 100}%`,
                transition: 'width 1s linear'
              }} />
            </div>
          </>
        ) : (
          <p style={{ color: '#86868b', textAlign: 'center' }}>Secret not configured</p>
        )}
      </div>

      {/* Downtime settings */}
      <h2 className="section-title">Downtime</h2>
      <div className="card">
        <div className="toggle-row">
          <div>
            <div className="toggle-label">Enable Downtime</div>
            <div className="toggle-sublabel">Computer is locked during this time</div>
          </div>
          <input
            type="checkbox"
            checked={policy.downtime_enabled}
            onChange={(e) => savePolicy({ downtime_enabled: e.target.checked })}
          />
        </div>

        {policy.downtime_enabled && (
          <>
            <div style={{ marginTop: 16 }}>
              <label style={{ fontSize: 14, color: '#86868b', display: 'block', marginBottom: 6 }}>
                Default schedule (every day)
              </label>
              <div className="time-inputs">
                <span>from</span>
                <input
                  type="time"
                  value={policy.downtime_start}
                  onChange={(e) => savePolicy({ downtime_start: e.target.value })}
                />
                <span>to</span>
                <input
                  type="time"
                  value={policy.downtime_end}
                  onChange={(e) => savePolicy({ downtime_end: e.target.value })}
                />
              </div>
            </div>

            <div style={{ marginTop: 16 }}>
              <label style={{ fontSize: 14, color: '#86868b', display: 'block', marginBottom: 6 }}>
                Weekdays (Mon-Fri) — if different
              </label>
              <div className="time-inputs">
                <span>from</span>
                <input
                  type="time"
                  value={policy.downtime_weekday_start || ''}
                  onChange={(e) => savePolicy({ downtime_weekday_start: e.target.value || policy.downtime_start })}
                />
                <span>to</span>
                <input
                  type="time"
                  value={policy.downtime_weekday_end || ''}
                  onChange={(e) => savePolicy({ downtime_weekday_end: e.target.value || policy.downtime_end })}
                />
              </div>
            </div>

            <div style={{ marginTop: 16 }}>
              <label style={{ fontSize: 14, color: '#86868b', display: 'block', marginBottom: 6 }}>
                Weekends (Sat-Sun) — if different
              </label>
              <div className="time-inputs">
                <span>from</span>
                <input
                  type="time"
                  value={policy.downtime_weekend_start || ''}
                  onChange={(e) => savePolicy({ downtime_weekend_start: e.target.value || policy.downtime_start })}
                />
                <span>to</span>
                <input
                  type="time"
                  value={policy.downtime_weekend_end || ''}
                  onChange={(e) => savePolicy({ downtime_weekend_end: e.target.value || policy.downtime_end })}
                />
              </div>
            </div>
          </>
        )}
      </div>

      {/* Screen time settings */}
      <h2 className="section-title">Screen Time</h2>
      <div className="card">
        <div className="toggle-row">
          <div>
            <div className="toggle-label">Screen Time Limit</div>
            <div className="toggle-sublabel">Max minutes per day (outside downtime)</div>
          </div>
          <input
            type="checkbox"
            checked={policy.screen_time_enabled}
            onChange={(e) => savePolicy({ screen_time_enabled: e.target.checked })}
          />
        </div>

        {policy.screen_time_enabled && (
          <>
            <div style={{ marginTop: 16 }}>
              <label style={{ fontSize: 14, color: '#86868b', display: 'block', marginBottom: 6 }}>
                Weekday limit
              </label>
              <div className="minutes-input">
                <input
                  type="number"
                  min="15"
                  max="1440"
                  step="15"
                  value={policy.screen_time_limit_minutes}
                  onChange={(e) => savePolicy({ screen_time_limit_minutes: parseInt(e.target.value) || 120 })}
                />
                <span className="unit">minutes ({formatMinutes(policy.screen_time_limit_minutes)})</span>
              </div>
            </div>

            <div style={{ marginTop: 16 }}>
              <label style={{ fontSize: 14, color: '#86868b', display: 'block', marginBottom: 6 }}>
                Weekend limit (leave empty = same as weekdays)
              </label>
              <div className="minutes-input">
                <input
                  type="number"
                  min="15"
                  max="1440"
                  step="15"
                  value={policy.screen_time_weekend_limit_minutes || ''}
                  placeholder={String(policy.screen_time_limit_minutes)}
                  onChange={(e) => savePolicy({ screen_time_weekend_limit_minutes: parseInt(e.target.value) || null })}
                />
                <span className="unit">minutes</span>
              </div>
            </div>
          </>
        )}
      </div>

      {/* Usage history */}
      <h2 className="section-title">This Week</h2>
      <div className="card">
        {usage.length === 0 ? (
          <p style={{ color: '#86868b' }}>No data yet</p>
        ) : (
          <div className="usage-stats">
            {usage.map(u => (
              <div key={u.date} className="usage-day">
                <div className="date">{new Date(u.date + 'T00:00').toLocaleDateString('en', { weekday: 'short', day: 'numeric' })}</div>
                <div className="time">{formatMinutes(u.total_minutes)}</div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Device token (hidden by default) */}
      <h2 className="section-title">Device Settings</h2>
      <div className="card">
        <div className="toggle-row">
          <div className="toggle-label">Agent API Token</div>
          <button className="btn btn-secondary btn-small" onClick={() => setShowToken(!showToken)}>
            {showToken ? 'Hide' : 'Show'}
          </button>
        </div>
        {showToken && <div className="token-display">{device.api_token}</div>}
      </div>

      {saving && <p style={{ textAlign: 'center', color: '#86868b', marginTop: 16 }}>Saving...</p>}
    </div>
  )
}
