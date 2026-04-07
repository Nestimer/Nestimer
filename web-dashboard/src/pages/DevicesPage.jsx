import React, { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { api } from '../services/api'

function timeSince(dateStr) {
  if (!dateStr) return 'never'
  const diff = (Date.now() - new Date(dateStr).getTime()) / 1000
  if (diff < 120) return 'just now'
  if (diff < 3600) return `${Math.floor(diff / 60)} min ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)} hr ago`
  return `${Math.floor(diff / 86400)} days ago`
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
        <h1>Devices</h1>
        <div style={{ display: 'flex', gap: 8 }}>
          <button className="btn btn-primary btn-small" onClick={() => { setShowAdd(!showAdd); setNewToken('') }}>
            + Add Device
          </button>
          <button className="btn btn-secondary btn-small" onClick={logout}>Sign Out</button>
        </div>
      </div>

      {showAdd && (
        <div className="card">
          <h3>New Device</h3>
          {!newToken ? (
            <form onSubmit={addDevice}>
              <div className="form-group">
                <label>Device Name</label>
                <input type="text" value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="Alex's MacBook" required />
              </div>
              <div className="form-group">
                <label>Child's Name</label>
                <input type="text" value={childName} onChange={(e) => setChildName(e.target.value)} placeholder="Alex" required />
              </div>
              <button className="btn btn-primary" type="submit">Create</button>
            </form>
          ) : (
            <div>
              <p style={{ marginBottom: 8, fontWeight: 500 }}>Device created! Paste this into the agent app on the child's Mac:</p>
              <div className="token-display" style={{ fontSize: 13, userSelect: 'all', cursor: 'pointer' }}
                onClick={(e) => { navigator.clipboard.writeText(e.target.textContent) }}>
                {`http://${window.location.hostname}:8000|${newToken}`}
              </div>
              <p style={{ marginTop: 8, fontSize: 12, color: '#86868b' }}>
                Click to copy. Paste this single line when the agent asks for setup string.
              </p>
              <button className="btn btn-secondary btn-small" style={{ marginTop: 12 }} onClick={() => { setShowAdd(false); setNewToken('') }}>
                Done
              </button>
            </div>
          )}
        </div>
      )}

      {devices.length === 0 && !showAdd && (
        <div className="card" style={{ textAlign: 'center', padding: 40 }}>
          <p style={{ fontSize: 18, marginBottom: 8 }}>No devices</p>
          <p style={{ color: '#86868b' }}>Add your child's Mac to start monitoring</p>
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
            {isOnline(device.last_seen) ? 'Online' : timeSince(device.last_seen)}
            {device.agent_version && <div style={{ fontSize: 11, color: '#86868b', marginTop: 2 }}>v{device.agent_version}</div>}
          </div>
        </div>
      ))}
    </div>
  )
}
