import React, { useState, useEffect, useCallback } from 'react'
import { useParams, Link } from 'react-router-dom'
import { api } from '../services/api'

function formatMinutes(m) {
  const h = Math.floor(m / 60)
  const min = Math.round(m % 60)
  if (h > 0) return `${h}ч ${min}м`
  return `${min}м`
}

export default function DeviceDetailPage() {
  const { id } = useParams()
  const [device, setDevice] = useState(null)
  const [policy, setPolicy] = useState(null)
  const [usage, setUsage] = useState([])
  const [saving, setSaving] = useState(false)
  const [showToken, setShowToken] = useState(false)

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

  const savePolicy = async (updates) => {
    setSaving(true)
    try {
      const updated = await api.updatePolicy(id, updates)
      setPolicy(updated)
    } catch (e) { alert(e.message) }
    setSaving(false)
  }

  if (!device || !policy) return <div className="loading">Загрузка...</div>

  const todayUsage = usage.length > 0 ? usage[0] : null
  const usedMinutes = todayUsage ? todayUsage.total_minutes : 0
  const limitMinutes = policy.screen_time_limit_minutes || 120
  const usagePercent = limitMinutes > 0 ? Math.min(100, (usedMinutes / limitMinutes) * 100) : 0
  const barClass = usagePercent > 90 ? 'exceeded' : usagePercent > 70 ? 'warning' : 'ok'

  return (
    <div className="page">
      <Link to="/" className="back-link">&larr; Все устройства</Link>

      <div className="header">
        <div>
          <h1>{device.name}</h1>
          <p style={{ color: '#86868b' }}>{device.child_name}</p>
        </div>
      </div>

      {/* Today's usage summary */}
      <div className="card">
        <h3>Сегодня</h3>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
          <span style={{ fontSize: 32, fontWeight: 700 }}>{formatMinutes(usedMinutes)}</span>
          <span style={{ color: '#86868b' }}>из {formatMinutes(limitMinutes)}</span>
        </div>
        <div className="usage-bar">
          <div className={`usage-bar-fill ${barClass}`} style={{ width: `${usagePercent}%` }} />
        </div>
      </div>

      {/* Downtime settings */}
      <h2 className="section-title">Время отдыха (Downtime)</h2>
      <div className="card">
        <div className="toggle-row">
          <div>
            <div className="toggle-label">Включить даунтайм</div>
            <div className="toggle-sublabel">Компьютер заблокирован в это время</div>
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
                Основное расписание (каждый день)
              </label>
              <div className="time-inputs">
                <span>с</span>
                <input
                  type="time"
                  value={policy.downtime_start}
                  onChange={(e) => savePolicy({ downtime_start: e.target.value })}
                />
                <span>до</span>
                <input
                  type="time"
                  value={policy.downtime_end}
                  onChange={(e) => savePolicy({ downtime_end: e.target.value })}
                />
              </div>
            </div>

            <div style={{ marginTop: 16 }}>
              <label style={{ fontSize: 14, color: '#86868b', display: 'block', marginBottom: 6 }}>
                Будни (Пн-Пт) — если отличается
              </label>
              <div className="time-inputs">
                <span>с</span>
                <input
                  type="time"
                  value={policy.downtime_weekday_start || ''}
                  onChange={(e) => savePolicy({ downtime_weekday_start: e.target.value || policy.downtime_start })}
                />
                <span>до</span>
                <input
                  type="time"
                  value={policy.downtime_weekday_end || ''}
                  onChange={(e) => savePolicy({ downtime_weekday_end: e.target.value || policy.downtime_end })}
                />
              </div>
            </div>

            <div style={{ marginTop: 16 }}>
              <label style={{ fontSize: 14, color: '#86868b', display: 'block', marginBottom: 6 }}>
                Выходные (Сб-Вс) — если отличается
              </label>
              <div className="time-inputs">
                <span>с</span>
                <input
                  type="time"
                  value={policy.downtime_weekend_start || ''}
                  onChange={(e) => savePolicy({ downtime_weekend_start: e.target.value || policy.downtime_start })}
                />
                <span>до</span>
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
      <h2 className="section-title">Экранное время</h2>
      <div className="card">
        <div className="toggle-row">
          <div>
            <div className="toggle-label">Лимит экранного времени</div>
            <div className="toggle-sublabel">Максимум минут за день (вне даунтайма)</div>
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
                Лимит в будни
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
                <span className="unit">минут ({formatMinutes(policy.screen_time_limit_minutes)})</span>
              </div>
            </div>

            <div style={{ marginTop: 16 }}>
              <label style={{ fontSize: 14, color: '#86868b', display: 'block', marginBottom: 6 }}>
                Лимит в выходные (оставьте пустым = как в будни)
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
                <span className="unit">минут</span>
              </div>
            </div>
          </>
        )}
      </div>

      {/* Usage history */}
      <h2 className="section-title">История за неделю</h2>
      <div className="card">
        {usage.length === 0 ? (
          <p style={{ color: '#86868b' }}>Данных пока нет</p>
        ) : (
          <div className="usage-stats">
            {usage.map(u => (
              <div key={u.date} className="usage-day">
                <div className="date">{new Date(u.date + 'T00:00').toLocaleDateString('ru', { weekday: 'short', day: 'numeric' })}</div>
                <div className="time">{formatMinutes(u.total_minutes)}</div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Device token (hidden by default) */}
      <h2 className="section-title">Настройки устройства</h2>
      <div className="card">
        <div className="toggle-row">
          <div className="toggle-label">API токен агента</div>
          <button className="btn btn-secondary btn-small" onClick={() => setShowToken(!showToken)}>
            {showToken ? 'Скрыть' : 'Показать'}
          </button>
        </div>
        {showToken && <div className="token-display">{device.api_token}</div>}
      </div>

      {saving && <p style={{ textAlign: 'center', color: '#86868b', marginTop: 16 }}>Сохранение...</p>}
    </div>
  )
}
