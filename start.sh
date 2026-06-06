#!/bin/bash

# ==========================================
# OpenClaw 2026.4.5 最新版
# 策略：JSON 保持最简，权限交给 exec-approvals.json
# 更新：支持 v2026.4.5 新配置格式
# 新增：支持跳过恢复、强制微信重新扫码、跳过备份
# 修复：模型默认值与聊天内模型覆盖冲突问题
# ==========================================

OC_HOME="/home/node/.openclaw"
CONF_FILE="/home/node/app/configs/models_config.json"
export HF_ORIGIN="https://${HF_SPACE_OWNER:-tianmingyun999}-${HF_SPACE_NAME:-openclaw2}.hf.space"

# 可选开关：
# SKIP_RESTORE=1             跳过 Hugging Face Dataset / S3 恢复
# RESET_MODEL_OVERRIDE=1     只在本次启动清理旧的聊天模型覆盖，例如旧 Agnes；正常使用后改回 0
# FORCE_WECHAT_RELOGIN=1     清理旧微信登录态，强制重新扫码
# SKIP_BACKUP=1              跳过自动备份，也跳过扫码后的强制备份
# WECHAT_ENABLE=1            启用微信插件
# WECHAT_LOGIN_ON_START=1    启动时执行微信扫码登录
# TELEGRAM_ENABLE=1          启用 Telegram Bot
# TELEGRAM_BOT_TOKEN=xxx     BotFather 生成的 Telegram Bot Token
# TELEGRAM_DM_POLICY=open    测试阶段开放私聊，跑通后建议改 allowlist
# TELEGRAM_ALLOW_FROM=*      测试阶段允许所有人，跑通后填你的 Telegram user id
# DEFAULT_PROVIDER=nvidia    环境变量层面的默认 provider
# CHAT_MODEL=xxx             环境变量层面的默认模型 id

set -euo pipefail

# 出错时尽量不要让整个 Space 直接退出，关键命令处仍然使用 || echo 兜底。
echo "--- 📂 1. 环境清洗 ---"
rm -rf "$OC_HOME/agents/main"
rm -rf "$OC_HOME/index.db"
mkdir -p "$OC_HOME/agents/assistant" "$OC_HOME/agents/coder" "$OC_HOME/agents/designer"
mkdir -p "$OC_HOME/workspace/assistant" "$OC_HOME/workspace/coder" "$OC_HOME/workspace/designer"

echo "--- 💾 2. 同步恢复 ---"
if [ "${SKIP_RESTORE:-0}" = "1" ]; then
    echo "[SYNC] SKIP_RESTORE=1，跳过备份恢复，使用当前环境启动。"
else
    if [ -n "${RESTORE_DATE:-}" ]; then
        echo "[SYNC] Restoring to date/key: $RESTORE_DATE"
        python3 sync.py restore "$RESTORE_DATE" || echo "[SYNC] Restore failed, starting fresh."
    else
        echo "[SYNC] Restoring latest backup..."
        python3 sync.py restore || echo "[SYNC] Starting fresh."
    fi
fi

# restore 可能清空并重建了 OC_HOME，所以这里再次保证目录存在。
mkdir -p "$OC_HOME/agents/assistant" "$OC_HOME/agents/coder" "$OC_HOME/agents/designer"
mkdir -p "$OC_HOME/workspace/assistant" "$OC_HOME/workspace/coder" "$OC_HOME/workspace/designer"

echo "--- 🧹 3. 模型覆盖清理检查 ---"
if [ "${RESET_MODEL_OVERRIDE:-0}" = "1" ]; then
    echo "[MODEL] RESET_MODEL_OVERRIDE=1，清理旧模型覆盖配置。"
    rm -f "$OC_HOME/workspace/assistant/model_override.json"
else
    echo "[MODEL] 保留 model_override.json，允许聊天中修改默认模型。"
fi

echo "--- ⚙️ 4. 解析模型配置 ---"
export MODELS_JSON=$(python3 << 'PYTHON_EOF'
import os, json, sys

config_path = '/home/node/app/configs/models_config.json'
try:
    with open(config_path, 'r') as f:
        cfg = json.load(f)
except Exception as e:
    print(f"[MODEL] Failed to load {config_path}: {e}", file=sys.stderr)
    cfg = {"providers": {}}

# 可选：允许用户通过 OpenClaw 对话添加自定义模型配置
# 文件路径：/home/node/.openclaw/workspace/assistant/custom_models.json
# 格式：{"providers": {"provider_id": {"baseUrl": "...", "api": "openai-completions", "keyEnv": "XXX_KEY", "models": [...]}}}
custom_path = '/home/node/.openclaw/workspace/assistant/custom_models.json'
try:
    if os.path.exists(custom_path):
        with open(custom_path, 'r') as f:
            custom_cfg = json.load(f)
        if isinstance(custom_cfg, dict) and isinstance(custom_cfg.get('providers'), dict):
            cfg.setdefault('providers', {})
            cfg['providers'].update(custom_cfg['providers'])
            print(f"[MODEL] Loaded custom models from {custom_path}", file=sys.stderr)
except Exception as e:
    print(f"[MODEL] Failed to load custom models: {e}", file=sys.stderr)

key_map = {
    "google": "GGL_KEY",
    "nvidia": "NVIDIA_API_KEY",
    "nvapi": "NVIDIA_API_KEY",
    "agnes": "AGNES_KEY",
    "openrouter": "OPR_KEY",
    "deepseek": "DS_KEY",
    "siliconflow": "SF_KEY",
    "zhipu": "GLM_KEY",
    "mistral": "MST_KEY",
    "moonshot": "KIM_KEY",
    "longCat": "LONGCAT_KEY",
    "openai": "OPENAI_KEY",
    "anthropic": "ANTHROPIC_KEY"
}

output = {"providers": {}}
for p_id, p_info in cfg.get('providers', {}).items():
    key_env = p_info.get('keyEnv') or key_map.get(p_id, "")
    api_key = os.getenv(key_env) if key_env else None
    if api_key:
        if 'models' in p_info:
            models_list = p_info['models']
        elif 'main' in p_info:
            models_list = [
                {"id": p_info[role], "name": f"{p_id}-{role}"}
                for role in ['main', 'code', 'image']
                if role in p_info
            ]
        else:
            models_list = []

        url = p_info.get('url') or p_info.get('baseUrl')
        provider_config = {"baseUrl": url, "apiKey": api_key, "models": models_list}
        if 'api' in p_info:
            provider_config['api'] = p_info['api']
        if p_info.get('authHeader') is not None:
            provider_config['authHeader'] = p_info.get('authHeader')
        output["providers"][p_id] = provider_config
    else:
        print(f"[MODEL] Provider skipped because key is missing: {p_id} / env={key_env}", file=sys.stderr)

print(json.dumps(output, ensure_ascii=False) if output["providers"] else '{"providers": {}}')
PYTHON_EOF
)

echo "--- 🛠️ 5. 构建 OpenClaw JSON ---"
python3 << 'PYTHON_EOF'
import json, os, sys

models_data = json.loads(os.getenv('MODELS_JSON', '{"providers":{}}'))
base = "/home/node/.openclaw"
hf_origin = os.getenv('HF_ORIGIN', '')


def resolve_model():
    default_provider = os.getenv('DEFAULT_PROVIDER', 'google')
    chat_model = os.getenv('CHAT_MODEL', 'gemini-2.0-flash')

    # 可选：允许用户通过 OpenClaw 对话修改默认模型
    # 文件路径：/home/node/.openclaw/workspace/assistant/model_override.json
    # 格式：{"provider":"agnes", "model":"agnes-2.0-flash"}
    override_path = f"{base}/workspace/assistant/model_override.json"
    if os.path.exists(override_path):
        try:
            with open(override_path, 'r') as f:
                override = json.load(f)
            default_provider = override.get('provider', default_provider)
            chat_model = override.get('model', chat_model)
            print(f"[MODEL_OVERRIDE] 使用聊天覆盖配置: {default_provider}/{chat_model}", file=sys.stderr)
        except Exception as e:
            print(f"[MODEL_OVERRIDE] 读取失败，继续使用环境变量: {e}", file=sys.stderr)
    else:
        print(f"[MODEL] 未检测到 model_override.json，使用环境变量默认模型: {default_provider}/{chat_model}", file=sys.stderr)

    if chat_model.startswith(f"{default_provider}/"):
        model_name = chat_model
    else:
        model_name = f"{default_provider}/{chat_model}"

    provider_exists = default_provider in models_data.get('providers', {})
    if not provider_exists:
        print(f"[MODEL_WARNING] 当前默认 provider 未注册或缺少 API Key: {default_provider}", file=sys.stderr)

    provider_models = models_data.get('providers', {}).get(default_provider, {}).get('models', [])
    known_ids = {m.get('id') for m in provider_models if isinstance(m, dict)}
    raw_model = chat_model[len(default_provider) + 1:] if chat_model.startswith(f"{default_provider}/") else chat_model
    if provider_exists and known_ids and raw_model not in known_ids:
        print(f"[MODEL_WARNING] 当前模型不在 models_config.json 的 {default_provider}.models 里: {raw_model}", file=sys.stderr)
        print(f"[MODEL_WARNING] 已注册模型: {sorted(known_ids)}", file=sys.stderr)

    return model_name


model_name = resolve_model()
print(f"[配置] 使用模型: {model_name}", file=sys.stderr)

config = {
    "logging": {"level": "info"},
    "models": models_data,
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
                x.strip() for x in os.getenv("TELEGRAM_ALLOW_FROM", "*").split(",")
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
        "deny": ["cron"]
    },
    "agents": {
        "defaults": {
            "model": {"primary": model_name},
            "params": {}
        },
        "list": [
            {
                "id": "assistant",
                "name": "Team Leader",
                "default": True,
                "workspace": f"{base}/workspace/assistant",
                "agentDir": f"{base}/agents/assistant",
                "model": {"primary": model_name},
                "subagents": {
                    "allowAgents": ["coder", "designer"],
                    "model": {"primary": model_name}
                }
            },
            {
                "id": "coder",
                "name": "Engineer",
                "workspace": f"{base}/workspace/coder",
                "agentDir": f"{base}/agents/coder",
                "model": {"primary": model_name}
            },
            {
                "id": "designer",
                "name": "Creator",
                "workspace": f"{base}/workspace/designer",
                "agentDir": f"{base}/agents/designer",
                "model": {"primary": model_name}
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
            "token": os.getenv("OPENCLAW_GATEWAY_TOKEN", "openclaw-hf-space-token-2026"),
            "rateLimit": {
                "exemptLoopback": True
            }
        },
        "controlUi": {
            "enabled": True,
            "dangerouslyDisableDeviceAuth": True,
            "dangerouslyAllowHostHeaderOriginFallback": True,
            "allowedOrigins": [hf_origin, "https://*.hf.space"]
        }
    }
}

os.makedirs(base, exist_ok=True)
with open(f"{base}/openclaw.json", 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
PYTHON_EOF

echo "--- 🛡️ 6. 强制物理授权 (解决 4.1 配对拦截) ---"
cat > "$OC_HOME/exec-approvals.json" << 'APPROVALS_EOF'
{
  "allow": {
    "127.0.0.1": ["*"],
    "localhost": ["*"]
  },
  "trust": {
    "assistant": ["coder", "designer"]
  }
}
APPROVALS_EOF

echo "--- 💾 7. 修复配置兼容性 (OpenClaw 2026.4.5) ---"
openclaw doctor --fix || echo "[DOCTOR] Config migration completed or not needed."

echo "--- 🔎 8. 验证模型配置 ---"
python3 << 'VERIFY_EOF'
import json, os, sys

base = "/home/node/.openclaw"
models_data = json.loads(os.getenv('MODELS_JSON', '{"providers":{}}'))

def resolve_expected_model():
    default_provider = os.getenv('DEFAULT_PROVIDER', 'google')
    chat_model = os.getenv('CHAT_MODEL', 'gemini-2.0-flash')

    override_path = f"{base}/workspace/assistant/model_override.json"
    if os.path.exists(override_path):
        try:
            with open(override_path, 'r') as f:
                override = json.load(f)
            default_provider = override.get('provider', default_provider)
            chat_model = override.get('model', chat_model)
            print(f"[MODEL_OVERRIDE] 验证阶段使用聊天覆盖配置: {default_provider}/{chat_model}", file=sys.stderr)
        except Exception as e:
            print(f"[MODEL_OVERRIDE] 验证阶段读取失败，继续使用环境变量: {e}", file=sys.stderr)

    if chat_model.startswith(f"{default_provider}/"):
        return default_provider, chat_model
    return default_provider, f"{default_provider}/{chat_model}"

try:
    expected_provider, expected_model = resolve_expected_model()

    with open(f"{base}/openclaw.json", 'r') as f:
        config = json.load(f)

    actual_model = config.get('agents', {}).get('defaults', {}).get('model', {}).get('primary', 'NOT_FOUND')

    if actual_model != expected_model:
        print(f"[警告] 配置不匹配！期望: {expected_model}, 实际: {actual_model}", file=sys.stderr)
        print("[警告] 正在重新写入正确配置...", file=sys.stderr)

        config['agents']['defaults']['model']['primary'] = expected_model
        for agent in config['agents']['list']:
            agent['model']['primary'] = expected_model
            if 'subagents' in agent:
                agent['subagents']['model']['primary'] = expected_model

        with open(f"{base}/openclaw.json", 'w') as f:
            json.dump(config, f, indent=2, ensure_ascii=False)

        print(f"[修复] 配置已更正为: {expected_model}", file=sys.stderr)
    else:
        print(f"[验证] 配置正确: {actual_model}", file=sys.stderr)

    if expected_provider not in models_data.get('providers', {}):
        print(f"[警告] Provider 未注册，通常是缺少对应 API Key: {expected_provider}", file=sys.stderr)
except Exception as e:
    print(f"[错误] 验证配置时出错: {e}", file=sys.stderr)
VERIFY_EOF

echo "--- 🧹 9. 微信登录态清理检查 ---"
if [ "${FORCE_WECHAT_RELOGIN:-0}" = "1" ]; then
    echo "[WECHAT] FORCE_WECHAT_RELOGIN=1，正在清理旧微信登录态..."
    find "$OC_HOME" -maxdepth 6 \( -iname "*weixin*" -o -iname "*wechat*" \) -print -exec rm -rf {} + || true
    echo "[WECHAT] 旧微信登录态清理完成，本次将重新扫码。"
else
    echo "[WECHAT] 不清理微信登录态。"
fi

echo "--- 🟢 10. 微信插件配置 ---"
if [ "${WECHAT_ENABLE:-0}" = "1" ]; then
    echo "[WECHAT] Installing/enabling @tencent-weixin/openclaw-weixin..."
    # 固定安装医生提示的兼容版本，避免 latest 变动导致 Gateway 不加载外部插件
    openclaw plugins install "@tencent-weixin/openclaw-weixin@2.4.3" || echo "[WECHAT] Plugin install skipped/failed; continuing."
    openclaw config set plugins.entries.openclaw-weixin.enabled true || true
    openclaw config set channels.openclaw-weixin.enabled true || true

    echo "[WECHAT] Running doctor after plugin setup so gateway can load openclaw-weixin..."
    openclaw doctor --fix || echo "[WECHAT] Doctor after plugin setup failed/skipped; continuing."

    if [ "${WECHAT_LOGIN_ON_START:-0}" = "1" ]; then
        echo "[WECHAT] QR login starting. Check Hugging Face Logs for the QR code."
        echo "[WECHAT] After successful scan, this script will force a backup unless SKIP_BACKUP=1."
        openclaw channels login --channel openclaw-weixin || echo "[WECHAT] Login command exited; check logs."

        echo "[WECHAT] QR login step finished."
        if [ "${SKIP_BACKUP:-0}" = "1" ]; then
            echo "[WECHAT] SKIP_BACKUP=1，跳过扫码后的强制备份。"
        else
            echo "[WECHAT] Force backup after login..."
            python3 sync.py backup || echo "[WECHAT] Force backup failed."
        fi
    else
        echo "[WECHAT] QR login skipped. Set WECHAT_LOGIN_ON_START=1 only when you need to scan."
    fi
else
    echo "[WECHAT] Disabled. Set WECHAT_ENABLE=1 to enable openclaw-weixin."
fi

# 启动智能备份控制器（方案B：变化检测 + 2小时强制备份）
echo "--- 💾 11. 自动备份配置 ---"
if [ "${SKIP_BACKUP:-0}" = "1" ]; then
    echo "[BACKUP] SKIP_BACKUP=1，跳过自动备份。"
else
    echo "[BACKUP] Starting intelligent backup controller (Strategy B)..."
    echo "[BACKUP] - Change detection: every 5 minutes"
    echo "[BACKUP] - Max interval: 2 hours (forced backup)"
    echo "[BACKUP] - Min interval: 5 minutes (avoid duplicates)"
    echo "[BACKUP] - Retention: 180 days"
    python3 /home/node/app/backup_controller.py &
fi

echo "--- 🚀 12. 启动 OpenClaw Gateway ---"
exec openclaw gateway run --port 7860 --token "${OPENCLAW_GATEWAY_TOKEN:-openclaw-hf-space-token-2026}" --allow-unconfigured