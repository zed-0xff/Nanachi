{
 "$schema": "https://opencode.ai/config.json",

 "update": "disable",

 "disabled_providers": [
    "openai",
    "anthropic",
    "google",
    "google-vertex",
    "gemini",
    "github-copilot",
    "opencode"
  ],

  "attention": {
    "notifications": true,
    "sound": true
  },

  "providers": {

    "HyperQwen": {
      "package": "@opencode/ai/providers/openai-compatible",
      "name": "Qwen 3.8 27B (RTX 3090)",
      "settings": {
        "baseURL": "http://hyperwen:18020/v1",
        "apiKey": "..."
      },
      "models": {
        "qwen3.8-27b": {
          "name": "Qwen 3.8 27B",
          "limit": {
            "context": 131072,
            "output": 30000
          }
        }
      }
    }
  },

  "plugins": [
    "@mohak34/opencode-notifier@latest",
    "file:///workspace/.config/opencode/plugins/opencode-prune-images"
  ],

  "operator": {
    "contextManagement": {
      "enabled": true,
      "ratio": 0.8,
      "hardCapTokens": 131072,
      "keepRecentTurns": 4,
      "compactOnComplete": true,
      "compactFloorTokens": 20000
    }
  }
}
