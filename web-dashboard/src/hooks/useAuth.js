import { useState, useEffect, createContext, useContext } from 'react'
import { api } from '../services/api'

const AuthContext = createContext(null)

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const token = localStorage.getItem('token')
    if (token) {
      api.me().then(setUser).catch(() => localStorage.removeItem('token')).finally(() => setLoading(false))
    } else {
      setLoading(false)
    }
  }, [])

  const login = async (email, password) => {
    const { access_token } = await api.login({ email, password })
    localStorage.setItem('token', access_token)
    const u = await api.me()
    setUser(u)
  }

  const register = async (name, email, password) => {
    const { access_token } = await api.register({ name, email, password })
    localStorage.setItem('token', access_token)
    const u = await api.me()
    setUser(u)
  }

  const logout = () => {
    localStorage.removeItem('token')
    setUser(null)
  }

  return (
    <AuthContext.Provider value={{ user, loading, login, register, logout }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  return useContext(AuthContext)
}
