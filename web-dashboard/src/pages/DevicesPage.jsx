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

// A device is stale when it hasn't reported in over 15 minutes — the compensating
// control for platforms the agent can't forcibly lock: a bypass stops being invisible.
const STALE_AFTER_MS = 15 * 60 * 1000

function isStale(device) {
  return !device.last_seen || (Date.now() - new Date(device.last_seen).getTime()) > STALE_AFTER_MS
}

function staleLabel(device) {
  if (!device.last_seen) return 'Never reported'
  const seen = new Date(device.last_seen)
  const hh = String(seen.getHours()).padStart(2, '0')
  const mm = String(seen.getMinutes()).padStart(2, '0')
  return `Not reporting since ${hh}:${mm}`
}

// One shared daily budget per child, across all their devices. Group the device
// list by child so that's visible; devices without a child yet — or when the
// children list failed to load — go in a trailing "Unassigned" group instead of
// vanishing.
function groupByChild(devices, children) {
  const byId = new Map(children.map((c) => [c.id, { child: c, devices: [] }]))
  const orphans = []
  for (const device of devices) {
    const group = byId.get(device.child_id)
    if (group) group.devices.push(device)
    else orphans.push(device)
  }
  const groups = [...byId.values()].filter((g) => g.devices.length > 0)
  if (orphans.length) groups.push({ child: { id: null, name: 'Unassigned' }, devices: orphans })
  return groups
}

export default function DevicesPage() {
  const { user, logout } = useAuth()
  const navigate = useNavigate()
  const [devices, setDevices] = useState([])
  const [children, setChildren] = useState([])
  const [childrenError, setChildrenError] = useState('')
  const [showAdd, setShowAdd] = useState(false)
  const [newName, setNewName] = useState('')
  const [childName, setChildName] = useState('')
  const [newToken, setNewToken] = useState('')
  const [showAddChild, setShowAddChild] = useState(false)
  const [newChildName, setNewChildName] = useState('')
  const [creatingChild, setCreatingChild] = useState(false)
  const [renamingChildId, setRenamingChildId] = useState(null)
  const [renameValue, setRenameValue] = useState('')
  const [savingRename, setSavingRename] = useState(false)

  useEffect(() => { loadDevices(); loadChildren() }, [])

  // Devices and children are loaded independently: this is the page a parent uses
  // to see and control their child's machines, so a failing /children request must
  // not blank out devices that loaded fine. It degrades to an ungrouped list plus a
  // non-blocking notice instead.
  const loadDevices = async () => {
    try {
      const devs = await api.listDevices()
      setDevices(devs)
    } catch (e) { console.error(e) }
  }

  const loadChildren = async () => {
    try {
      const kids = await api.listChildren()
      setChildren(kids)
      setChildrenError('')
    } catch (e) {
      console.error(e)
      setChildren([])
      setChildrenError('Could not load children — showing devices ungrouped.')
    }
  }

  const addDevice = async (e) => {
    e.preventDefault()
    try {
      const device = await api.createDevice({ name: newName, child_name: childName })
      setNewToken(device.api_token)
      setNewName('')
      setChildName('')
      loadDevices()
      loadChildren()
    } catch (e) { alert(e.message) }
  }

  const addChild = async (e) => {
    e.preventDefault()
    if (!newChildName.trim()) return
    setCreatingChild(true)
    try {
      await api.createChild(newChildName.trim())
      setNewChildName('')
      setShowAddChild(false)
      loadChildren()
    } catch (e) { alert(e.message) }
    setCreatingChild(false)
  }

  const startRenameChild = (child) => {
    setRenamingChildId(child.id)
    setRenameValue(child.name)
  }

  const saveRenameChild = async (childId) => {
    if (!renameValue.trim()) return
    setSavingRename(true)
    try {
      await api.renameChild(childId, renameValue.trim())
      setRenamingChildId(null)
      loadChildren()
    } catch (e) { alert(e.message) }
    setSavingRename(false)
  }

  return (
    <div className="page">
      <div className="header">
        <h1>Devices</h1>
        <div style={{ display: 'flex', gap: 8 }}>
          <button className="btn btn-secondary btn-small" onClick={() => setShowAddChild(!showAddChild)}>
            + Add Child
          </button>
          <button className="btn btn-primary btn-small" onClick={() => { setShowAdd(!showAdd); setNewToken('') }}>
            + Add Device
          </button>
          <button className="btn btn-secondary btn-small" onClick={logout}>Sign Out</button>
        </div>
      </div>

      {showAddChild && (
        <div className="card">
          <h3>New Child</h3>
          <form onSubmit={addChild}>
            <div className="form-group">
              <label>Name</label>
              <input type="text" value={newChildName} onChange={(e) => setNewChildName(e.target.value)} placeholder="Alex" required />
            </div>
            <button className="btn btn-primary" type="submit" disabled={creatingChild}>Create</button>
          </form>
        </div>
      )}

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
                {`${window.location.origin}|${newToken}`}
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

      {childrenError && <p className="error">{childrenError}</p>}

      {devices.length === 0 && !showAdd && (
        <div className="card" style={{ textAlign: 'center', padding: 40 }}>
          <p style={{ fontSize: 18, marginBottom: 8 }}>No devices</p>
          <p style={{ color: '#86868b' }}>Add your child's Mac to start monitoring</p>
        </div>
      )}

      {groupByChild(devices, children).map(({ child, devices: childDevices }) => (
        <div key={child.id ?? 'unassigned'}>
          {child.id && renamingChildId === child.id ? (
            <div style={{ display: 'flex', gap: 8, alignItems: 'center', margin: '24px 0 12px' }}>
              <input
                type="text"
                value={renameValue}
                onChange={(e) => setRenameValue(e.target.value)}
                maxLength={100}
                autoFocus
                style={{ fontSize: 18, fontWeight: 600, padding: '6px 10px', border: '1px solid #d2d2d7', borderRadius: 8 }}
              />
              <button className="btn btn-primary btn-small" disabled={savingRename || !renameValue.trim()} onClick={() => saveRenameChild(child.id)}>Save</button>
              <button className="btn btn-secondary btn-small" onClick={() => setRenamingChildId(null)}>Cancel</button>
            </div>
          ) : (
            <div className="section-title" style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              <span>{child.name}</span>
              {child.id && (
                <button className="btn btn-secondary btn-small" onClick={() => startRenameChild(child)}>Edit</button>
              )}
            </div>
          )}
          {childDevices.map(device => (
            <div key={device.id} className="card device-card" onClick={() => navigate(`/devices/${device.id}`)}>
              <div className="device-info">
                <h3>{device.name}</h3>
                <p className="child-name">{device.child_name}</p>
              </div>
              <div className="device-status">
                <span className={`status-dot ${isOnline(device.last_seen) ? 'status-online' : 'status-offline'}`}></span>
                {isOnline(device.last_seen) ? 'Online' : timeSince(device.last_seen)}
                {device.agent_version && <div style={{ fontSize: 11, color: '#86868b', marginTop: 2 }}>v{device.agent_version}</div>}
                {isStale(device) && (
                  <div style={{ fontSize: 11, color: '#ff9500', fontWeight: 600, marginTop: 4 }}>
                    {staleLabel(device)}
                  </div>
                )}
              </div>
            </div>
          ))}
        </div>
      ))}
    </div>
  )
}
