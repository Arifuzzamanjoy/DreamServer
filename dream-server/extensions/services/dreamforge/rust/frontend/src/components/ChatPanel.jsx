import React, { useRef, useEffect, useState } from 'react';
import MessageBubble from './MessageBubble';
import ToolCallCard from './ToolCallCard';
import PermissionDialog from './PermissionDialog';
import ActivityIndicator from './ActivityIndicator';

export default function ChatPanel({ messages, status, pendingPermission, onSend, onPermissionResponse, bypass, onBypassChange, turnStats }) {
  const [input, setInput] = useState('');
  const bottomRef = useRef(null);
  const inputRef = useRef(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages, status]);

  const handleSubmit = (e) => {
    e.preventDefault();
    const text = input.trim();
    if (!text || status === 'running') return;
    onSend(text);
    setInput('');
    inputRef.current?.focus();
  };

  const handleKeyDown = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSubmit(e);
    }
  };

  return (
    <div className="flex flex-col flex-1 min-h-0">
      {/* Bypass mode banner */}
      {bypass && (
        <div className="px-4 py-1.5 bg-amber-900/30 border-b border-amber-800/50 text-center">
          <span className="text-xs text-amber-300">
            Bypass permissions mode: DreamForge can take actions without asking, including modifying or deleting files.
          </span>
        </div>
      )}

      {/* Messages */}
      <div className="flex-1 overflow-y-auto px-4 py-3 space-y-3">
        {messages.length === 0 && status !== 'running' && (
          <div className="flex items-center justify-center h-full text-gray-600">
            <div className="text-center">
              <p className="text-2xl mb-2">Welcome to DreamForge</p>
              <p className="text-sm">Ask me to help with your code. I run locally on your DreamServer.</p>
            </div>
          </div>
        )}
        {messages.map((msg, i) => {
          if (msg.role === 'tool') {
            return <ToolCallCard key={i} message={msg} />;
          }
          // Collapse intermediate assistant messages (followed by a tool call)
          const nextMsg = messages[i + 1];
          if (msg.role === 'assistant' && nextMsg?.role === 'tool') {
            return (
              <div key={i} className="text-xs text-gray-500 italic pl-1 py-0.5 border-l-2 border-gray-700 ml-1">
                {msg.content?.length > 120 ? msg.content.slice(0, 120) + '...' : msg.content}
              </div>
            );
          }
          return <MessageBubble key={i} message={msg} />;
        })}
        {pendingPermission && (
          <PermissionDialog
            permission={pendingPermission}
            onRespond={onPermissionResponse}
          />
        )}
        {/* Activity indicator — shows spinner, elapsed time, token counts */}
        <ActivityIndicator turnStats={turnStats} status={status} />
        <div ref={bottomRef} />
      </div>

      {/* Input */}
      <form onSubmit={handleSubmit} className="liquid-metal-frame--soft border-t bg-gray-900/50" style={{ borderColor: 'rgba(157,0,255,0.12)' }}>
        <div className="flex items-end gap-2 max-w-4xl mx-auto p-3">
          <textarea
            ref={inputRef}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder={status === 'running' ? 'Agent is working...' : 'Ask DreamForge anything...'}
            disabled={status === 'running'}
            rows={1}
            className="flex-1 resize-none rounded-xl bg-gray-800 border border-gray-700 px-4 py-3 text-sm
                       placeholder-gray-500 focus:outline-none focus:border-dream-500 focus:ring-1 focus:ring-dream-500
                       disabled:opacity-50 disabled:cursor-not-allowed"
            style={{ minHeight: '44px', maxHeight: '200px' }}
          />
          <button
            type="submit"
            disabled={!input.trim() || status === 'running'}
            className="liquid-metal-button px-4 py-3 rounded-xl text-white text-sm font-medium
                       disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            Send
          </button>
        </div>
        {/* Footer bar with bypass toggle */}
        <div className="flex items-center justify-between px-4 pb-2 pt-0 max-w-4xl mx-auto">
          <button
            type="button"
            onClick={() => onBypassChange(!bypass)}
            className={`flex items-center gap-1.5 px-2 py-1 rounded text-xs transition-colors ${
              bypass
                ? 'text-amber-300 bg-amber-900/30 hover:bg-amber-900/50'
                : 'text-gray-500 hover:text-gray-400 hover:bg-gray-800'
            }`}
          >
            <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              {bypass ? (
                <path d="M8 11V7a4 4 0 1 1 8 0m-9 4h10a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-6a2 2 0 0 1 2-2z" />
              ) : (
                <><rect x="3" y="11" width="18" height="11" rx="2" ry="2" /><path d="M7 11V7a5 5 0 0 1 10 0v4" /></>
              )}
            </svg>
            Bypass permissions
          </button>
        </div>
      </form>
    </div>
  );
}
