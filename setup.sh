#!/usr/bin/env bash
# SentinelReady setup — detects an existing Ollama before starting a second one.
#
# Beta issue #15: docker-compose.yml always started its own Ollama, and
# sentinelready.yaml marked ollama_host "do not change", so a host already
# running Ollama ended up with two copies competing for the same RAM and
# GPU — each holding a multi-GB model resident.
#
# Compose is declarative and cannot branch on what's installed, so the
# decision has to happen before it runs. This script probes, asks, and
# writes .env accordingly. It never starts anything on its own.
#
# DELIBERATELY NEVER MODIFIES AN EXISTING OLLAMA. Not an upgrade, not a
# restart, not a config change. That process may be serving workloads
# SentinelReady knows nothing about, and a version bump to suit us could
# break them. If something needs doing there, this prints the command and
# leaves it to you.
set -euo pipefail

# Must match docker-compose.yml's pull default and sentinelready.yaml.example.
# 1.0.9 changed the shipped default because llama3.1 does not read the number
# in an alert -- it answered "interrupt someone now" to all six controlled
# cases, including a 12%-full disk it called "critically high, above 90%".
# This script and .env.example were missed in that change, so a new customer
# following the documented setup still got llama3.1.
MODEL="${SENTINEL_MODEL:-mistral:7b-instruct-v0.3-q4_K_M}"
ENV_FILE=".env"

say()  { printf '%s\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

probe() {  # $1 = url -> echoes version on success
    curl -fsS --max-time 3 "$1/api/version" 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'
}

bold "SentinelReady setup"
say

FOUND_URL=""; FOUND_VER=""
for url in "http://localhost:11434" "http://host.docker.internal:11434"; do
    ver="$(probe "$url" || true)"
    if [ -n "$ver" ]; then FOUND_URL="$url"; FOUND_VER="$ver"; break; fi
done

if [ -z "$FOUND_URL" ]; then
    say "No existing Ollama found on this host."
    say "SentinelReady will start its own and pull '$MODEL' on first run."
    say
    say "Start it with:"
    bold "  docker compose up -d"
    say
    say "Have an Ollama elsewhere on your network? Point at it instead:"
    say "  OLLAMA_URL=http://ITS-IP:11434 \\"
    say "    docker compose -f docker-compose.yml -f docker-compose.external-ollama.yml up -d"
    exit 0
fi

say "Found an existing Ollama:"
say "  URL     : $FOUND_URL"
say "  Version : $FOUND_VER"

if curl -fsS --max-time 5 "$FOUND_URL/api/tags" 2>/dev/null | grep -q "\"$MODEL"; then
    say "  Model   : '$MODEL' is already present"
    MODEL_READY=yes
else
    say "  Model   : '$MODEL' is NOT present"
    MODEL_READY=no
fi
say

say "Reusing it avoids running a second Ollama that would hold another copy"
say "of the model in RAM (and contend for the same GPU)."
say
printf 'Use this existing Ollama? [Y/n] '
read -r reply || reply=""
case "${reply:-Y}" in
    [Nn]*)
        say
        say "Leaving it untouched. SentinelReady will start its own alongside it."
        say "Note both will hold a copy of the model resident."
        say
        bold "  docker compose up -d"
        exit 0
        ;;
esac

if [ "$MODEL_READY" = "no" ]; then
    say
    bold "One thing to do first — on the Ollama host, run:"
    say "  ollama pull $MODEL"
    say
    say "Not done automatically on purpose: that's your Ollama, and pulling a"
    say "multi-GB model into it is your call, not ours."
fi

if [ -f "$ENV_FILE" ] && grep -q '^OLLAMA_URL=' "$ENV_FILE"; then
    say
    say "$ENV_FILE already sets OLLAMA_URL — leaving it as-is:"
    grep '^OLLAMA_URL=' "$ENV_FILE" | sed 's/^/  /'
else
    printf 'OLLAMA_URL=%s\n' "$FOUND_URL" >> "$ENV_FILE"
    say
    say "Wrote OLLAMA_URL=$FOUND_URL to $ENV_FILE"
fi

say
say "Also set this in sentinelready.yaml so the app agrees:"
say "  ai:"
say "    ollama_host: $FOUND_URL"
say
bold "Then start with:"
say "  docker compose -f docker-compose.yml -f docker-compose.external-ollama.yml up -d"
say
say "(If Ollama refuses the connection from the container, it's bound to"
say " 127.0.0.1. Set OLLAMA_HOST=0.0.0.0 on the Ollama host and restart it.)"
