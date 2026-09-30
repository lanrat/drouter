#!/bin/bash
# drouter - Dynamic route injection for Docker containers
# https://github.com/lanrat/drouter

# Not using set -e because we handle errors explicitly
# Not using set -u because we use intentional empty defaults
set -o noclobber  # Prevent accidental file overwrites

# Configuration
LABEL_KEY_V4="${DROUTER_LABEL_V4:-drouter.routes.ipv4}"
LABEL_KEY_V6="${DROUTER_LABEL_V6:-drouter.routes.ipv6}"
LABEL_KEY_DELAY="${DROUTER_LABEL_DELAY:-drouter.routes.delay}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-1}"
DEFAULT_ROUTE_DELAY="${DEFAULT_ROUTE_DELAY:-0}"  # Default delay before adding routes

# Logging functions
log() {
    local level=$1
    shift
    echo "$(date -Iseconds) [$level] $*"
}

log_debug() { [[ "$LOG_LEVEL" == "DEBUG" ]] && log DEBUG "$@"; }
log_info() { log INFO "$@"; }
log_warn() { log WARNING "$@"; }
log_error() { log ERROR "$@"; }

# Add or update a single route with retries
# ip route replace is idempotent: it adds the route, or updates the existing
# route to the same destination in place (e.g. when the gateway changed)
add_single_route() {
    local pid=$1
    local container=$2
    local ip_ver=$3  # -6 for IPv6, empty for IPv4
    shift 3
    local route_args=("$@")
    local route="${route_args[*]}"

    local attempt=1
    local error
    while [ "$attempt" -le "$RETRY_ATTEMPTS" ]; do
        # shellcheck disable=SC2086  # ip_ver intentionally unquoted (empty for v4, -6 for v6)
        if error=$(nsenter -t "$pid" -n ip ${ip_ver} route replace "${route_args[@]}" 2>&1); then
            log_info "Set route '$route' on container $container"
            return 0
        fi
        log_warn "Attempt $attempt/$RETRY_ATTEMPTS failed for route '$route' on $container: $error"

        if [ "$attempt" -lt "$RETRY_ATTEMPTS" ]; then
            sleep "$RETRY_DELAY"
        fi
        ((attempt++))
    done

    log_error "Failed to set route '$route' on container $container after $RETRY_ATTEMPTS attempts"
    return 1
}

# Add all routes from a label value (routes separated by semicolons or newlines)
add_routes() {
    local pid=$1
    local container=$2
    local ip_ver=$3
    local routes=$4

    local route_list route route_args
    IFS=';' read -ra route_list <<< "${routes//$'\n'/;}"
    for route in "${route_list[@]}"; do
        # Split into ip arguments; this also trims whitespace and avoids glob expansion
        read -ra route_args <<< "$route"
        if [ "${#route_args[@]}" -gt 0 ]; then
            add_single_route "$pid" "$container" "$ip_ver" "${route_args[@]}"
        fi
    done
}

# Process routes for a container
process_container_routes() {
    local container=$1

    # Get container details
    local inspect_json
    if ! inspect_json=$(docker inspect "$container" 2>/dev/null); then
        log_error "Failed to inspect container $container"
        return 1
    fi

    # Check if container is running
    local state
    state=$(jq -r '.[0].State.Status' <<< "$inspect_json")
    if [ "$state" != "running" ]; then
        log_debug "Container $container is not running (state: $state), skipping"
        return 0
    fi

    # Get PID
    local pid
    pid=$(jq -r '.[0].State.Pid' <<< "$inspect_json")
    if [ "$pid" == "0" ] || [ "$pid" == "null" ]; then
        log_warn "Container $container has no valid PID, might be restarting"
        return 1
    fi

    # Check network mode
    local network_mode
    network_mode=$(jq -r '.[0].HostConfig.NetworkMode' <<< "$inspect_json")

    # Skip certain network modes
    case "$network_mode" in
        "host")
            log_debug "Container $container uses host networking, skipping routes"
            return 0
            ;;
        "none")
            log_debug "Container $container has no networking, skipping routes"
            return 0
            ;;
        container:*)
            log_debug "Container $container shares another container's network, skipping"
            return 0
            ;;
    esac

    # Get routes and configured delay for this container
    local routes_v4 routes_v6 route_delay
    routes_v4=$(jq -r --arg key "$LABEL_KEY_V4" '.[0].Config.Labels[$key] // ""' <<< "$inspect_json")
    routes_v6=$(jq -r --arg key "$LABEL_KEY_V6" '.[0].Config.Labels[$key] // ""' <<< "$inspect_json")
    route_delay=$(jq -r --arg key "$LABEL_KEY_DELAY" --arg def "$DEFAULT_ROUTE_DELAY" \
        '.[0].Config.Labels[$key] // $def' <<< "$inspect_json")

    if [ -z "$routes_v4" ] && [ -z "$routes_v6" ]; then
        log_debug "Container $container has no static routes defined"
        return 0
    fi

    # Validate delay is a number
    if ! [[ "$route_delay" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_warn "Invalid delay value '$route_delay' for container $container, using default"
        route_delay=$DEFAULT_ROUTE_DELAY
    fi

    # Apply delay if specified
    if [ "$route_delay" != "0" ]; then
        log_info "Waiting ${route_delay}s before adding routes to container $container"
        sleep "$route_delay"

        # Re-check if container is still running after delay
        state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
        if [ "$state" != "running" ]; then
            log_debug "Container $container is no longer running after delay, skipping"
            return 0
        fi

        # Re-get PID in case it changed
        pid=$(docker inspect -f '{{.State.Pid}}' "$container" 2>/dev/null)
        if [ -z "$pid" ] || [ "$pid" == "0" ]; then
            log_warn "Container $container has no valid PID after delay"
            return 1
        fi
    fi

    log_info "Processing routes for container $container (network: $network_mode, pid: $pid)"

    add_routes "$pid" "$container" "" "$routes_v4"
    add_routes "$pid" "$container" "-6" "$routes_v6"
}

# Process existing containers on startup
process_existing_containers() {
    log_info "Processing existing containers with static routes..."

    local containers
    # Look for containers with any of our labels
    containers=$(docker ps --filter "label=$LABEL_KEY_V4" --format '{{.Names}}' 2>/dev/null)
    containers+=$'\n'$(docker ps --filter "label=$LABEL_KEY_V6" --format '{{.Names}}' 2>/dev/null)

    # Remove duplicates and empty lines
    containers=$(sort -u <<< "$containers" | grep -v '^$' || true)

    local container count=0
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        # Process in the background so one container's delay or retries don't block others
        process_container_routes "$container" &
        ((count++))
    done <<< "$containers"

    log_info "Started processing $count existing container(s)"
}

# Main monitoring loop
main() {
    log_info "drouter starting (labels: $LABEL_KEY_V4, $LABEL_KEY_V6, $LABEL_KEY_DELAY, log level: $LOG_LEVEL)"

    # Record the time before the startup sweep so docker events replays any start
    # that happens between the sweep and the event subscription. Containers seen by
    # both are processed twice, which is harmless since ip route replace is idempotent.
    local since
    since=$(date +%s)

    # Process existing containers
    process_existing_containers

    # Monitor events
    log_info "Monitoring Docker events..."

    # Labels cannot be changed on running containers, so only start events matter.
    # docker events ANDs multiple label filters, so the OR between our labels is done
    # in jq instead. Container event attributes include all container labels.
    docker events \
        --since "$since" \
        --filter "type=container" \
        --filter "event=start" \
        --format '{{json .}}' |
    while read -r event; do
        [ -z "$event" ] && continue

        local container
        container=$(jq -r --arg v4 "$LABEL_KEY_V4" --arg v6 "$LABEL_KEY_V6" \
            'select((.Actor.Attributes // {}) | has($v4) or has($v6))
             | .Actor.Attributes.name // .Actor.ID[0:12]' <<< "$event")
        [ -z "$container" ] && continue

        log_debug "Received start event for container: $container"

        # Process in the background so one container's delay or retries don't block others
        process_container_routes "$container" &
    done
}

# Trap signals for clean shutdown
trap 'log_info "Shutting down drouter"; exit 0' SIGTERM SIGINT

# Run main loop
main
