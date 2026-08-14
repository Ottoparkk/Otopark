import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { BrowserRouter } from 'react-router'
import App from './App'
import { AuthProvider } from './app/providers/AuthProvider'
import { initTheme } from './lib/theme'
import './styles/index.css'

initTheme()

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // Occupancy and open tickets change constantly; a stale list at a
      // barrier is worse than a brief spinner.
      staleTime: 15_000,
      refetchOnWindowFocus: true,
      retry: 1,
    },
    mutations: {
      // OFF by default, ON per mutation. Silently retrying a money-moving
      // call is how double charges happen: an entry write should retry, a
      // payment collection must not. The operator is standing right there
      // and can simply tap again.
      retry: false,
    },
  },
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter basename="/Otopark">
          <App />
        </BrowserRouter>
      </AuthProvider>
    </QueryClientProvider>
  </StrictMode>,
)
