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
  const [activities, setActivities] = useState([])
  const [newActivity, setNewActivity] = useState(null)

  const load = useCallback(async () => {
    try {
      const [dev, pol, usg, acts] = await Promise.all([
        api.getDevice(id),
        api.getPolicy(id),
        api.getUsage(id, 7),
        api.listActivities(id),
      ])
      setDevice(dev)
      setPolicy(pol)
      setUsage(usg)
      setActivities(acts)
    } catch (e) { console.error(e) }
  }, [id])

  useEffect(() => { load() }, [load])

  // TOTP code generation
  useEffect(() => {
    if (!device?.shared_secret) return
    const update = () => {
      try {
        setTotpCode(generateTOTP(device.shared_secret))
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
          <div style={{ textAlign: 'center' }}>
            <p style={{ color: '#86868b', marginBottom: 12 }}>Secret not configured</p>
            <button className="btn btn-primary btn-small" onClick={async () => {
              try {
                const updated = await api.regenerateSecret(id)
                setDevice(updated)
              } catch (e) { alert(e.message) }
            }}>Generate Secret</button>
          </div>
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
                  min="1"
                  max="1440"
                  step="1"
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
                  min="1"
                  max="1440"
                  step="1"
                  value={policy.screen_time_weekend_limit_minutes || ''}
                  placeholder={String(policy.screen_time_limit_minutes)}
                  onChange={(e) => savePolicy({ screen_time_weekend_limit_minutes: parseInt(e.target.value) || null })}
                />
                <span className="unit">minutes</span>
              </div>
            </div>

            <div style={{ marginTop: 16 }}>
              <label style={{ fontSize: 14, color: '#86868b', display: 'block', marginBottom: 6 }}>
                Per day overrides (leave empty = use weekday/weekend default)
              </label>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(140px, 1fr))', gap: 8 }}>
                {[
                  { key: 'mon', label: 'Mon', idx: 0 },
                  { key: 'tue', label: 'Tue', idx: 1 },
                  { key: 'wed', label: 'Wed', idx: 2 },
                  { key: 'thu', label: 'Thu', idx: 3 },
                  { key: 'fri', label: 'Fri', idx: 4 },
                  { key: 'sat', label: 'Sat', idx: 5 },
                  { key: 'sun', label: 'Sun', idx: 6 },
                ].map(day => {
                  const field = `screen_time_${day.key}_minutes`
                  const fallback = (day.idx >= 5 ? policy.screen_time_weekend_limit_minutes : null) || policy.screen_time_limit_minutes
                  return (
                    <div key={day.key} style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                      <span style={{ fontSize: 13, color: '#86868b', width: 32 }}>{day.label}</span>
                      <input
                        type="number"
                        min="1"
                        max="1440"
                        step="1"
                        style={{ width: 70, padding: '6px 8px', border: '1px solid #d2d2d7', borderRadius: 8, fontSize: 14 }}
                        value={policy[field] || ''}
                        placeholder={String(fallback)}
                        onChange={(e) => savePolicy({ [field]: parseInt(e.target.value) || null })}
                      />
                      <span style={{ fontSize: 12, color: '#86868b' }}>m</span>
                    </div>
                  )
                })}
              </div>
            </div>
          </>
        )}
      </div>

      {/* Scheduled activities */}
      <h2 className="section-title">Scheduled Activities</h2>
      <div className="card">
        <p style={{ color: '#86868b', fontSize: 13, marginBottom: 12 }}>
          Time within these windows (including buffer) is not counted toward screen time, and the computer is unlocked even during downtime.
        </p>
        {activities.length === 0 && !newActivity && (
          <p style={{ color: '#86868b', textAlign: 'center', padding: '12px 0' }}>No activities yet</p>
        )}
        {activities.map(a => {
          const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
          return (
            <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '8px 0', borderBottom: '1px solid #f5f5f7' }}>
              <input type="checkbox" checked={a.enabled} onChange={async (e) => {
                try { const upd = await api.updateActivity(id, a.id, { enabled: e.target.checked }); setActivities(activities.map(x => x.id === a.id ? upd : x)) } catch (err) { alert(err.message) }
              }} />
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 500 }}>{a.name}</div>
                <div style={{ fontSize: 12, color: '#86868b' }}>
                  {days[a.day_of_week]} {a.start_time}–{a.end_time} (±{a.buffer_before_minutes}m)
                </div>
              </div>
              <button className="btn btn-secondary btn-small" onClick={async () => {
                if (!confirm(`Delete activity "${a.name}"?`)) return
                try { await api.deleteActivity(id, a.id); setActivities(activities.filter(x => x.id !== a.id)) } catch (err) { alert(err.message) }
              }}>Delete</button>
            </div>
          )
        })}
        {newActivity ? (
          <div style={{ padding: '12px 0', borderTop: activities.length > 0 ? '1px solid #f5f5f7' : 'none' }}>
            <div className="form-group">
              <label>Name</label>
              <input type="text" value={newActivity.name} onChange={e => setNewActivity({ ...newActivity, name: e.target.value })} placeholder="English" />
            </div>
            <div className="form-group">
              <label>Day</label>
              <select value={newActivity.day_of_week} onChange={e => setNewActivity({ ...newActivity, day_of_week: parseInt(e.target.value) })}
                style={{ width: '100%', padding: 10, border: '1px solid #d2d2d7', borderRadius: 10, fontSize: 16 }}>
                <option value={0}>Monday</option>
                <option value={1}>Tuesday</option>
                <option value={2}>Wednesday</option>
                <option value={3}>Thursday</option>
                <option value={4}>Friday</option>
                <option value={5}>Saturday</option>
                <option value={6}>Sunday</option>
              </select>
            </div>
            <div style={{ display: 'flex', gap: 12 }}>
              <div className="form-group" style={{ flex: 1 }}>
                <label>Start</label>
                <input type="time" value={newActivity.start_time} onChange={e => setNewActivity({ ...newActivity, start_time: e.target.value })} />
              </div>
              <div className="form-group" style={{ flex: 1 }}>
                <label>End</label>
                <input type="time" value={newActivity.end_time} onChange={e => setNewActivity({ ...newActivity, end_time: e.target.value })} />
              </div>
            </div>
            <div style={{ display: 'flex', gap: 12 }}>
              <div className="form-group" style={{ flex: 1 }}>
                <label>Buffer before (min)</label>
                <input type="number" min="0" max="60" value={newActivity.buffer_before_minutes} onChange={e => setNewActivity({ ...newActivity, buffer_before_minutes: parseInt(e.target.value) || 0 })} />
              </div>
              <div className="form-group" style={{ flex: 1 }}>
                <label>Buffer after (min)</label>
                <input type="number" min="0" max="60" value={newActivity.buffer_after_minutes} onChange={e => setNewActivity({ ...newActivity, buffer_after_minutes: parseInt(e.target.value) || 0 })} />
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
              <button className="btn btn-primary btn-small" onClick={async () => {
                try { const created = await api.createActivity(id, newActivity); setActivities([...activities, created]); setNewActivity(null) } catch (err) { alert(err.message) }
              }}>Create</button>
              <button className="btn btn-secondary btn-small" onClick={() => setNewActivity(null)}>Cancel</button>
            </div>
          </div>
        ) : (
          <button className="btn btn-secondary btn-small" style={{ marginTop: 8 }} onClick={() => setNewActivity({
            name: '', day_of_week: 0, start_time: '16:00', end_time: '17:00', buffer_before_minutes: 5, buffer_after_minutes: 5, enabled: true
          })}>+ Add Activity</button>
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

      {/* Device info */}
      <h2 className="section-title">Device Settings</h2>
      <div className="card">
        {device.agent_version && (
          <div className="toggle-row">
            <div className="toggle-label">Agent Version</div>
            <div style={{ fontWeight: 500 }}>v{device.agent_version}</div>
          </div>
        )}
        <div className="toggle-row">
          <div className="toggle-label">Agent Setup String</div>
          <button className="btn btn-secondary btn-small" onClick={() => setShowToken(!showToken)}>
            {showToken ? 'Hide' : 'Show'}
          </button>
        </div>
        {showToken && (
          <div className="token-display" style={{ cursor: 'pointer', userSelect: 'all' }}
            onClick={(e) => { navigator.clipboard.writeText(e.target.textContent) }}>
            {`http://${window.location.hostname}:8000|${device.api_token}`}
          </div>
        )}
        {showToken && <p style={{ fontSize: 12, color: '#86868b', marginTop: 6 }}>Click to copy</p>}
      </div>

      {saving && <p style={{ textAlign: 'center', color: '#86868b', marginTop: 16 }}>Saving...</p>}
    </div>
  )
}
