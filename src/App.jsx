import { useEffect, useRef, useState } from 'react'

const STORAGE_KEY = 'codex-local-thread'

function messagesMatch(left, right) {
  if (left.length !== right.length) return false
  return left.every((message, index) => message.role === right[index]?.role && message.text === right[index]?.text)
}

function Icon({ name, size = 18 }) {
  const paths = {
    plus: <><path d="M12 5v14M5 12h14" /></>,
    send: <><path d="m22 2-7 20-4-9-9-4Z" /><path d="M22 2 11 13" /></>,
    terminal: <><path d="m4 17 6-6-6-6" /><path d="M12 19h8" /></>,
    code: <><path d="m8 9-4 3 4 3M16 9l4 3-4 3M14 5l-4 14" /></>,
    spark: <><path d="m12 3 1.4 4.1L17.5 8.5l-4.1 1.4L12 14l-1.4-4.1-4.1-1.4 4.1-1.4Z" /><path d="m19 15 .8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8Z" /></>,
    panel: <><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M9 4v16" /></>,
    stop: <><rect x="6" y="6" width="12" height="12" rx="2" /></>,
    copy: <><rect x="9" y="9" width="11" height="11" rx="2" /><path d="M15 9V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h3" /></>,
    check: <><path d="m5 12 4 4L19 6" /></>,
  }
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>
}

function RichText({ text }) {
  const parts = text.split(/(```[\s\S]*?```)/g)
  return <div className="rich-text">{parts.map((part, index) => {
    if (!part.startsWith('```')) return part.split('\n\n').map((p, i) => <p key={`${index}-${i}`}>{renderInline(p)}</p>)
    const body = part.slice(3, -3)
    const firstBreak = body.indexOf('\n')
    const language = firstBreak > -1 ? body.slice(0, firstBreak).trim() : ''
    const code = firstBreak > -1 ? body.slice(firstBreak + 1) : body
    return <CodeBlock key={index} code={code} language={language} />
  })}</div>
}

function renderInline(text) {
  const tokens = text.split(/(`[^`]+`|\*\*[^*]+\*\*)/g)
  return tokens.map((token, i) => {
    if (token.startsWith('`')) return <code key={i}>{token.slice(1, -1)}</code>
    if (token.startsWith('**')) return <strong key={i}>{token.slice(2, -2)}</strong>
    return <span key={i}>{token}</span>
  })
}

function CodeBlock({ code, language }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    await navigator.clipboard.writeText(code)
    setCopied(true)
    setTimeout(() => setCopied(false), 1200)
  }
  return <div className="code-block">
    <div className="code-head"><span>{language || 'code'}</span><button onClick={copy}><Icon name={copied ? 'check' : 'copy'} size={14} />{copied ? 'Copied' : 'Copy'}</button></div>
    <pre><code>{code}</code></pre>
  </div>
}

function EmptyState({ onPrompt }) {
  const prompts = [
    ['Explore this codebase', 'Map the architecture and important entry points.'],
    ['Build a feature', 'Describe what you want changed and Codex can implement it.'],
    ['Debug an issue', 'Share an error or unexpected behavior to investigate.'],
  ]
  return <div className="empty-state">
    <div className="mark"><Icon name="spark" size={28} /></div>
    <p className="eyebrow">LOCAL WORKSPACE AGENT</p>
    <h1>What should we build?</h1>
    <p className="intro">Chat with Codex in this workspace. It can read files, run commands, and make changes while you watch.</p>
    <div className="prompt-grid">
      {prompts.map(([title, body]) => <button key={title} onClick={() => onPrompt(body)}><span>{title}</span><small>{body}</small></button>)}
    </div>
  </div>
}

export default function App() {
  const [messages, setMessages] = useState([])
  const [input, setInput] = useState('')
  const [threadId, setThreadId] = useState(() => localStorage.getItem(STORAGE_KEY) || '')
  const [turnId, setTurnId] = useState('')
  const [working, setWorking] = useState(false)
  const [status, setStatus] = useState('connecting')
  const [activity, setActivity] = useState('')
  const [sidebar, setSidebar] = useState(true)
  const [threads, setThreads] = useState([])
  const [loadingThread, setLoadingThread] = useState('')
  const endRef = useRef(null)
  const textareaRef = useRef(null)
  const socketRef = useRef(null)
  const threadIdRef = useRef(threadId)
  const workingRef = useRef(working)

  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }) }, [messages, activity])
  useEffect(() => { threadIdRef.current = threadId }, [threadId])
  useEffect(() => { workingRef.current = working }, [working])
  useEffect(() => {
    const check = async () => {
      try {
        const res = await fetch('/api/health')
        const data = await res.json()
        setStatus(data.codex === 'ready' ? 'ready' : 'offline')
      } catch { setStatus('offline') }
    }
    check()
    const timer = setInterval(check, 10000)
    return () => clearInterval(timer)
  }, [])

  useEffect(() => {
    refreshThreads()
    if (threadId) openThread(threadId)
  }, [])

  useEffect(() => {
    let disposed = false
    let retryTimer
    const connect = () => {
      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
      const socket = new WebSocket(`${protocol}//${window.location.host}/api/ws`)
      socketRef.current = socket
      socket.onopen = () => {
        if (threadIdRef.current) socket.send(JSON.stringify({ type: 'subscribe', threadId: threadIdRef.current }))
      }
      socket.onmessage = event => handleRealtimeEvent(JSON.parse(event.data))
      socket.onclose = () => {
        if (!disposed) retryTimer = setTimeout(connect, 1000)
      }
      socket.onerror = () => socket.close()
    }
    connect()
    return () => {
      disposed = true
      clearTimeout(retryTimer)
      socketRef.current?.close()
    }
  }, [])

  useEffect(() => {
    if (threadId && socketRef.current?.readyState === WebSocket.OPEN) {
      socketRef.current.send(JSON.stringify({ type: 'subscribe', threadId }))
    }
  }, [threadId])

  const refreshThreads = async () => {
    try {
      const response = await fetch('/api/threads')
      if (!response.ok) return
      const data = await response.json()
      setThreads(data.threads || [])
    } catch { /* health indicator already communicates connection errors */ }
  }

  const handleRealtimeEvent = event => {
    if (event.type !== 'notification') return
    const { method, params = {} } = event
    if (['thread/started', 'thread/name/updated', 'thread/archived', 'thread/unarchived', 'thread/deleted'].includes(method)) refreshThreads()
    if (!params.threadId || params.threadId !== threadIdRef.current || workingRef.current) return

    if (method === 'item/started' && params.item?.type === 'userMessage') {
      const text = (params.item.content || []).filter(part => part.type === 'text').map(part => part.text).join('\n').trim()
      if (text) setMessages(current => current.at(-1)?.role === 'user' && current.at(-1)?.text === text ? current : [...current, { role: 'user', text }])
    } else if (method === 'item/agentMessage/delta') {
      setActivity('')
      setMessages(current => {
        const last = current.at(-1)
        if (last?.role === 'assistant' && last.liveItemId === params.itemId) {
          return current.map((message, index) => index === current.length - 1 ? { ...message, text: message.text + params.delta } : message)
        }
        return [...current, { role: 'assistant', text: params.delta, liveItemId: params.itemId }]
      })
    } else if (method === 'item/started') {
      const labels = {
        commandExecution: `Running ${params.item.command || 'a command'}`,
        fileChange: 'Updating workspace files',
        webSearch: `Searching for ${params.item.query || 'information'}`,
        reasoning: 'Working through the request',
      }
      if (labels[params.item?.type]) setActivity(labels[params.item.type])
    } else if (method === 'item/completed' && params.item?.type === 'agentMessage') {
      setMessages(current => current.map(message => message.liveItemId === params.item.id ? { role: 'assistant', text: params.item.text } : message))
    } else if (method === 'turn/completed') {
      setActivity('')
      openThread(threadIdRef.current, { silent: true })
      refreshThreads()
    }
  }

  const openThread = async (id, { silent = false } = {}) => {
    if (!id || workingRef.current) return
    if (!silent) setLoadingThread(id)
    try {
      const response = await fetch(`/api/threads/${encodeURIComponent(id)}`)
      if (!response.ok) throw new Error(await response.text())
      const data = await response.json()
      const incoming = data.messages || []
      setMessages(current => messagesMatch(current, incoming) ? current : incoming)
      setThreadId(data.threadId || id)
      setTurnId('')
      setActivity('')
      localStorage.setItem(STORAGE_KEY, data.threadId || id)
    } catch (error) {
      if (!silent) setMessages([{ role: 'assistant', text: `I couldn't load that session: ${error.message}`, error: true }])
    } finally {
      if (!silent) setLoadingThread('')
    }
  }

  const newChat = () => {
    if (working) return
    setMessages([])
    setThreadId('')
    setTurnId('')
    setActivity('')
    localStorage.removeItem(STORAGE_KEY)
    textareaRef.current?.focus()
  }

  const send = async (preset) => {
    const text = (typeof preset === 'string' ? preset : input).trim()
    if (!text || working) return
    setInput('')
    setWorking(true)
    setActivity('Thinking')
    setMessages(current => [...current, { role: 'user', text }, { role: 'assistant', text: '' }])

    try {
      const response = await fetch('/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: text, threadId }),
      })
      if (!response.ok || !response.body) throw new Error((await response.text()) || `HTTP ${response.status}`)

      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''
      let eventName = 'message'
      let dataLines = []
      const dispatch = () => {
        if (!dataLines.length) return
        const payload = JSON.parse(dataLines.join('\n'))
        if (eventName === 'ready') {
          setThreadId(payload.threadId)
          setTurnId(payload.turnId)
          localStorage.setItem(STORAGE_KEY, payload.threadId)
        } else if (eventName === 'delta') {
          setActivity('')
          setMessages(current => current.map((m, i) => i === current.length - 1 ? { ...m, text: m.text + payload.text } : m))
        } else if (eventName === 'activity') {
          setActivity(payload.label)
        } else if (eventName === 'error') {
          throw new Error(payload.message)
        }
      }
      while (true) {
        const { value, done } = await reader.read()
        buffer += decoder.decode(value || new Uint8Array(), { stream: !done })
        const lines = buffer.split('\n')
        buffer = lines.pop() || ''
        for (const raw of lines) {
          const line = raw.replace(/\r$/, '')
          if (!line) { dispatch(); eventName = 'message'; dataLines = []; continue }
          if (line.startsWith('event:')) eventName = line.slice(6).trim()
          if (line.startsWith('data:')) dataLines.push(line.slice(5).trimStart())
        }
        if (done) break
      }
    } catch (error) {
      setMessages(current => current.map((m, i) => i === current.length - 1 ? { ...m, text: m.text || `I couldn't complete that turn: ${error.message}`, error: true } : m))
    } finally {
      setWorking(false)
      setActivity('')
      setTurnId('')
      refreshThreads()
      textareaRef.current?.focus()
    }
  }

  const stop = async () => {
    if (!threadId || !turnId) return
    await fetch('/api/interrupt', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ threadId, turnId }) })
  }

  const keyDown = (event) => {
    if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); send() }
  }

  return <div className={`app ${sidebar ? '' : 'sidebar-closed'}`}>
    <aside>
      <div className="brand"><div className="brand-mark"><Icon name="terminal" size={18} /></div><span>Codex <em>local</em></span></div>
      <button className="new-chat" onClick={newChat}><Icon name="plus" />New conversation</button>
      <div className="nav-label">WORKSPACE</div>
      <button className="workspace" onClick={() => openThread(threadId || threads[0]?.id)} disabled={working || (!threadId && !threads.length)}><Icon name="code" /><div><strong>codex-thing</strong><span>/path/to/codex-thing</span></div></button>
      <div className="nav-label recent-label">RECENT SESSIONS</div>
      <div className="thread-list">
        {threads.map(thread => <button key={thread.id} className={thread.id === threadId ? 'active' : ''} onClick={() => openThread(thread.id)} disabled={working} title={thread.preview || thread.title}>
          <span>{loadingThread === thread.id ? 'Loading…' : thread.title}</span>
          <small>{new Date(thread.updatedAt * 1000).toLocaleDateString([], { month: 'short', day: 'numeric' })}</small>
        </button>)}
        {!threads.length && <p>No saved sessions yet</p>}
      </div>
      <div className="aside-spacer" />
      <div className="connection"><span className={`status-dot ${status}`} /><div><strong>{status === 'ready' ? 'Codex connected' : status === 'offline' ? 'Codex offline' : 'Connecting…'}</strong><small>App server · workspace write</small></div></div>
    </aside>

    <main>
      <header>
        <button className="icon-button" onClick={() => setSidebar(v => !v)} aria-label="Toggle sidebar"><Icon name="panel" /></button>
        <div><strong>{messages.length ? 'Workspace conversation' : 'New conversation'}</strong><span>{threadId ? `Thread ${threadId.slice(0, 8)}` : 'Codex local'}</span></div>
        <div className="header-badge"><span className={`status-dot ${status}`} />{status === 'ready' ? 'Connected' : 'Offline'}</div>
      </header>

      <section className="conversation">
        {!messages.length ? <EmptyState onPrompt={send} /> : <div className="message-list">
          {messages.map((message, index) => <article className={`message ${message.role} ${message.error ? 'error' : ''}`} key={index}>
            <div className="avatar">{message.role === 'user' ? 'Y' : <Icon name="spark" size={16} />}</div>
            <div className="message-body"><div className="message-meta">{message.role === 'user' ? 'You' : 'Codex'}</div>{message.text ? <RichText text={message.text} /> : (index === messages.length - 1 && <div className="thinking"><i /><i /><i /></div>)}</div>
          </article>)}
          {activity && <div className="activity"><span className="spinner" />{activity}</div>}
          <div ref={endRef} />
        </div>}
      </section>

      <footer>
        <div className={`composer ${working ? 'working' : ''}`}>
          <textarea ref={textareaRef} value={input} onChange={e => setInput(e.target.value)} onKeyDown={keyDown} placeholder="Ask Codex to build, explain, or debug…" rows={1} disabled={working} />
          <div className="composer-row"><span>↵ send &nbsp;·&nbsp; ⇧↵ new line</span>{working ? <button className="send stop" onClick={stop} aria-label="Stop"><Icon name="stop" size={16} /></button> : <button className="send" onClick={() => send()} disabled={!input.trim() || status !== 'ready'} aria-label="Send"><Icon name="send" size={17} /></button>}</div>
        </div>
        <p className="disclaimer">Codex can make mistakes. Review commands and file changes.</p>
      </footer>
    </main>
  </div>
}
