import { useEffect, useRef, useState } from 'react'

const STORAGE_KEY = 'codex-local-thread'

function workspaceName(path) {
  const parts = (path || '').split('/').filter(Boolean)
  return parts.at(-1) || 'Workspace'
}

function workspaceParent(path) {
  const normalized = (path || '').replace(/\/+$/, '')
  const separator = normalized.lastIndexOf('/')
  if (separator <= 0) return '/'
  return `${normalized.slice(0, separator)}/`
}

function messagesMatch(left, right) {
  if (left.length !== right.length) return false
  const fields = ['kind', 'id', 'role', 'text', 'command', 'cwd', 'output', 'status', 'exitCode', 'durationMs']
  return left.every((message, index) => fields.every(field => message[field] === right[index]?.[field]))
}

function appendAssistantDelta(items, text, itemId) {
  let index = itemId ? items.findIndex(item => item.liveItemId === itemId) : -1
  if (index < 0 && items.at(-1)?.role === 'assistant' && !items.at(-1)?.text) index = items.length - 1
  if (index < 0) return [...items, { role: 'assistant', text, liveItemId: itemId }]
  return items.map((item, itemIndex) => itemIndex === index ? { ...item, text: (item.text || '') + text, liveItemId: itemId || item.liveItemId } : item)
}

function upsertCommand(items, command, outputDelta = '') {
  const withoutPlaceholder = items.at(-1)?.role === 'assistant' && !items.at(-1)?.text ? items.slice(0, -1) : items
  const index = withoutPlaceholder.findIndex(item => item.kind === 'command' && item.id === command.id)
  if (index < 0) return [...withoutPlaceholder, { kind: 'command', ...command, output: (command.output || '') + outputDelta }]
  return withoutPlaceholder.map((item, itemIndex) => itemIndex === index ? {
    ...item,
    ...command,
    output: command.output ?? ((item.output || '') + outputDelta),
  } : item)
}

function appendInterruptedNotice(items, turn) {
  if (items.some(item => item.kind === 'notice' && item.id === turn.id)) return items
  return [...items, {
    kind: 'notice',
    id: turn.id,
    status: 'interrupted',
    text: 'Conversation interrupted — tell the model what to do differently. Something went wrong? Use /feedback to report the issue.',
  }]
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
    alert: <><path d="M12 9v4M12 17h.01" /><path d="M10.3 3.9 2.5 17.4A2 2 0 0 0 4.2 20h15.6a2 2 0 0 0 1.7-2.6L13.7 3.9a2 2 0 0 0-3.4 0Z" /></>,
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

function CommandCard({ item }) {
  const [expanded, setExpanded] = useState(false)
  const output = item.output || ''
  const lines = output.split('\n')
  const needsExpansion = lines.length > 14 || output.length > 2600
  let visibleOutput = output
  if (!expanded && needsExpansion) {
    visibleOutput = lines.slice(0, 14).join('\n')
    if (visibleOutput.length > 2600) visibleOutput = `${visibleOutput.slice(0, 2600)}…`
  }
  const failed = item.status === 'failed' || (item.exitCode != null && item.exitCode !== 0)
  const running = item.status === 'inProgress'
  const label = running ? 'Running' : failed ? 'Command failed' : item.status === 'declined' ? 'Command declined' : 'Ran'
  const details = [item.exitCode != null ? `exit ${item.exitCode}` : '', item.durationMs != null ? `${(item.durationMs / 1000).toFixed(2)}s` : ''].filter(Boolean)

  return <article className={`command-card ${failed ? 'failed' : ''} ${running ? 'running' : ''}`}>
    <div className="command-title"><Icon name="terminal" size={15} /><strong>{label}</strong>{details.length > 0 && <span>{details.join(' · ')}</span>}</div>
    <pre className="command-line"><code>{item.command || 'Command'}</code></pre>
    {item.cwd && <div className="command-cwd">{item.cwd}</div>}
    {output && <div className="command-output"><pre><code>{visibleOutput}</code></pre>{needsExpansion && <button onClick={() => setExpanded(value => !value)}>{expanded ? 'Collapse output' : `Show full output · ${lines.length} lines`}</button>}</div>}
  </article>
}

function TranscriptItem({ item, index, isLast }) {
  if (item.kind === 'command') return <CommandCard item={item} />
  if (item.kind === 'notice') return <div className="system-notice"><Icon name="alert" size={16} /><div><strong>Conversation interrupted</strong><span>{item.text.replace(/^Conversation interrupted\s*[—-]\s*/i, '')}</span></div></div>
  return <article className={`message ${item.role} ${item.error ? 'error' : ''}`}>
    <div className="avatar">{item.role === 'user' ? 'Y' : <Icon name="spark" size={16} />}</div>
    <div className="message-body"><div className="message-meta">{item.role === 'user' ? 'You' : 'Codex'}</div>{item.text ? <RichText text={item.text} /> : (isLast && <div className="thinking"><i /><i /><i /></div>)}</div>
  </article>
}

function ApprovalCard({ approval, deciding, onDecision }) {
	const [answers, setAnswers] = useState({})
	const setAnswer = (questionId, value) => setAnswers(current => ({ ...current, [questionId]: value }))
	const kind = approval.kind || 'command'
	if (kind === 'userInput') {
		const questions = approval.questions || []
		const complete = questions.every(question => (answers[question.id] || '').trim())
		const submit = () => onDecision(approval.id, 'submit', {
			answers: Object.fromEntries(questions.map(question => [question.id, [(answers[question.id] || '').trim()]])),
		})
		return <section className="approval-card" role="alert" aria-label="Codex needs your input">
			<div className="approval-head"><Icon name="alert" size={17} /><div><strong>Codex needs your input</strong><span>Answer to continue this turn</span></div></div>
			<div className="approval-questions">{questions.map(question => {
				const selected = answers[question.id] || ''
				return <fieldset key={question.id}>
					{question.header && <legend>{question.header}</legend>}
					<p>{question.question}</p>
					{question.options?.length > 0 && <div className="approval-options">{question.options.map(option => <button type="button" className={selected === option.label ? 'selected' : ''} key={option.label} disabled={deciding} onClick={() => setAnswer(question.id, option.label)}><strong>{option.label}</strong>{option.description && <span>{option.description}</span>}</button>)}</div>}
					<input type={question.isSecret ? 'password' : 'text'} value={selected} disabled={deciding} placeholder={question.options?.length ? 'Or type another answer' : 'Type your answer'} onChange={event => setAnswer(question.id, event.target.value)} />
				</fieldset>
			})}</div>
			<div className="approval-actions"><button className="approve" disabled={deciding || !complete} onClick={submit}>{deciding ? 'Waiting for Codex…' : 'Submit answers'}</button></div>
		</section>
	}

  const rememberLabel = approval.proposedExecPrefix?.length
    ? `Always allow ${approval.proposedExecPrefix.join(' ')}`
    : 'Allow for this session'
	const headings = {
		command: ['Command approval required', `Environment: ${approval.environment || 'local'}`],
		fileChange: ['File-change approval required', 'Review the requested workspace edit'],
		permissions: ['Additional permissions requested', `Environment: ${approval.environment || 'local'}`],
		mcpElicitation: [`${approval.serverName || 'An MCP server'} needs your approval`, 'External tool request'],
	}
	const [title, subtitle] = headings[kind] || headings.command
	return <section className="approval-card" role="alert" aria-label={title}>
		<div className="approval-head"><Icon name="alert" size={17} /><div><strong>{title}</strong><span>{subtitle}</span></div></div>
    {approval.reason && <p className="approval-reason">{approval.reason}</p>}
		{kind === 'command' && <pre><code>{approval.command || 'Unknown command'}</code></pre>}
		{kind === 'fileChange' && <pre><code>{approval.grantRoot ? `Allow changes under ${approval.grantRoot}` : `Apply the pending file changes${approval.itemId ? ` (${approval.itemId})` : ''}`}</code></pre>}
		{kind === 'permissions' && <pre><code>{JSON.stringify(approval.permissions || {}, null, 2)}</code></pre>}
		{kind === 'mcpElicitation' && <p className="approval-reason">{approval.message || 'The MCP server requested additional information.'}</p>}
    {approval.cwd && <div className="approval-cwd">Working directory: {approval.cwd}</div>}
    <div className="approval-actions">
			<button className="approve" disabled={deciding} onClick={() => onDecision(approval.id, 'accept')}>{deciding ? 'Waiting for Codex…' : kind === 'fileChange' ? 'Apply changes' : kind === 'permissions' ? 'Grant for this turn' : kind === 'mcpElicitation' ? 'Allow' : 'Allow once'}</button>
			{kind !== 'mcpElicitation' && <button disabled={deciding} onClick={() => onDecision(approval.id, 'always')}>{kind === 'fileChange' ? "Apply and don't ask again" : kind === 'permissions' ? 'Grant for this session' : rememberLabel}</button>}
			{kind === 'mcpElicitation' && <button disabled={deciding} onClick={() => onDecision(approval.id, 'decline')}>Continue without it</button>}
			<button className="deny" disabled={deciding} onClick={() => onDecision(approval.id, kind === 'permissions' ? 'decline' : 'cancel')}>{kind === 'permissions' ? 'Continue without permissions' : 'Deny and stop'}</button>
    </div>
  </section>
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
  const [approvals, setApprovals] = useState([])
  const [approvalError, setApprovalError] = useState('')
  const [decidingApproval, setDecidingApproval] = useState('')
  const [defaultWorkspace, setDefaultWorkspace] = useState('')
  const [workspace, setWorkspace] = useState('')
  const [differentWorkspace, setDifferentWorkspace] = useState(false)
  const [workspaceInput, setWorkspaceInput] = useState('')
  const [workspaceError, setWorkspaceError] = useState('')
  const [workspaceSuggestions, setWorkspaceSuggestions] = useState([])
  const [workspaceFocused, setWorkspaceFocused] = useState(false)
  const [workspaceSuggestionIndex, setWorkspaceSuggestionIndex] = useState(-1)
  const [workspaceSuggestionsLoading, setWorkspaceSuggestionsLoading] = useState(false)
  const endRef = useRef(null)
  const textareaRef = useRef(null)
  const socketRef = useRef(null)
  const threadIdRef = useRef(threadId)
  const workingRef = useRef(working)
  const streamingRef = useRef(false)
  const workspaceRef = useRef(workspace)
  const defaultWorkspaceRef = useRef(defaultWorkspace)

  const applyRuntimeSnapshot = runtime => {
    if (!runtime || runtime.threadId !== threadIdRef.current) return
    const isWorking = Boolean(runtime.working)
    workingRef.current = isWorking
    setWorking(isWorking)
    setTurnId(runtime.turnId || '')
    setApprovals(runtime.approvals || [])
    setDecidingApproval(current => (runtime.approvals || []).some(item => item.id === current) ? current : '')
    if (!isWorking) setActivity('')
    else if ((runtime.activeFlags || []).includes('waitingOnApproval') || runtime.approvals?.length) setActivity('Waiting for approval')
    else setActivity(current => current || 'Working')
  }

  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }) }, [messages, activity])
  useEffect(() => { threadIdRef.current = threadId }, [threadId])
  useEffect(() => { workingRef.current = working }, [working])
  useEffect(() => { workspaceRef.current = workspace }, [workspace])
  useEffect(() => {
    if (!differentWorkspace || !workspaceInput.trim()) {
      setWorkspaceSuggestions([])
      setWorkspaceSuggestionsLoading(false)
      return
    }
    const controller = new AbortController()
    const timer = setTimeout(async () => {
      setWorkspaceSuggestionsLoading(true)
      try {
        const response = await fetch(`/api/workspaces/complete?path=${encodeURIComponent(workspaceInput.trim())}`, { signal: controller.signal })
        if (!response.ok) throw new Error(await response.text())
        const data = await response.json()
        setWorkspaceSuggestions(data.suggestions || [])
        setWorkspaceSuggestionIndex(-1)
      } catch (error) {
        if (error.name !== 'AbortError') setWorkspaceSuggestions([])
      } finally {
        if (!controller.signal.aborted) setWorkspaceSuggestionsLoading(false)
      }
    }, 160)
    return () => {
      clearTimeout(timer)
      controller.abort()
    }
  }, [differentWorkspace, workspaceInput])
  useEffect(() => {
    const check = async () => {
      try {
        const res = await fetch('/api/health')
        const data = await res.json()
        setStatus(data.codex === 'ready' ? 'ready' : 'offline')
        if (data.workspace) {
          defaultWorkspaceRef.current = data.workspace
          setDefaultWorkspace(data.workspace)
          if (!workspaceRef.current) {
            workspaceRef.current = data.workspace
            setWorkspace(data.workspace)
          }
        }
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

  const refreshThreads = async (cwd = workspaceRef.current) => {
    try {
      const query = cwd ? `?cwd=${encodeURIComponent(cwd)}` : ''
      const response = await fetch(`/api/threads${query}`)
      if (!response.ok) return
      const data = await response.json()
      setThreads(data.threads || [])
      if (data.workspace && !workspaceRef.current) {
        workspaceRef.current = data.workspace
        setWorkspace(data.workspace)
      }
    } catch { /* health indicator already communicates connection errors */ }
  }

  const handleRealtimeEvent = (event, { allowWhileWorking = false } = {}) => {
    if (event.type === 'runtime/snapshot') {
      applyRuntimeSnapshot(event)
      return
    }
    if (event.type === 'approval/resolved') {
      if (event.threadId === threadIdRef.current) {
        setApprovals(current => current.filter(item => item.id !== event.approvalId))
        setDecidingApproval('')
        setApprovalError('')
      }
      return
    }
    if (event.type === 'approval/submitted') {
      if (event.threadId === threadIdRef.current) setDecidingApproval(event.approvalId)
      return
    }
    if (event.type === 'approval/error') {
      setDecidingApproval('')
      setApprovalError(event.message || 'The approval could not be submitted.')
      return
    }
    if (event.type !== 'notification') return
    const { method, params = {} } = event
    if (['thread/started', 'thread/name/updated', 'thread/archived', 'thread/unarchived', 'thread/deleted'].includes(method)) refreshThreads()
    if (!params.threadId || params.threadId !== threadIdRef.current || (streamingRef.current && !allowWhileWorking)) return

    if (method === 'turn/started') {
      workingRef.current = true
      setWorking(true)
      setTurnId(params.turn?.id || '')
      setActivity('Working')
    } else if (method === 'item/started' && params.item?.type === 'userMessage') {
      const text = (params.item.content || []).filter(part => part.type === 'text').map(part => part.text).join('\n').trim()
      if (text) setMessages(current => current.at(-1)?.role === 'user' && current.at(-1)?.text === text ? current : [...current, { role: 'user', text }])
    } else if (method === 'item/agentMessage/delta') {
      setActivity('')
      setMessages(current => appendAssistantDelta(current, params.delta, params.itemId))
    } else if (method === 'item/commandExecution/outputDelta') {
      setMessages(current => upsertCommand(current, { id: params.itemId, status: 'inProgress' }, params.delta))
    } else if ((method === 'item/started' || method === 'item/completed') && params.item?.type === 'commandExecution') {
      setActivity(method === 'item/started' ? `Running ${params.item.command || 'a command'}` : '')
      setMessages(current => upsertCommand(current, {
        id: params.item.id,
        command: params.item.command,
        cwd: params.item.cwd,
        output: params.item.aggregatedOutput,
        status: params.item.status,
        exitCode: params.item.exitCode,
        durationMs: params.item.durationMs,
      }))
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
      workingRef.current = false
      setWorking(false)
      setTurnId('')
      setApprovals([])
      setActivity('')
      if (params.turn?.status === 'interrupted') setMessages(current => appendInterruptedNotice(current, params.turn))
      if (!allowWhileWorking) openThread(threadIdRef.current, { silent: true })
      refreshThreads()
    }
  }

  const openThread = async (id, { silent = false, force = false } = {}) => {
    if (!id || (workingRef.current && !force)) return
    if (!silent) setLoadingThread(id)
    try {
      const response = await fetch(`/api/threads/${encodeURIComponent(id)}`)
      if (!response.ok) throw new Error(await response.text())
      const data = await response.json()
      const incoming = data.messages || []
      setMessages(current => messagesMatch(current, incoming) ? current : incoming)
      setThreadId(data.threadId || id)
      threadIdRef.current = data.threadId || id
      if (data.workspace) {
        workspaceRef.current = data.workspace
        setWorkspace(data.workspace)
        setWorkspaceInput(data.workspace)
        setDifferentWorkspace(Boolean(defaultWorkspaceRef.current && data.workspace !== defaultWorkspaceRef.current))
        refreshThreads(data.workspace)
      }
      applyRuntimeSnapshot(data.runtime || { threadId: data.threadId || id, working: false, approvals: [] })
      localStorage.setItem(STORAGE_KEY, data.threadId || id)
    } catch (error) {
      if (!silent) setMessages([{ role: 'assistant', text: `I couldn't load that session: ${error.message}`, error: true }])
    } finally {
      if (!silent) setLoadingThread('')
    }
  }

  const newChat = () => {
    if (working) return
    const targetWorkspace = differentWorkspace ? workspaceInput.trim() : (defaultWorkspaceRef.current || defaultWorkspace)
    if (differentWorkspace && !targetWorkspace) {
      setWorkspaceError('Enter an absolute workspace path.')
      return
    }
    setWorkspaceError('')
    if (targetWorkspace) {
      workspaceRef.current = targetWorkspace
      setWorkspace(targetWorkspace)
      refreshThreads(targetWorkspace)
    }
    setMessages([])
    setThreadId('')
    setTurnId('')
    setActivity('')
    setApprovals([])
    setApprovalError('')
    localStorage.removeItem(STORAGE_KEY)
    textareaRef.current?.focus()
  }

  const send = async (preset) => {
    const text = (typeof preset === 'string' ? preset : input).trim()
    if (!text || working) return
    const targetWorkspace = threadId ? '' : (differentWorkspace ? workspaceInput.trim() : (workspace || defaultWorkspaceRef.current || defaultWorkspace))
    if (!threadId && (!targetWorkspace || !targetWorkspace.startsWith('/'))) {
      setWorkspaceError('Enter an absolute workspace path before starting the conversation.')
      return
    }
    setWorkspaceError('')
    setInput('')
    streamingRef.current = true
    setWorking(true)
    setActivity('Thinking')
    setMessages(current => [...current, { role: 'user', text }, { role: 'assistant', text: '' }])

    try {
      const response = await fetch('/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: text, threadId, workspace: targetWorkspace }),
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
          threadIdRef.current = payload.threadId
          setTurnId(payload.turnId)
          if (payload.workspace) {
            workspaceRef.current = payload.workspace
            setWorkspace(payload.workspace)
          }
          localStorage.setItem(STORAGE_KEY, payload.threadId)
        } else if (eventName === 'delta') {
          setActivity('')
          setMessages(current => appendAssistantDelta(current, payload.text, payload.itemId))
        } else if (eventName === 'activity') {
          setActivity(payload.label)
        } else if (eventName === 'protocol') {
          const richMethod = payload.method === 'item/commandExecution/outputDelta' ||
            ((payload.method === 'item/started' || payload.method === 'item/completed') && payload.params?.item?.type === 'commandExecution') ||
            (payload.method === 'turn/completed' && payload.params?.turn?.status === 'interrupted')
          if (richMethod) handleRealtimeEvent(payload, { allowWhileWorking: true })
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
      setMessages(current => {
        const text = `I couldn't complete that turn: ${error.message}`
        if (current.at(-1)?.role === 'assistant' && !current.at(-1)?.text) return current.map((item, index) => index === current.length - 1 ? { ...item, text, error: true } : item)
        return [...current, { role: 'assistant', text, error: true }]
      })
    } finally {
      streamingRef.current = false
      workingRef.current = false
      setWorking(false)
      setActivity('')
      setTurnId('')
      if (threadIdRef.current) await openThread(threadIdRef.current, { silent: true, force: true })
      refreshThreads()
      textareaRef.current?.focus()
    }
  }

  const stop = async () => {
    if (!threadId) return
    await fetch('/api/interrupt', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ threadId, turnId }) })
  }

  const decideApproval = (approvalId, decision, payload = {}) => {
    if (!approvalId || socketRef.current?.readyState !== WebSocket.OPEN) {
      setApprovalError('The realtime connection is not ready. Reconnect and try again.')
      return
    }
    setApprovalError('')
    setDecidingApproval(approvalId)
    socketRef.current.send(JSON.stringify({ type: 'approval/decide', approvalId, decision, ...payload }))
  }

  const selectWorkspaceSuggestion = suggestion => {
    setWorkspaceInput(suggestion.path)
    setWorkspaceError('')
    setWorkspaceFocused(false)
    setWorkspaceSuggestionIndex(-1)
  }

  const workspacePathKeyDown = event => {
    if (!workspaceSuggestions.length) return
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      setWorkspaceFocused(true)
      setWorkspaceSuggestionIndex(index => Math.min(index + 1, workspaceSuggestions.length - 1))
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      setWorkspaceFocused(true)
      setWorkspaceSuggestionIndex(index => Math.max(index - 1, 0))
    } else if (event.key === 'Enter' && workspaceSuggestionIndex >= 0) {
      event.preventDefault()
      selectWorkspaceSuggestion(workspaceSuggestions[workspaceSuggestionIndex])
    } else if (event.key === 'Escape') {
      setWorkspaceFocused(false)
      setWorkspaceSuggestionIndex(-1)
    }
  }

  const keyDown = (event) => {
    if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); send() }
  }

  return <div className={`app ${sidebar ? '' : 'sidebar-closed'}`}>
    <aside>
      <div className="brand"><div className="brand-mark"><Icon name="terminal" size={18} /></div><span>Codex <em>local</em></span></div>
      <button className="new-chat" onClick={newChat}><Icon name="plus" />New conversation</button>
      <div className="workspace-choice">
        <label><input type="checkbox" checked={differentWorkspace} onChange={event => {
          const checked = event.target.checked
          setDifferentWorkspace(checked)
          setWorkspaceError('')
          if (checked && !workspaceInput) setWorkspaceInput(workspaceParent(workspaceRef.current || defaultWorkspaceRef.current))
        }} disabled={working} />Choose a different path</label>
        {differentWorkspace && <div className="workspace-complete">
          <input className="workspace-path" value={workspaceInput} onChange={event => { setWorkspaceInput(event.target.value); setWorkspaceError(''); setWorkspaceFocused(true) }} onFocus={() => setWorkspaceFocused(true)} onBlur={() => setWorkspaceFocused(false)} onKeyDown={workspacePathKeyDown} placeholder="/absolute/path/to/workspace" aria-label="Workspace path" role="combobox" aria-autocomplete="list" aria-expanded={workspaceFocused && (workspaceSuggestionsLoading || workspaceSuggestions.length > 0)} aria-controls="workspace-suggestions" aria-activedescendant={workspaceSuggestionIndex >= 0 ? `workspace-suggestion-${workspaceSuggestionIndex}` : undefined} disabled={working} />
          {workspaceFocused && (workspaceSuggestionsLoading || workspaceSuggestions.length > 0) && <div className="workspace-suggestions" id="workspace-suggestions" role="listbox">
            {workspaceSuggestionsLoading && <span>Loading directories…</span>}
            {!workspaceSuggestionsLoading && workspaceSuggestions.map((suggestion, index) => <button id={`workspace-suggestion-${index}`} role="option" aria-selected={index === workspaceSuggestionIndex} className={index === workspaceSuggestionIndex ? 'active' : ''} key={suggestion.path} onMouseDown={event => { event.preventDefault(); selectWorkspaceSuggestion(suggestion) }}><strong>{suggestion.name}</strong><small>{suggestion.path}</small></button>)}
          </div>}
        </div>}
        {workspaceError && <span className="workspace-error">{workspaceError}</span>}
      </div>
      <div className="nav-label">WORKSPACE</div>
      <button className="workspace" onClick={() => openThread(threadId || threads[0]?.id)} disabled={working || (!threadId && !threads.length)}><Icon name="code" /><div><strong>{workspaceName(workspace || defaultWorkspace)}</strong><span>{workspace || defaultWorkspace || 'Loading workspace…'}</span></div></button>
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
          {messages.map((message, index) => <TranscriptItem item={message} index={index} isLast={index === messages.length - 1} key={message.id ? `${message.kind || message.role}-${message.id}` : index} />)}
          {activity && <div className="activity"><span className="spinner" />{activity}</div>}
          <div ref={endRef} />
        </div>}
      </section>

      <footer>
        {approvals.length > 0 && <div className="approval-stack">
          {approvals.map(approval => <ApprovalCard key={approval.id} approval={approval} deciding={approval.submitted || decidingApproval === approval.id} onDecision={decideApproval} />)}
          {approvalError && <p className="approval-error">{approvalError}</p>}
        </div>}
        <div className={`composer ${working ? 'working' : ''}`}>
          <textarea ref={textareaRef} value={input} onChange={e => setInput(e.target.value)} onKeyDown={keyDown} placeholder="Ask Codex to build, explain, or debug…" rows={1} disabled={working} />
          <div className="composer-row"><span>↵ send &nbsp;·&nbsp; ⇧↵ new line</span>{working ? <button className="send stop" onClick={stop} aria-label="Stop"><Icon name="stop" size={16} /></button> : <button className="send" onClick={() => send()} disabled={!input.trim() || status !== 'ready'} aria-label="Send"><Icon name="send" size={17} /></button>}</div>
        </div>
        <p className="disclaimer">Codex can make mistakes. Review commands and file changes.</p>
      </footer>
    </main>
  </div>
}
