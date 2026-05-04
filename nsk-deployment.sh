#!/bin/bash

# Flag file to track execution
FLAG_FILE="/home/ubuntu/.publisher_token_initialized"
LOCK_FILE="/tmp/publisher_setup.lock"
TRACE_DIR="/home/ubuntu/logs"
LOG_TS="$(date -u +'%Y%m%dT%H%M%SZ')"
RUN_LOG="${TRACE_DIR}/run-publisher-setup-${LOG_TS}.log"
CREATE_RESPONSE_LOG="${TRACE_DIR}/publisher-create-response-${LOG_TS}.json"
TOKEN_RESPONSE_LOG="${TRACE_DIR}/publisher-token-response-${LOG_TS}.json"
SCRIPT_PATH="/usr/local/bin/run-publisher-setup.sh"
ANYAPP_LOG="${TRACE_DIR}/publisher-anyapp-enable-${LOG_TS}.log"
UPGRADE_LOG="${TRACE_DIR}/publisher-upgrade-${LOG_TS}.log"

mkdir -p "${TRACE_DIR}"

set -o pipefail

# Setup logging
exec > >(tee -a "${RUN_LOG}" | logger -t "$(basename "$0")") 2>&1

# Ensure only one instance runs
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "Another instance is running. Exiting."
    exit 1
fi

# Check if already run successfully
if [ -f "$FLAG_FILE" ]; then
    echo "Publisher already initialized. Exiting."
    exit 0
fi

# Wait for system to be ready
sleep 120

# Check if docker is running
while ! systemctl is-active --quiet docker; do
  sleep 10
done

# Function to wait for apt locks to be released
wait_for_apt() {
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
     echo "Waiting for other software managers to finish..."
     sleep 5
  done
}

# Function to install packages with retry
install_packages() {
  local max_attempts=10
  local attempt=1
  local packages="$1"
  
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt to install packages: $packages"
    wait_for_apt
    if sudo DEBIAN_FRONTEND=noninteractive apt-get update -y && \
       sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $packages; then
      echo "Package installation successful"
      return 0
    fi
    echo "Package installation failed, waiting before retry..."
    sleep 30
    attempt=$((attempt + 1))
  done
  echo "Failed to install packages after $max_attempts attempts"
  return 1
}

# Install required packages with retry
if ! install_packages "curl jq expect"; then
  echo "Failed to install required packages. Exiting."
  exit 1
fi

trace() {
  echo "TRACE $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*" >&2
}

decode_jwt_claim() {
  local token="$1"
  local claim="$2"
  local payload=""
  local padding=""

  payload=$(printf '%s' "${token}" | cut -d '.' -f 2 | tr '_-' '/+')
  case $((${#payload} % 4)) in
    2) padding='==' ;;
    3) padding='=' ;;
    *) padding='' ;;
  esac

  printf '%s' "${payload}${padding}" | base64 -d 2>/dev/null | jq -r "${claim} // empty" 2>/dev/null
}

json_get() {
  local query="$1"
  local payload="$2"
  jq -r "${query}" <<<"${payload}"
}

run_sensitive_capture() {
  local __resultvar="$1"
  shift
  local output=""
  output=$("$@")
  local status=$?
  printf -v "${__resultvar}" '%s' "${output}"
  return "${status}"
}

run_sensitive_pipeline() {
  bash -lc "$1"
}

cleanup_sensitive_artifacts() {
  trace "CleanupSensitiveLogs enabled. Removing sensitive artifacts."
  rm -f "${TOKEN_RESPONSE_LOG}"
  rm -f "${SCRIPT_PATH}"
}

run_wizard_menu_flow() {
  local flow_name="$1"
  local log_file="$2"
  shift 2
  local steps=("$@")
  local steps_serialized
  steps_serialized="$(printf "%s\n" "${steps[@]}")"

  trace "Starting wizard menu flow '${flow_name}'"
  trace "Wizard menu log file: ${log_file}"

  set +x
  EXPECT_FLOW_NAME="${flow_name}" \
  EXPECT_LOG_FILE="${log_file}" \
  EXPECT_WIZARD="/home/ubuntu/npa_publisher_wizard" \
  EXPECT_STEPS="${steps_serialized}" \
  /usr/bin/expect <<'EOF'
set timeout 1800
match_max 100000
set flow_name $env(EXPECT_FLOW_NAME)
set log_file $env(EXPECT_LOG_FILE)
set wizard $env(EXPECT_WIZARD)
set steps [split [string trim $env(EXPECT_STEPS)] "\n"]

log_file -a $log_file
spawn sudo $wizard

expect {
  -re "Configuration menu:" { send -- "[lindex $steps 0]\r" }
  timeout { puts stderr "Timed out waiting for initial menu for $flow_name"; exit 1 }
  eof { puts stderr "Wizard exited before initial menu for $flow_name"; exit 1 }
}

foreach step [lrange $steps 1 end] {
  expect {
    -re "Configuration menu:" {
      send -- "$step\r"
      exp_continue
    }
    -re "Please type 'yes' to proceed\\." {
      send -- "$step\r"
      exp_continue
    }
    -re "Are you sure you want to continue\\?" {
      send -- "$step\r"
      exp_continue
    }
    -re {\[Return\]} {
      send -- "\r"
      exp_continue
    }
    -re "Updates require a reboot\\. Please press enter to initiate the reboot\\." {
      send -- "\r"
      exp_continue
    }
    -re "Enter your choice.*" {
      send -- "$step\r"
      exp_continue
    }
    -re "Restarting publisher..." {
      exp_continue
    }
    timeout { puts stderr "Timed out while processing step '$step' for $flow_name"; exit 1 }
    eof { exit 0 }
  }
}

expect {
  eof { exit 0 }
  timeout { exit 0 }
}
EOF
  return $?
}

enable_anyapp() {
  trace "AnyApp enabled. Running post-registration AnyApp bootstrap."
  echo "Enabling AnyApp..."
  trace "AnyApp log file: ${ANYAPP_LOG}"
  if run_sensitive_pipeline "cd /home/ubuntu && sudo ./npa_publisher_wizard -ba_any_app enable 2>&1 | tee \"${ANYAPP_LOG}\""; then
    trace "AnyApp enable completed successfully."
    return 0
  fi
  trace "AnyApp flag path failed. Falling back to interactive menu flow."
  if run_wizard_menu_flow "anyapp-enable" "${ANYAPP_LOG}" "6" "1"; then
    trace "AnyApp menu flow completed successfully."
    return 0
  fi
  trace "AnyApp enable failed."
  return 1
}

run_upgrade_flow() {
  trace "UpgradePublisher enabled. Running upgrade flow."
  echo "Applying system updates and upgrading publisher image..."
  trace "Upgrade log file: ${UPGRADE_LOG}"
  set +x
  EXPECT_LOG_FILE="${UPGRADE_LOG}" \
  EXPECT_WIZARD="/home/ubuntu/npa_publisher_wizard" \
  /usr/bin/expect <<'EOF'
set timeout 3600
match_max 100000
set log_file $env(EXPECT_LOG_FILE)
set wizard $env(EXPECT_WIZARD)

log_file -a $log_file
spawn sudo $wizard

expect {
  -re {8\. Exit} { send -- "1\r" }
  timeout { puts stderr "Timed out waiting for top-level upgrade menu"; exit 1 }
  eof { puts stderr "Wizard exited before top-level upgrade menu"; exit 1 }
}

expect {
  -re {4\. Return to previous menu} { send -- "3\r" }
  timeout { puts stderr "Timed out waiting for upgrade submenu"; exit 1 }
  eof { puts stderr "Wizard exited before upgrade submenu"; exit 1 }
}

expect {
  -re {Please type 'yes' to proceed\.} { send -- "yes\r" }
  timeout { puts stderr "Timed out waiting for upgrade confirmation"; exit 1 }
  eof { exit 0 }
}

expect {
  -re {\[Return\]} { send -- "\r"; exp_continue }
  -re {Updates require a reboot\. Please press enter to initiate the reboot\.} { send -- "\r"; exp_continue }
  eof { exit 0 }
  timeout { exit 0 }
}
EOF
  local status=$?
  set -x
  if [ "${status}" -eq 0 ]; then
    trace "Upgrade flow completed successfully."
    return 0
  fi
  trace "Upgrade flow failed."
  return 1
}

request_registration_token() {
  local response status token http_body http_code

  run_sensitive_capture response curl -s -w $'\n%{http_code}' -X 'POST' "${TOKEN_URL}" \
    -H 'accept: application/json' \
    -H "Netskope-Api-Token: ${API_TOKEN}" \
    -d ''

  http_body=$(printf '%s\n' "${response}" | sed '$d')
  http_code=$(printf '%s\n' "${response}" | tail -n 1)
  printf '%s\n' "${http_body}" > "${TOKEN_RESPONSE_LOG}"
  trace "Token endpoint HTTP status: ${http_code}"
  trace "Token endpoint response saved to ${TOKEN_RESPONSE_LOG}"

  status=$(json_get '.status // empty' "${http_body}")
  if [ "${status}" != "success" ]; then
    echo "Failed to retrieve Publisher Token. Response: ${http_body}"
    return 1
  fi

  token=$(json_get '.data.token // empty' "${http_body}")
  if [ -z "${token}" ] || [ "${token}" = "null" ]; then
    echo "Publisher Token response did not include a usable token. Response: ${http_body}"
    return 1
  fi

  trace "Token length: ${#token}"
  trace "Token issuer: $(decode_jwt_claim "${token}" '.iss')"
  trace "Token subject: $(decode_jwt_claim "${token}" '.sub')"
  trace "Token expiry epoch: $(decode_jwt_claim "${token}" '.exp')"

  printf '%s' "${token}"
}

register_publisher() {
  local max_attempts=6
  local retry_delay=20
  local attempt=1
  local pub_token=""

  echo "Waiting ${retry_delay} seconds before first registration attempt to allow publisher propagation..."
  sleep "${retry_delay}"

  while [ "${attempt}" -le "${max_attempts}" ]; do
    local attempt_log="${TRACE_DIR}/publisher-registration-attempt-${attempt}-${LOG_TS}.log"
    echo "Registration attempt ${attempt}/${max_attempts}: requesting fresh token..."

    if pub_token=$(request_registration_token); then
      echo "Registration attempt ${attempt}/${max_attempts}: launching publisher wizard..."
      trace "Starting wizard attempt ${attempt} from /home/ubuntu"
      trace "Wizard attempt ${attempt} log file: ${attempt_log}"
      if run_sensitive_pipeline "cd /home/ubuntu && sudo ./npa_publisher_wizard -token \"${pub_token}\" 2>&1 | tee \"${attempt_log}\""; then
        return 0
      fi
      trace "Wizard attempt ${attempt} failed."
    fi

    if [ "${attempt}" -lt "${max_attempts}" ]; then
      echo "Registration attempt ${attempt}/${max_attempts} failed. Waiting ${retry_delay} seconds before retry..."
      sleep "${retry_delay}"
    fi

    attempt=$((attempt + 1))
  done

  return 1
}

# Configuration variables
TENANT_URL="##TENANT_URL##"
API_TOKEN="##API_TOKEN##"
PUB_NAME=$(hostname)
_PUB_TAG="##PUB_TAG##"
PUB_UPGRADE="##PUB_UPGRADE##"
CLEANUP_SENSITIVE_LOGS="##CLEANUP_SENSITIVE_LOGS##"
ENABLE_ANYAPP="##ENABLE_ANYAPP##"
UPGRADE_PUBLISHER_AFTER_REGISTER="##UPGRADE_PUBLISHER_AFTER_REGISTER##"

trace "Execution user: $(whoami)"
trace "Execution cwd: $(pwd)"
trace "Hostname: ${PUB_NAME}"
trace "/etc/hosts contents:"
sed 's/^/TRACE HOSTS /' /etc/hosts || true

# Verify if tags were provided
if [ ! -z "$_PUB_TAG" ]; then
  IFS=, read -a arr <<<"${_PUB_TAG}"
  printf -v tags ',{"tag_name": "%s"}' "${arr[@]}"
  PUB_TAG="${tags:1}"
  TAGS=',"tags": [ '${PUB_TAG}' ]'
fi

# Set default upgrade profile
if [ -z "$PUB_UPGRADE" ]; then
  PUB_UPGRADE=1
fi

echo "Verifying upgrade profile..."
UPGRADE_PROFILE_URL="https://${TENANT_URL}/api/v2/infrastructure/publisherupgradeprofiles/${PUB_UPGRADE}"
echo "API Call: curl -X GET ${UPGRADE_PROFILE_URL}"
run_sensitive_capture UPGRADE_PROFILE curl -s -X 'GET' "${UPGRADE_PROFILE_URL}" -H 'accept: application/json' -H "Netskope-Api-Token: ${API_TOKEN}"
echo "Upgrade Profile Response: ${UPGRADE_PROFILE}"

STATUS=$(json_get '.status // empty' "${UPGRADE_PROFILE}")
if [ "$STATUS" != "success" ] ; then
  echo "Using default Upgrade Profile ID!"
  PUB_UPGRADE=1
fi

echo "Creating Publisher object..."
CREATE_URL="https://${TENANT_URL}/api/v2/infrastructure/publishers?silent=0"
CREATE_PAYLOAD='{"name": "'"${PUB_NAME}"'","lbrokerconnect": false'"${TAGS}"',"publisher_upgrade_profiles_id": '${PUB_UPGRADE}'}'
echo "API Call: curl -X POST ${CREATE_URL}"
echo "Payload: ${CREATE_PAYLOAD}"
trace "Publisher create payload length: ${#CREATE_PAYLOAD}"
trace "Publisher create response will be written to ${CREATE_RESPONSE_LOG}"

run_sensitive_capture PUB_CREATE curl -s -X 'POST' "${CREATE_URL}" \
  -H 'accept: application/json' \
  -H "Netskope-Api-Token: ${API_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "${CREATE_PAYLOAD}"
printf '%s\n' "${PUB_CREATE}" > "${CREATE_RESPONSE_LOG}"
echo "Create Publisher Response: ${PUB_CREATE}"
trace "Publisher create response saved to ${CREATE_RESPONSE_LOG}"

STATUS=$(json_get '.status // empty' "${PUB_CREATE}")
if [ "$STATUS" != "success" ] ; then
  echo "Failed to create Publisher object!"
  exit 1
fi

echo "Publisher ${PUB_NAME} created successfully"

# Get Publisher Token
PUB_ID=$(json_get '.data.id // empty' "${PUB_CREATE}")
if [ -z "${PUB_ID}" ] || [ "${PUB_ID}" = "null" ]; then
  echo "Publisher create response did not include an ID. Response: ${PUB_CREATE}"
  exit 1
fi
trace "Created publisher ID: ${PUB_ID}"
TOKEN_URL="https://${TENANT_URL}/api/v2/infrastructure/publishers/${PUB_ID}/registration_token"
echo "API Call: curl -X POST ${TOKEN_URL}"
trace "Publisher token response will be written to ${TOKEN_RESPONSE_LOG}"

echo "Registering Publisher..."
if register_publisher; then
  echo "Publisher ${PUB_NAME} registered successfully"
  if [ "${ENABLE_ANYAPP}" = "true" ]; then
    if ! enable_anyapp; then
      echo "Publisher registered but AnyApp enable failed"
      exit 1
    fi
  fi
  if [ "${UPGRADE_PUBLISHER_AFTER_REGISTER}" = "true" ]; then
    if ! run_upgrade_flow; then
      echo "Publisher registered but upgrade flow failed"
      exit 1
    fi
  fi
  # Create flag file only if all post-registration steps succeeded
  touch "$FLAG_FILE"
  if [ "${CLEANUP_SENSITIVE_LOGS}" = "true" ]; then
    cleanup_sensitive_artifacts
  fi
else
  echo "Failed to register publisher"
  exit 1
fi
