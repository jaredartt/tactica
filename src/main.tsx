import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import { Boundary } from './components/Boundary'
import './styles.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <Boundary>
      <App />
    </Boundary>
  </React.StrictMode>,
)
