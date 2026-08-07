#!/usr/bin/env bash

set -u

# ==================================================
# Oracle A1 Catcher
# ==================================================
#
# This script periodically attempts to create an OCI
# VM.Standard.A1.Flex instance when capacity becomes
# available.
#
# Configuration is loaded from .env
#
# NEVER commit your real .env file.
# ==================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: configuration file not found: $ENV_FILE"
    echo "Copy .env.example to .env and configure it first."
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# ==================================================
# DEFAULT SETTINGS
# ==================================================

INSTANCE_NAME="${INSTANCE_NAME:-instance-a1-auto}"
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"

RETRY_SECONDS="${RETRY_SECONDS:-60}"
PAUSE_BETWEEN_REQUESTS="${PAUSE_BETWEEN_REQUESTS:-5}"
STATUS_NOTIFICATION_SECONDS="${STATUS_NOTIFICATION_SECONDS:-21600}"

LOG_FILE="${LOG_FILE:-$HOME/create-a1.log}"

SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/oracle_a1.pub}"

AVAILABILITY_DOMAINS=(
  "$OCI_AD_1"
  "$OCI_AD_2"
)

CONFIGURATIONS=(
  "1:6"
  "2:12"
)

# ==================================================
# LOGGING
# ==================================================

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

OUTPUT_FILE=""
ERROR_FILE=""

cleanup_temp_files() {
    [[ -n "${OUTPUT_FILE:-}" && -f "${OUTPUT_FILE:-}" ]] && rm -f "$OUTPUT_FILE"
    [[ -n "${ERROR_FILE:-}" && -f "${ERROR_FILE:-}" ]] && rm -f "$ERROR_FILE"
}

trap cleanup_temp_files EXIT

# ==================================================
# NOTIFICATIONS
# ==================================================

notify_telegram() {
    local message="$1"

    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" &&
          -n "${TELEGRAM_CHAT_ID:-}" ]]; then

        curl -fsS \
          --connect-timeout 15 \
          --max-time 30 \
          -X POST \
          "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
          --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
          --data-urlencode "text=${message}" \
          >/dev/null 2>&1 || \
          echo "WARNING: Telegram notification failed."
    fi
}

notify_start() {
    notify_telegram "🟢 Oracle A1 Catcher started

Host: $(hostname)
Instance: $INSTANCE_NAME
Shape: $SHAPE

Configurations:
- 1 OCPU / 6 GB
- 2 OCPU / 12 GB

Date: $(date '+%Y-%m-%d %H:%M:%S')"
}

notify_status() {
    local cycle="$1"

    notify_telegram "🔄 Oracle A1 Catcher is still running

Host: $(hostname)
Cycle: $cycle

No A1 capacity found yet.

Date: $(date '+%Y-%m-%d %H:%M:%S')"
}

notify_error() {
    local error_message="$1"

    error_message="$(printf '%s\n' "$error_message" | tail -n 20)"

    notify_telegram "❌ Oracle A1 Catcher stopped

Host: $(hostname)

Error:
$error_message

Log:
$LOG_FILE

Date: $(date '+%Y-%m-%d %H:%M:%S')"
}

# ==================================================
# OCI HELPERS
# ==================================================

instance_already_exists() {
    local count

    count="$(
        oci compute instance list \
          --compartment-id "$OCI_COMPARTMENT_ID" \
          --display-name "$INSTANCE_NAME" \
          --all \
          --query \
          'length(data[?`lifecycle-state` != `TERMINATED` && `lifecycle-state` != `TERMINATING`])' \
          --raw-output 2>/dev/null
    )"

    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    [[ "$count" -gt 0 ]]
}

get_public_ip() {
    local instance_id="$1"

    oci compute instance list-vnics \
      --instance-id "$instance_id" \
      --query 'data[0]."public-ip"' \
      --raw-output 2>/dev/null || true
}

# ==================================================
# VALIDATION
# ==================================================

for command in oci curl python3; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $command"
        exit 1
    fi
done

if [[ ! -f "$SSH_PUBLIC_KEY_FILE" ]]; then
    echo "ERROR: SSH public key not found:"
    echo "$SSH_PUBLIC_KEY_FILE"
    exit 1
fi

if ! oci iam region-subscription list \
     --output json >/dev/null 2>&1; then

    echo "ERROR: OCI authentication failed."
    notify_error "OCI authentication failed."
    exit 1
fi

if instance_already_exists; then
    echo "Instance $INSTANCE_NAME already exists."
    exit 0
fi

# ==================================================
# START
# ==================================================

echo "=============================================="
echo "Oracle Cloud A1 Catcher"
echo "=============================================="
echo "Instance : $INSTANCE_NAME"
echo "Shape    : $SHAPE"
echo "Log      : $LOG_FILE"
echo "Started  : $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="

notify_start

LAST_STATUS_NOTIFICATION="$(date +%s)"
cycle=1

# ==================================================
# MAIN LOOP
# ==================================================

while true; do

    echo
    echo "=============================================="
    echo "Cycle $cycle"
    echo "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "=============================================="

    if instance_already_exists; then
        echo "Instance already exists. Stopping."
        exit 0
    fi

    for CONFIG in "${CONFIGURATIONS[@]}"; do

        IFS=":" read -r OCPUS MEMORY_GB <<< "$CONFIG"

        for AD in "${AVAILABILITY_DOMAINS[@]}"; do

            echo
            echo "Trying:"
            echo "AD: $AD"
            echo "CPU: $OCPUS"
            echo "RAM: $MEMORY_GB GB"

            OUTPUT_FILE="$(mktemp)"
            ERROR_FILE="$(mktemp)"

            oci compute instance launch \
              --compartment-id "$OCI_COMPARTMENT_ID" \
              --availability-domain "$AD" \
              --display-name "$INSTANCE_NAME" \
              --shape "$SHAPE" \
              --shape-config \
                "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GB}}" \
              --subnet-id "$OCI_SUBNET_ID" \
              --image-id "$OCI_IMAGE_ID" \
              --assign-public-ip true \
              --ssh-authorized-keys-file "$SSH_PUBLIC_KEY_FILE" \
              --connection-timeout 30 \
              --read-timeout 120 \
              --max-retries 3 \
              --output json \
              >"$OUTPUT_FILE" 2>"$ERROR_FILE"

            STATUS=$?

            if [[ "$STATUS" -eq 0 ]]; then

                INSTANCE_ID="$(
                    python3 - "$OUTPUT_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f)["data"]["id"])
PY
                )"

                echo
                echo "INSTANCE CREATED SUCCESSFULLY"
                echo "OCID: $INSTANCE_ID"

                oci compute instance get \
                  --instance-id "$INSTANCE_ID" \
                  --wait-for-state RUNNING \
                  --max-wait-seconds 900 \
                  >/dev/null || true

                sleep 10

                PUBLIC_IP="$(get_public_ip "$INSTANCE_ID")"

                notify_telegram "🚀 Oracle Cloud A1 instance created!

Name:
$INSTANCE_NAME

Configuration:
$OCPUS OCPU / $MEMORY_GB GB

Availability Domain:
$AD

Public IP:
${PUBLIC_IP:-unavailable}

SSH:
ssh -i ~/.ssh/oracle_a1 opc@${PUBLIC_IP:-PUBLIC_IP}

Date:
$(date '+%Y-%m-%d %H:%M:%S')"

                echo "Public IP: ${PUBLIC_IP:-unavailable}"
                echo "Stopping catcher."

                exit 0
            fi

            ERROR_TEXT="$(cat "$ERROR_FILE")"

            if echo "$ERROR_TEXT" | grep -Eqi \
              "Out of capacity|Out of host capacity|OutOfHostCapacity"; then

                echo "No capacity available."

            elif echo "$ERROR_TEXT" | grep -Eqi \
              "timed out|ConnectTimeout|ReadTimeout|RequestException|ConnectionError|Connection reset|Max retries exceeded|temporarily unavailable"; then

                echo "Temporary network error. Will retry."

            elif echo "$ERROR_TEXT" | grep -Eqi \
              "TooManyRequests|429|ServiceUnavailable|InternalServerError|502|503|504"; then

                echo "Temporary OCI service/rate-limit error. Will retry."

            else
                echo "Unexpected OCI error:"
                cat "$ERROR_FILE"

                notify_error "$ERROR_TEXT"

                exit 1
            fi

            rm -f "$OUTPUT_FILE" "$ERROR_FILE"
            OUTPUT_FILE=""
            ERROR_FILE=""

            sleep "$PAUSE_BETWEEN_REQUESTS"
        done
    done

    CURRENT_TIME="$(date +%s)"

    if (( CURRENT_TIME - LAST_STATUS_NOTIFICATION >= STATUS_NOTIFICATION_SECONDS )); then
        notify_status "$cycle"
        LAST_STATUS_NOTIFICATION="$CURRENT_TIME"
    fi

    cycle=$((cycle + 1))

    echo
    echo "No capacity found. Retrying in ${RETRY_SECONDS}s."

    sleep "$RETRY_SECONDS"
done
