import React, { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'

export default function LoginPage() {
  const [tab, setTab] = useState('login')
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const { login, register, user } = useAuth()
  const navigate = useNavigate()

  if (user) {
    navigate('/')
    return null
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError('')
    setLoading(true)
    try {
      if (tab === 'login') {
        await login(email, password)
      } else {
        await register(name, email, password)
      }
      navigate('/')
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="login-page">
      <div className="card login-card">
        <h1>UsageTime</h1>
        <p className="subtitle">Родительский контроль для macOS</p>

        <div className="tab-switch">
          <button className={tab === 'login' ? 'active' : ''} onClick={() => setTab('login')}>Вход</button>
          <button className={tab === 'register' ? 'active' : ''} onClick={() => setTab('register')}>Регистрация</button>
        </div>

        <form onSubmit={handleSubmit}>
          {tab === 'register' && (
            <div className="form-group">
              <label>Имя</label>
              <input type="text" value={name} onChange={(e) => setName(e.target.value)} placeholder="Ваше имя" required />
            </div>
          )}
          <div className="form-group">
            <label>Email</label>
            <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="email@example.com" required />
          </div>
          <div className="form-group">
            <label>Пароль</label>
            <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="Пароль" required />
          </div>
          {error && <p className="error">{error}</p>}
          <button className="btn btn-primary" type="submit" disabled={loading}>
            {loading ? 'Подождите...' : (tab === 'login' ? 'Войти' : 'Создать аккаунт')}
          </button>
        </form>
      </div>
    </div>
  )
}
