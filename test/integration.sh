#!/bin/bash
# Integration test for drouter against a real Docker daemon.
#
# drouter runs inside a privileged container sharing the host PID namespace,
# so this only needs access to the Docker socket, not root on the host.
# Test containers use their own label keys (drouter-test.routes.*), so a
# drouter service already running on this host ignores them, and the drouter
# under test ignores any real containers.
#
# Usage: test/integration.sh
# Environment:
#   DOCKER_SOCK   Docker socket to mount (default: /var/run/docker.sock)
#   TEST_SUBNET4  IPv4 subnet for the test network (default: 172.31.250.0/24)
#   TEST_SUBNET6  IPv6 subnet for the test network (default: fd00:d0:7e57::/64)
#   KEEP          Set to 1 to leave containers running after the test

set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"
TEST_SUBNET4="${TEST_SUBNET4:-172.31.250.0/24}"
TEST_SUBNET6="${TEST_SUBNET6:-fd00:d0:7e57::/64}"

PREFIX="drouter-test"
NETWORK="$PREFIX-net"
RUNNER="$PREFIX-runner"
RUNNER_IMAGE="$PREFIX-runner:latest"
TARGET_IMAGE="alpine:3.22"

LABEL_V4="$PREFIX.routes.ipv4"
LABEL_V6="$PREFIX.routes.ipv6"
LABEL_DELAY="$PREFIX.routes.delay"

# Gateways inside the test subnets (.1 is the Docker bridge gateway)
GW4="${TEST_SUBNET4%.*/*}.1"
# .10 also catches substring matches against the .1 gateway
GW4_ALT="${TEST_SUBNET4%.*/*}.10"
GW6="${TEST_SUBNET6%::/*}::1"

PASSED=0
FAILED=0

pass() { echo "  PASS: $*"; ((PASSED++)); }
fail() { echo "  FAIL: $*"; ((FAILED++)); }

# Run a check and record the result
check() {
    local desc=$1
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# Retry a command until it succeeds or the timeout (seconds) expires
wait_for() {
    local timeout=$1
    shift
    local end=$((SECONDS + timeout))
    until "$@"; do
        [ "$SECONDS" -ge "$end" ] && return 1
        sleep 0.5
    done
}

# Check that a container has an exact route: has_route <container> <4|6> <dest> <gateway>
has_route() {
    local container=$1 ver=$2 dest=$3 gw=$4
    docker exec "$container" ip "-$ver" route 2>/dev/null |
        awk -v d="$dest" -v g="$gw" '$1 == d && $2 == "via" && $3 == g { found = 1 } END { exit !found }'
}

no_route() { ! has_route "$@"; }

runner_log() { docker logs "$RUNNER" 2>&1; }

log_contains() { runner_log | grep -qF -- "$1"; }

log_count() { runner_log | grep -cF -- "$1"; }

process_count() { log_count "Processing routes for container $1 "; }

processed_more_than() { [ "$(process_count "$1")" -gt "$2" ]; }

not_processed() { [ "$(process_count "$1")" -eq 0 ]; }

no_errors() { ! log_contains "[ERROR]"; }

# Start a labeled test container: start_target <name> [docker run args...]
start_target() {
    local name=$1
    shift
    docker run -d --init --name "$name" --label "$PREFIX=1" \
        --network "$NETWORK" "$@" "$TARGET_IMAGE" sleep 3600 >/dev/null
}

start_runner() {
    docker run -d --name "$RUNNER" --label "$PREFIX=1" \
        --privileged --pid=host \
        -v "$DOCKER_SOCK:/var/run/docker.sock" \
        -v "$REPO_DIR/drouter.sh:/usr/local/bin/drouter:ro" \
        -e LOG_LEVEL=DEBUG \
        -e RETRY_ATTEMPTS=2 \
        -e RETRY_DELAY=0 \
        -e DROUTER_LABEL_V4="$LABEL_V4" \
        -e DROUTER_LABEL_V6="$LABEL_V6" \
        -e DROUTER_LABEL_DELAY="$LABEL_DELAY" \
        "$RUNNER_IMAGE" bash /usr/local/bin/drouter >/dev/null &&
    wait_for 30 log_contains "Monitoring Docker events"
}

cleanup() {
    if [ "${KEEP:-0}" == "1" ]; then
        echo "KEEP=1: leaving test containers and network in place"
        return
    fi
    local ids
    ids=$(docker ps -aq --filter "label=$PREFIX=1")
    # shellcheck disable=SC2086  # word splitting intended for container IDs
    [ -n "$ids" ] && docker rm -f $ids >/dev/null
    docker network rm "$NETWORK" >/dev/null 2>&1
}

setup() {
    echo "Setup"
    cleanup
    trap cleanup EXIT

    docker build -q -t "$RUNNER_IMAGE" - >/dev/null <<'EOF' || { echo "Failed to build runner image"; exit 1; }
FROM alpine:3.22
RUN apk add --no-cache bash jq iproute2 util-linux-misc docker-cli
EOF
    docker pull -q "$TARGET_IMAGE" >/dev/null || { echo "Failed to pull $TARGET_IMAGE"; exit 1; }
    docker network create --ipv6 \
        --subnet "$TEST_SUBNET4" --gateway "$GW4" \
        --subnet "$TEST_SUBNET6" --gateway "$GW6" \
        "$NETWORK" >/dev/null || { echo "Failed to create network $NETWORK"; exit 1; }
}

test_startup_sweep() {
    echo "Startup sweep: container running before drouter starts (newline-separated routes)"
    start_target "$PREFIX-sweep" \
        --label "$LABEL_V4=10.99.1.0/24 via $GW4
10.99.2.0/24 via $GW4
" \
        --label "$LABEL_V6=2001:db8:99::/48 via $GW6"

    if ! start_runner; then
        fail "drouter did not start"
        runner_log
        exit 1
    fi

    check "first IPv4 route added" wait_for 10 has_route "$PREFIX-sweep" 4 10.99.1.0/24 "$GW4"
    check "second IPv4 route added" wait_for 10 has_route "$PREFIX-sweep" 4 10.99.2.0/24 "$GW4"
    check "IPv6 route added" wait_for 10 has_route "$PREFIX-sweep" 6 2001:db8:99::/48 "$GW6"
}

test_start_event() {
    echo "Start event: container started after drouter (semicolon-separated routes, extra spaces)"
    start_target "$PREFIX-event" \
        --label "$LABEL_V4=10.99.1.0/24 via $GW4 ;  10.99.2.0/24   via $GW4;"

    check "first IPv4 route added" wait_for 10 has_route "$PREFIX-event" 4 10.99.1.0/24 "$GW4"
    check "second IPv4 route added" wait_for 10 has_route "$PREFIX-event" 4 10.99.2.0/24 "$GW4"
}

test_both_labels_once() {
    echo "Both labels: container processed once per start"
    start_target "$PREFIX-both" \
        --label "$LABEL_V4=10.99.1.0/24 via $GW4" \
        --label "$LABEL_V6=2001:db8:99::/48 via $GW6"

    check "routes added" wait_for 10 has_route "$PREFIX-both" 6 2001:db8:99::/48 "$GW6"
    sleep 2
    check "processed exactly once" [ "$(process_count "$PREFIX-both")" -eq 1 ]
}

test_delay_does_not_block() {
    echo "Delay: a delayed container does not block others"
    start_target "$PREFIX-delay" \
        --label "$LABEL_V4=10.99.1.0/24 via $GW4" \
        --label "$LABEL_DELAY=5"
    start_target "$PREFIX-fast" \
        --label "$LABEL_V4=10.99.1.0/24 via $GW4"

    check "undelayed container gets routes within 3s" wait_for 3 has_route "$PREFIX-fast" 4 10.99.1.0/24 "$GW4"
    check "delayed container has no routes yet" no_route "$PREFIX-delay" 4 10.99.1.0/24 "$GW4"
    check "delayed container gets routes after delay" wait_for 10 has_route "$PREFIX-delay" 4 10.99.1.0/24 "$GW4"
}

test_restart() {
    echo "Restart: routes re-added in the container's new network namespace"
    local before
    before=$(process_count "$PREFIX-event")
    docker restart -t 0 "$PREFIX-event" >/dev/null

    check "container processed again" wait_for 10 processed_more_than "$PREFIX-event" "$before"
    check "routes present after restart" wait_for 10 has_route "$PREFIX-event" 4 10.99.1.0/24 "$GW4"
}

test_invalid_route() {
    echo "Invalid route: logged as an error, valid routes in the same label still added"
    start_target "$PREFIX-invalid" \
        --label "$LABEL_V4=not-a-route;10.99.3.0/24 via $GW4"

    check "valid route added" wait_for 10 has_route "$PREFIX-invalid" 4 10.99.3.0/24 "$GW4"
    check "invalid route logged as error" \
        wait_for 10 log_contains "Failed to set route 'not-a-route' on container $PREFIX-invalid"
}

test_skipped_network_modes() {
    echo "Network modes: host and none are skipped"
    docker run -d --init --name "$PREFIX-host" --label "$PREFIX=1" --network host \
        --label "$LABEL_V4=10.99.4.0/24 via $GW4" "$TARGET_IMAGE" sleep 3600 >/dev/null
    docker run -d --init --name "$PREFIX-none" --label "$PREFIX=1" --network none \
        --label "$LABEL_V4=10.99.4.0/24 via $GW4" "$TARGET_IMAGE" sleep 3600 >/dev/null

    check "host network skipped" \
        wait_for 10 log_contains "Container $PREFIX-host uses host networking, skipping routes"
    check "no network skipped" \
        wait_for 10 log_contains "Container $PREFIX-none has no networking, skipping routes"
}

test_replace_on_restart() {
    echo "drouter restart: changed gateway is corrected, existing routes cause no errors"
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$PREFIX-sweep")
    docker exec "$RUNNER" nsenter -t "$pid" -n ip route replace 10.99.1.0/24 via "$GW4_ALT"
    check "gateway changed out of band" has_route "$PREFIX-sweep" 4 10.99.1.0/24 "$GW4_ALT"

    # The invalid route container would log an expected error during the sweep
    docker rm -f "$PREFIX-invalid" >/dev/null
    docker rm -f "$RUNNER" >/dev/null
    if ! start_runner; then
        fail "drouter did not restart"
        return
    fi

    check "original gateway restored" wait_for 10 has_route "$PREFIX-sweep" 4 10.99.1.0/24 "$GW4"
    # Wait for the rest of the sweep to finish before checking for errors
    sleep 2
    check "no errors on re-applying existing routes" no_errors
}

test_foreign_labels_ignored() {
    echo "Label isolation: containers without the configured labels are ignored"
    start_target "$PREFIX-foreign" \
        --label "drouter.routes.ipv4=10.99.5.0/24 via $GW4"
    sleep 2
    check "container not processed" not_processed "$PREFIX-foreign"
}

main() {
    command -v docker >/dev/null || { echo "docker not found"; exit 1; }
    docker info >/dev/null 2>&1 || { echo "Cannot reach Docker daemon"; exit 1; }

    setup
    test_startup_sweep
    test_start_event
    test_both_labels_once
    test_delay_does_not_block
    test_restart
    test_invalid_route
    test_skipped_network_modes
    test_foreign_labels_ignored
    test_replace_on_restart

    echo
    echo "Passed: $PASSED  Failed: $FAILED"
    if [ "$FAILED" -gt 0 ]; then
        echo
        echo "drouter log:"
        runner_log
        exit 1
    fi
}

main "$@"
