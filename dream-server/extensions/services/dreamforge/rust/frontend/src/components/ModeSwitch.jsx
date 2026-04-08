import React from 'react';

const MODES = [
  { value: 'default', label: 'Default', desc: 'Prompts for writes/exec' },
  { value: 'plan', label: 'Plan', desc: 'Read-only, no execution' },
  { value: 'accept_edits', label: 'Accept Edits', desc: 'Auto-approve file writes' },
  { value: 'full_auto', label: 'Full Auto', desc: 'Auto-approve everything' },
];

export default function ModeSwitch({ currentMode, onChange }) {
  return (
    <div className="flex flex-col gap-1">
      <span className="text-xs text-gray-500 mb-1">Permission Mode</span>
      <div className="flex gap-1">
        {MODES.map((mode) => (
          <button
            key={mode.value}
            onClick={() => onChange(mode.value)}
            title={mode.desc}
            className={`px-2 py-1 rounded text-xs transition-colors ${
              currentMode === mode.value
                ? 'liquid-metal-button text-white'
                : 'bg-gray-800 text-gray-400 hover:bg-gray-700'
            }`}
          >
            {mode.label}
          </button>
        ))}
      </div>
    </div>
  );
}
