{
  "update": {
    "channel": "stable"
  },
  "logging": {
    "redactSensitive": "tools"
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "opencode-go/kimi-k2.5",
        "fallbacks": [
          "opencode-go/minimax-m2.7",
          "opencode-go/glm-5"
        ]
      },
      "workspace": "~/.openclaw/workspace",
      "elevatedDefault": "full",
      "memorySearch": {
        "sources": ["memory", "sessions"],
        "experimental": {
          "sessionMemory": true
        },
        "provider": "openai",
        "model": "text-embedding-3-small"
      },
      "contextPruning": {
        "mode": "cache-ttl",
        "ttl": "6h",
        "keepLastAssistants": 3
      },
      "compaction": {
        "mode": "default",
        "memoryFlush": {
          "enabled": true,
          "softThresholdTokens": 40000,
          "prompt": "Extract key decisions, state changes, lessons, blockers to memory/YYYY-MM-DD.md. Format: ## [HH:MM] Topic. Skip routine work. NO_FLUSH if nothing important.",
          "systemPrompt": "Compacting session context. Extract only what's worth remembering. No fluff."
        }
      },
      "heartbeat": {
        "model": "opencode-go/minimax-m2.5"
      },
      "maxConcurrent": 2,
      "subagents": {
        "maxConcurrent": 3,
        "model": {
          "primary": "opencode-go/minimax-m2.7",
          "fallbacks": [
            "opencode-go/minimax-m2.5"
          ]
        }
      }
    },
    "list": [
      {
        "id": "main",
        "default": true
      }
    ]
  },
  "tools": {
    "profile": "full",
    "exec": {
      "host": "gateway",
      "security": "full",
      "ask": "off"
    },
    "web": {
      "search": {
        "enabled": true
      },
      "fetch": {
        "enabled": true
      }
    }
  },
  "messages": {
    "ackReactionScope": "group-mentions"
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto",
    "restart": true
  },
  "hooks": {
    "internal": {
      "enabled": true,
      "entries": {
        "command-logger": {
          "enabled": true
        },
        "boot-md": {
          "enabled": true
        },
        "bootstrap-extra-files": {
          "enabled": true
        },
        "session-memory": {
          "enabled": true
        }
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "pairing",
      "botToken": "__TELEGRAM_BOT_TOKEN__",
      "groupPolicy": "allowlist",
      "streaming": "partial"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": "__GATEWAY_TOKEN__",
      "allowTailscale": true
    },
    "tailscale": {
      "mode": "serve",
      "resetOnExit": true
    }
  },
  "plugins": {
    "entries": {
      "telegram": {
        "enabled": true
      }
    }
  }
}
