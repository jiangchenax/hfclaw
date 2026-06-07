#!/bin/bash
# ==========================================
# OpenClaw Hugging Face Space 启动脚本
# 模型配置策略：
# 1. 只使用 /home/node/.openclaw/openclaw.json
# 2. 不读取 configs/models_config.json
# 3. 不读取 custom_models.json
# 4. 不读取 model_override.json
# 5. 首次启动自动创建 openclaw.json，并写入 Agnes 第一个模型
# 6. 后续新增模型直接编辑 openclaw.json
# ==========================================

set -euo pipefail

OC_HOME="/home/node/.openclaw"
CONFIG_FILE="$OC_HOME/openclaw.json"

export HF_ORIGIN="https://${HF_SPACE_OWNER:-tianmingyun999}-${HF_SPACE_NAME:-openclaw2}.hf.space"

echo "--- 1. 创建 OpenClaw 目录 ---"

mkdir -p "$OC_HOME"
mkdir -p "$OC_HOME/agents/assistant"
mkdir -p "$OC_HOME/agents/coder"
mkdir -p "$OC_HOME/agents/designer"
mkdir -p "$OC_HOME/workspace/assistant"
mkdir -p "$OC_HOME/workspace/coder"
mkdir -p "$OC_HOME/workspace/designer"

echo "--- 2. 恢复备份 ---"

if [ "${SKIP_RESTORE:-0}" = "1" ]; then
  echo "[SYNC] SKIP_RESTORE=1，跳过备份恢复。"
else
  if [ -n "${RESTORE_DATE:-}" ]; then
    echo "[SYNC] Restoring backup: $RESTORE_DATE"
    python3 sync.py restore "$RESTORE_DATE" || echo "[SYNC] Restore failed, continue with current files."
  else
    echo "[SYNC] Restoring latest backup..."
    python3 sync.py restore || echo "[SYNC] No backup restored, continue fresh."
  fi
fi

echo "--- 2.1 修复备份中的 openclaw.json 位置 ---"

# 标准位置：/home/node/.openclaw/openclaw.json
# 有些备份恢复后可能把 openclaw.json 放在 /home/node/openclaw.json
# 这里自动复制到标准位置，避免启动脚本重新创建首次配置

if [ ! -f "$CONFIG_FILE" ]; then
  if [ -f "/home/node/openclaw.json" ]; then
    echo "[CONFIG] 发现 /home/node/openclaw.json，复制到 $CONFIG_FILE"
    mkdir -p "$OC_HOME"
    cp "/home/node/openclaw.json" "$CONFIG_FILE"
  elif [ -f "$OC_HOME/.openclaw/openclaw.json" ]; then
    echo "[CONFIG] 发现嵌套配置 $OC_HOME/.openclaw/openclaw.json，复制到 $CONFIG_FILE"
    cp "$OC_HOME/.openclaw/openclaw.json" "$CONFIG_FILE"
  else
    echo "[CONFIG] 没有找到可恢复的 openclaw.json，后续会创建首次配置。"
  fi
else
  echo "[CONFIG] 标准位置已存在 openclaw.json。"
fi

echo "--- 3. 再次确保目录存在 ---"

mkdir -p "$OC_HOME"
mkdir -p "$OC_HOME/agents/assistant"
mkdir -p "$OC_HOME/agents/coder"
mkdir -p "$OC_HOME/agents/designer"
mkdir -p "$OC_HOME/workspace/assistant"
mkdir -p "$OC_HOME/workspace/coder"
mkdir -p "$OC_HOME/workspace/designer"

echo "--- 4. 清理旧模型覆盖文件和旧模型缓存 ---"

# 不再使用这些文件配置模型
rm -f "$OC_HOME/workspace/assistant/model_override.json" || true
rm -f "$OC_HOME/workspace/coder/model_override.json" || true
rm -f "$OC_HOME/workspace/designer/model_override.json" || true

rm -f "$OC_HOME/workspace/assistant/custom_models.json" || true
rm -f "$OC_HOME/workspace/coder/custom_models.json" || true
rm -f "$OC_HOME/workspace/designer/custom_models.json" || true

# 删除 OpenClaw 可能生成的旧 agent 模型缓存，避免继续显示旧模型
find "$OC_HOME/agents" -path "*/agent/models.json" -type f -delete 2>/dev/null || true

echo "--- 5. 创建或修复 openclaw.json ---"

python3 << 'PYTHON_EOF'
import json
import os
import time

base = "/home/node/.openclaw"
config_path = f"{base}/openclaw.json"
hf_origin = os.getenv("HF_ORIGIN", "https://*.hf.space")

agnes_api_key = os.getenv("AGNES_API_KEY", "").strip()

# 如果你不想用 Hugging Face Secret，也可以把下面这一行改成你的 key：
# agnes_api_key = "sk-xxxx"

default_model = "agnes/agnes-2.0-flash"

os.makedirs(base, exist_ok=True)

for path in [
    f"{base}/agents/assistant",
    f"{base}/agents/coder",
    f"{base}/agents/designer",
    f"{base}/workspace/assistant",
    f"{base}/workspace/coder",
    f"{base}/workspace/designer"
]:
    os.makedirs(path, exist_ok=True)


def first_config():
    return {
        "logging": {
            "level": "info"
        },
        "models": {
            "providers": {
                "agnes": {
                    "baseUrl": "https://apihub.agnes-ai.com/v1",
                    "apiKey": agnes_api_key,
                    "api": "openai-completions",
                    "models": [
                        {
                            "id": "agnes-2.0-flash",
                            "name": "Agnes 2.0 Flash",
                            "input": [
                                "text"
                            ],
                            "reasoning": False,
                            "contextWindow": 200000,
                            "maxTokens": 8192
                        }
                    ]
                }
            }
        },
        "channels": {
            "feishu": {
                "enabled": True,
                "dmPolicy": "open",
                "accounts": {
                    "default": {
                        "appId": os.getenv("FEISHU_APP_ID", ""),
                        "appSecret": os.getenv("FEISHU_APP_SECRET", ""),
                        "name": "OpenClaw Assistant"
                    }
                }
            },
            "openclaw-weixin": {
                "enabled": os.getenv("WECHAT_ENABLE", "0") == "1"
            },
            "telegram": {
                "enabled": os.getenv("TELEGRAM_ENABLE", "0") == "1",
                "botToken": os.getenv("TELEGRAM_BOT_TOKEN", ""),
                "dmPolicy": os.getenv("TELEGRAM_DM_POLICY", "open"),
                "allowFrom": [
                    x.strip()
                    for x in os.getenv("TELEGRAM_ALLOW_FROM", "*").split(",")
                    if x.strip()
                ],
                "groupPolicy": os.getenv("TELEGRAM_GROUP_POLICY", "disabled"),
                "groups": {}
            }
        },
        "plugins": {
            "entries": {
                "openclaw-weixin": {
                    "enabled": os.getenv("WECHAT_ENABLE", "0") == "1"
                }
            }
        },
        "tools": {
            "profile": "full",
            "deny": [
                "cron"
            ]
        },
        "agents": {
            "defaults": {
                "model": {
                    "primary": default_model
                },
                "params": {}
            },
            "list": [
                {
                    "id": "assistant",
                    "name": "Team Leader",
                    "default": True,
                    "workspace": f"{base}/workspace/assistant",
                    "agentDir": f"{base}/agents/assistant",
                    "model": {
                        "primary": default_model
                    },
                    "subagents": {
                        "allowAgents": [
                            "coder",
                            "designer"
                        ],
                        "model": {
                            "primary": default_model
                        }
                    }
                },
                {
                    "id": "coder",
                    "name": "Engineer",
                    "workspace": f"{base}/workspace/coder",
                    "agentDir": f"{base}/agents/coder",
                    "model": {
                        "primary": default_model
                    }
                },
                {
                    "id": "designer",
                    "name": "Creator",
                    "workspace": f"{base}/workspace/designer",
                    "agentDir": f"{base}/agents/designer",
                    "model": {
                        "primary": default_model
                    }
                }
            ]
        },
        "gateway": {
            "mode": "local",
            "port": 7860,
            "bind": "custom",
            "customBindHost": "0.0.0.0",
            "auth": {
                "mode": "token",
                "token": os.getenv(
                    "OPENCLAW_GATEWAY_TOKEN",
                    "openclaw-hf-space-token-2026"
                ),
                "rateLimit": {
                    "exemptLoopback": True
                }
            },
            "controlUi": {
                "enabled": True,
                "dangerouslyDisableDeviceAuth": True,
                "dangerouslyAllowHostHeaderOriginFallback": True,
                "allowedOrigins": [
                    hf_origin,
                    "https://*.hf.space"
                ]
            }
        }
    }


def get_current_primary(config):
    try:
        primary = config.get("agents", {}).get("defaults", {}).get("model", {}).get("primary", "")
        if primary:
            return primary
    except Exception:
        pass

    try:
        for agent in config.get("agents", {}).get("list", []):
            primary = agent.get("model", {}).get("primary", "")
            if primary:
                return primary
    except Exception:
        pass

    return default_model


def ensure_runtime_config(config):
    if not isinstance(config, dict):
        config = {}

    config.setdefault("logging", {})
    config["logging"].setdefault("level", "info")

    config.setdefault("models", {})
    config["models"].setdefault("providers", {})

    # 如果 openclaw.json 已经存在，不覆盖已有 models.providers。
    # 如果 providers 为空，才写入第一个 Agnes 模型。
    if not config["models"]["providers"]:
        config["models"]["providers"]["agnes"] = {
            "baseUrl": "https://apihub.agnes-ai.com/v1",
            "apiKey": agnes_api_key,
            "api": "openai-completions",
            "models": [
                {
                    "id": "agnes-2.0-flash",
                    "name": "Agnes 2.0 Flash",
                    "input": [
                        "text"
                    ],
                    "reasoning": False,
                    "contextWindow": 200000,
                    "maxTokens": 8192
                }
            ]
        }

    # 如果 Agnes 已存在但 apiKey 为空，并且环境变量里有 key，则补上
    if "agnes" in config["models"]["providers"]:
        if agnes_api_key and not config["models"]["providers"]["agnes"].get("apiKey"):
            config["models"]["providers"]["agnes"]["apiKey"] = agnes_api_key

    primary = get_current_primary(config)

    config.setdefault("channels", {})

    config["channels"].setdefault("feishu", {})
    config["channels"]["feishu"].update({
        "enabled": True,
        "dmPolicy": "open",
        "accounts": {
            "default": {
                "appId": os.getenv("FEISHU_APP_ID", ""),
                "appSecret": os.getenv("FEISHU_APP_SECRET", ""),
                "name": "OpenClaw Assistant"
            }
        }
    })

    config["channels"].setdefault("openclaw-weixin", {})
    config["channels"]["openclaw-weixin"]["enabled"] = os.getenv("WECHAT_ENABLE", "0") == "1"

    config["channels"].setdefault("telegram", {})
    config["channels"]["telegram"].update({
        "enabled": os.getenv("TELEGRAM_ENABLE", "0") == "1",
        "botToken": os.getenv("TELEGRAM_BOT_TOKEN", ""),
        "dmPolicy": os.getenv("TELEGRAM_DM_POLICY", "open"),
        "allowFrom": [
            x.strip()
            for x in os.getenv("TELEGRAM_ALLOW_FROM", "*").split(",")
            if x.strip()
        ],
        "groupPolicy": os.getenv("TELEGRAM_GROUP_POLICY", "disabled"),
        "groups": config["channels"]["telegram"].get("groups", {})
    })

    config.setdefault("plugins", {})
    config["plugins"].setdefault("entries", {})
    config["plugins"]["entries"].setdefault("openclaw-weixin", {})
    config["plugins"]["entries"]["openclaw-weixin"]["enabled"] = os.getenv("WECHAT_ENABLE", "0") == "1"

    config.setdefault("tools", {})
    config["tools"].setdefault("profile", "full")
    config["tools"].setdefault("deny", ["cron"])

    config.setdefault("agents", {})
    config["agents"].setdefault("defaults", {})
    config["agents"]["defaults"].setdefault("model", {})
    config["agents"]["defaults"].setdefault("params", {})

    if not config["agents"]["defaults"]["model"].get("primary"):
        config["agents"]["defaults"]["model"]["primary"] = primary

    primary = config["agents"]["defaults"]["model"].get("primary", primary)

    if not config["agents"].get("list"):
        config["agents"]["list"] = [
            {
                "id": "assistant",
                "name": "Team Leader",
                "default": True,
                "workspace": f"{base}/workspace/assistant",
                "agentDir": f"{base}/agents/assistant",
                "model": {
                    "primary": primary
                },
                "subagents": {
                    "allowAgents": [
                        "coder",
                        "designer"
                    ],
                    "model": {
                        "primary": primary
                    }
                }
            },
            {
                "id": "coder",
                "name": "Engineer",
                "workspace": f"{base}/workspace/coder",
                "agentDir": f"{base}/agents/coder",
                "model": {
                    "primary": primary
                }
            },
            {
                "id": "designer",
                "name": "Creator",
                "workspace": f"{base}/workspace/designer",
                "agentDir": f"{base}/agents/designer",
                "model": {
                    "primary": primary
                }
            }
        ]
    else:
        for agent in config["agents"]["list"]:
            agent_id = agent.get("id", "")

            if agent_id == "assistant":
                agent.setdefault("workspace", f"{base}/workspace/assistant")
                agent.setdefault("agentDir", f"{base}/agents/assistant")
            elif agent_id == "coder":
                agent.setdefault("workspace", f"{base}/workspace/coder")
                agent.setdefault("agentDir", f"{base}/agents/coder")
            elif agent_id == "designer":
                agent.setdefault("workspace", f"{base}/workspace/designer")
                agent.setdefault("agentDir", f"{base}/agents/designer")

            agent.setdefault("model", {})
            if not agent["model"].get("primary"):
                agent["model"]["primary"] = primary

            if agent_id == "assistant":
                agent.setdefault("subagents", {})
                agent["subagents"].setdefault("allowAgents", ["coder", "designer"])
                agent["subagents"].setdefault("model", {})
                if not agent["subagents"]["model"].get("primary"):
                    agent["subagents"]["model"]["primary"] = primary

    config["gateway"] = {
        "mode": "local",
        "port": 7860,
        "bind": "custom",
        "customBindHost": "0.0.0.0",
        "auth": {
            "mode": "token",
            "token": os.getenv(
                "OPENCLAW_GATEWAY_TOKEN",
                "openclaw-hf-space-token-2026"
            ),
            "rateLimit": {
                "exemptLoopback": True
            }
        },
        "controlUi": {
            "enabled": True,
            "dangerouslyDisableDeviceAuth": True,
            "dangerouslyAllowHostHeaderOriginFallback": True,
            "allowedOrigins": [
                hf_origin,
                "https://*.hf.space"
            ]
        }
    }

    return config


if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            config = json.load(f)

        print("[CONFIG] 检测到已有 openclaw.json。")
        print("[CONFIG] 保留已有 models.providers，不从其他文件读取模型。")

    except Exception as e:
        broken_path = f"{config_path}.broken.{int(time.time())}"
        try:
            os.rename(config_path, broken_path)
            print(f"[CONFIG] openclaw.json 解析失败，已备份到: {broken_path}")
        except Exception:
            print("[CONFIG] openclaw.json 解析失败，且备份失败。")

        print(f"[CONFIG] 解析错误: {e}")
        config = first_config()
else:
    print("[CONFIG] 未发现 openclaw.json，创建首次配置。")
    config = first_config()

config = ensure_runtime_config(config)

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

providers = config.get("models", {}).get("providers", {})
primary = config.get("agents", {}).get("defaults", {}).get("model", {}).get("primary", "")

print(f"[CONFIG] openclaw.json 已写入: {config_path}")
print(f"[CONFIG] 当前 provider 数量: {len(providers)}")
print(f"[CONFIG] 当前默认模型: {primary or '未设置'}")

if "agnes" in providers and not providers["agnes"].get("apiKey"):
    print("[WARN] Agnes provider 缺少 apiKey。请在 Hugging Face Secrets 添加 AGNES_API_KEY。")
PYTHON_EOF

echo "--- 6. 写入执行授权配置 ---"

cat > "$OC_HOME/exec-approvals.json" << 'APPROVALS_EOF'
{
  "allow": {
    "127.0.0.1": [
      "*"
    ],
    "localhost": [
      "*"
    ]
  },
  "trust": {
    "assistant": [
      "coder",
      "designer"
    ]
  }
}
APPROVALS_EOF

echo "--- 7. 修复 OpenClaw 配置兼容性 ---"

openclaw doctor --fix || echo "[DOCTOR] Config migration completed or not needed."

echo "--- 8. 微信登录态清理检查 ---"

if [ "${FORCE_WECHAT_RELOGIN:-0}" = "1" ]; then
  echo "[WECHAT] FORCE_WECHAT_RELOGIN=1，正在清理旧微信登录态..."
  find "$OC_HOME" -maxdepth 6 \( -iname "*weixin*" -o -iname "*wechat*" \) -print -exec rm -rf {} + || true
  echo "[WECHAT] 旧微信登录态已清理。"
else
  echo "[WECHAT] 不清理微信登录态。"
fi

echo "--- 9. 微信插件配置 ---"

if [ "${WECHAT_ENABLE:-0}" = "1" ]; then
  echo "[WECHAT] Installing/enabling @tencent-weixin/openclaw-weixin..."

  openclaw plugins install "@tencent-weixin/openclaw-weixin@2.4.3" || echo "[WECHAT] Plugin install skipped/failed; continuing."

  openclaw config set plugins.entries.openclaw-weixin.enabled true || true
  openclaw config set channels.openclaw-weixin.enabled true || true

  echo "[WECHAT] Running doctor after plugin setup..."
  openclaw doctor --fix || echo "[WECHAT] Doctor after plugin setup failed/skipped; continuing."

  if [ "${WECHAT_LOGIN_ON_START:-0}" = "1" ]; then
    echo "[WECHAT] QR login starting. Check Hugging Face Logs for QR code."

    openclaw channels login --channel openclaw-weixin || echo "[WECHAT] Login command exited; check logs."

    echo "[WECHAT] QR login step finished."

    if [ "${SKIP_BACKUP:-0}" = "1" ]; then
      echo "[WECHAT] SKIP_BACKUP=1，跳过扫码后的强制备份。"
    else
      echo "[WECHAT] Force backup after login..."
      python3 sync.py backup || echo "[WECHAT] Force backup failed."
    fi
  else
    echo "[WECHAT] QR login skipped. Set WECHAT_LOGIN_ON_START=1 when needed."
  fi
else
  echo "[WECHAT] Disabled. Set WECHAT_ENABLE=1 to enable."
fi

echo "--- 10. 自动备份配置 ---"

if [ "${SKIP_BACKUP:-0}" = "1" ]; then
  echo "[BACKUP] SKIP_BACKUP=1，跳过自动备份。"
else
  echo "[BACKUP] Starting intelligent backup controller..."
  python3 /home/node/app/backup_controller.py &
fi

echo "--- 11. 启动 OpenClaw Gateway ---"

exec openclaw gateway run \
  --port 7860 \
  --token "${OPENCLAW_GATEWAY_TOKEN:-openclaw-hf-space-token-2026}" \
  --allow-unconfigured