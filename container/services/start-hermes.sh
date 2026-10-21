#!/bin/sh
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"
export HERMES_HOME

mkdir -p "$HERMES_HOME"

# Restore before starting Hermes. Failure must stop startup.
 /opt/hermes-azure/scripts/restore.sh

# Preserve the existing model configuration behavior.
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
    printf 'model:\n  provider: "ollama-cloud"\n  default: "nemotron-3-super:cloud"\n  base_url: "https://ollama.com/v1"\n' > "$HERMES_HOME/config.yaml"
else
    python3 -c '
from pathlib import Path
p = Path(__import__("os").environ["HERMES_HOME"]) / "config.yaml"
s = p.read_text()
s = s.replace("default: \"anthropic/claude-opus-4.6\"", "default: \"nemotron-3-super:cloud\"")
s = s.replace("provider: \"auto\"", "provider: \"ollama-cloud\"")
s = s.replace("base_url: \"https://openrouter.ai/api/v1\"", "base_url: \"https://ollama.com/v1\"")
p.write_text(s)
'
fi

# Gateway and backup lifecycle will be added after the restore tests.
exec /opt/hermes/.venv/bin/python /opt/hermes-azure/services/supervisor.py

