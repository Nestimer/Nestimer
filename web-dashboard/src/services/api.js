const BASE = '/api/v1'

function getToken() {
  return localStorage.getItem('token')
}

async function request(path, options = {}) {
  const token = getToken()
  const headers = { 'Content-Type': 'application/json', ...options.headers }
  if (token) headers['Authorization'] = `Bearer ${token}`

  const res = await fetch(`${BASE}${path}`, { ...options, headers })

  if (res.status === 401) {
    localStorage.removeItem('token')
    window.location.href = '/login'
    throw new Error('Unauthorized')
  }

  if (!res.ok) {
    const data = await res.json().catch(() => ({}))
    throw new Error(data.detail || `HTTP ${res.status}`)
  }

  return res.json()
}

export const api = {
  // Auth
  register: (data) => request('/auth/register', { method: 'POST', body: JSON.stringify(data) }),
  login: (data) => request('/auth/login', { method: 'POST', body: JSON.stringify(data) }),
  me: () => request('/auth/me'),

  // Devices
  listDevices: () => request('/devices'),
  getDevice: (id) => request(`/devices/${id}`),
  createDevice: (data) => request('/devices', { method: 'POST', body: JSON.stringify(data) }),
  deleteDevice: (id) => request(`/devices/${id}`, { method: 'DELETE' }),

  // Policy
  getPolicy: (deviceId) => request(`/devices/${deviceId}/policy`),
  updatePolicy: (deviceId, data) => request(`/devices/${deviceId}/policy`, { method: 'PUT', body: JSON.stringify(data) }),

  // Usage
  getUsage: (deviceId, days = 7) => request(`/devices/${deviceId}/usage?days=${days}`),
}
