import React, { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { api } from '../services/api'

function timeSince(dateStr) {
  if (!dateStr) return 'никогда'
  const diff = (Date.now() - new Date(dateStr).getTime()) / 1000
  if (diff < 120) return 'только что'
  if (diff < 3600) return `${Math.floor(diff / 60)} мин назад`
  if (diff < 86400) return `${Math.floor(diff / 3600)} ч назад`
  return `${Math.floor(diff / 86400)} дн назад`
}

function isOnline(dateStr) {
  if (!dateStr) return false
  return (Date.now() - new Date(dateStr).getTime()) < 3 * 60 * 1000 // 3 min
}

export default function DevicesPage() {
  const { user, logout } = useAuth()
  const navigate = useNavigate()
  const [devices, setDevices] = useState([])
  const [showAdd, setShowAdd] = useState(false)
  const [newName, setNewName] = useState('')
  const [childName, setChildName] = useState('')
  const [newToken, setNewToken] = useState('')

  useEffect(() => { loadDevices() }, [])

  const loadDevices = async () => {
    try {
      const data = await api.listDevices()
      setDevices(data)
    } catch (e) { console.error(e) }
  }

  const addDevice = async (e) => {
    e.preventDefault()
    try {
      const device = await api.createDevice({ name: newName, child_name: childName })
      setNewToken(device.api_token)
      setDevices([...devices, { id: device.id, name: device.name, child_name: device.child_name, last_seen: null }])
      setNewName('')
      setChildName('')
    } catch (e) { alert(e.message) }
  }

  return (
    <div className="page">
      <div className="header">
        <h1>Устройства</h1>
        <div style={{ display: 'flex', gap: 8 }}>
          <button className="btn btn-primary btn-small" onClick={() => { setShowAdd(!showAdd); setNewToken('') }}>
            + Добавить
          </button>
          <button className="btn btn-secondary btn-small" onClick={logout}>Выйти</button>
        </div>
      </div>

      {showAdd && (
        <div className="card">
          <h3>Новое устройство</h3>
          {!newToken ? (
            <form onSubmit={addDevice}>
              <div className="form-group">
                <label>Название устройства</label>
                <input type="text" value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="MacBook Миши" required />
              </div>
              <div className="form-group">
                <label>Имя ребёнка</label>
                <input type="text" value={childName} onChange={(e) => setChildName(e.target.value)} placeholder="Миша" required />
              </div>
              <button className="btn btn-primary" type="submit">Создать</button>
            </form>
          ) : (
            <div>
              <p style={{ marginBottom: 8 }}>Устройство создано! Используйте этот токен при установке агента на Mac ребёнка:</p>
              <div className="token-display">{newToken}</div>
              <p style={{ marginTop: 12, fontSize: 13, color: '#86868b' }}>
                Скопируйте этот токен — он понадобится при запуске install.sh на Mac ребёнка.
                Токен также доступен на странице устройства.
              </p>
              <button className="btn btn-secondary btn-small" style={{ marginTop: 12 }} onClick={() => { setShowAdd(false); setNewToken('') }}>
                Готово
              </button>
            </div>
          )}
        </div>
      )}

      {devices.length === 0 && !showAdd && (
        <div className="card" style={{ textAlign: 'center', padding: 40 }}>
          <p style={{ fontSize: 18, marginBottom: 8 }}>Нет устройств</p>
          <p style={{ color: '#86868b' }}>Добавьте Mac ребёнка, чтобы начать контроль</p>
        </div>
      )}

      {devices.map(device => (
        <div key={device.id} className="card device-card" onClick={() => navigate(`/devices/${device.id}`)}>
          <div className="device-info">
            <h3>{device.name}</h3>
            <p className="child-name">{device.child_name}</p>
          </div>
          <div className="device-status">
            <span className={`status-dot ${isOnline(device.last_seen) ? 'status-online' : 'status-offline'}`}></span>
            {isOnline(device.last_seen) ? 'Онлайн' : timeSince(device.last_seen)}
          </div>
        </div>
      ))}
    </div>
  )
}
