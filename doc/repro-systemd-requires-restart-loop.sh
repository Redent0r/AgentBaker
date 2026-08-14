#!/usr/bin/env bash

set -euo pipefail

PREFIX="kata-requires-restart-repro"
WORKER_UNIT="${PREFIX}-worker.service"
STAMP_UNIT="${PREFIX}-stamp.service"
PATH_UNIT="${PREFIX}-stamp.path"
MODE="${1:---user}"

case "$MODE" in
	--user)
		RUNTIME_DIR="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required}"
		UNIT_DIR="$RUNTIME_DIR/systemd/user"
		SYSTEMCTL=(systemctl --user)
		JOURNALCTL=(journalctl --user)
		STAMP_SYSTEMCTL="systemctl --user"
		;;
	--system)
		if [ "$(id -u)" -ne 0 ]; then
			echo "The --system mode must run as root." >&2
			exit 1
		fi
		RUNTIME_DIR="/run"
		UNIT_DIR="$RUNTIME_DIR/systemd/system"
		SYSTEMCTL=(systemctl)
		JOURNALCTL=(journalctl)
		STAMP_SYSTEMCTL="systemctl"
		;;
	*)
		echo "Usage: $0 [--user|--system]" >&2
		exit 2
		;;
esac

TRIGGER_FILE="${RUNTIME_DIR}/${PREFIX}.trigger"
MARKER_FILE="${RUNTIME_DIR}/${PREFIX}.stamped"
STAMP_SCRIPT="${RUNTIME_DIR}/${PREFIX}-stamp.sh"

cleanup() {
	"${SYSTEMCTL[@]}" stop "$PATH_UNIT" "$STAMP_UNIT" "$WORKER_UNIT" >/dev/null 2>&1 || true
	"${SYSTEMCTL[@]}" reset-failed "$PATH_UNIT" "$STAMP_UNIT" "$WORKER_UNIT" >/dev/null 2>&1 || true
	rm -f \
		"$UNIT_DIR/$PATH_UNIT" \
		"$UNIT_DIR/$STAMP_UNIT" \
		"$UNIT_DIR/$WORKER_UNIT" \
		"$TRIGGER_FILE" \
		"$MARKER_FILE" \
		"$STAMP_SCRIPT"
	"${SYSTEMCTL[@]}" daemon-reload
}

if ! command -v systemctl >/dev/null 2>&1; then
	echo "systemctl is required." >&2
	exit 1
fi

trap cleanup EXIT
cleanup
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/$WORKER_UNIT" <<EOF
[Unit]
Description=Dummy worker for the systemd Requires/restart reproduction

[Service]
Type=simple
ExecStart=/usr/bin/sleep infinity
Restart=always
RestartSec=100ms
EOF

cat > "$STAMP_SCRIPT" <<EOF
#!/bin/sh
set -eu

echo "stamp attempt: restarting required worker"
$STAMP_SYSTEMCTL restart $WORKER_UNIT
touch $MARKER_FILE
echo "stamp completed"
EOF
chmod 0755 "$STAMP_SCRIPT"

cat > "$UNIT_DIR/$STAMP_UNIT" <<EOF
[Unit]
Description=Oneshot that restarts its own required worker
After=$WORKER_UNIT
Requires=$WORKER_UNIT

[Service]
Type=oneshot
ExecStart=$STAMP_SCRIPT
RemainAfterExit=true
EOF

cat > "$UNIT_DIR/$PATH_UNIT" <<EOF
[Unit]
Description=Repeatedly trigger the broken stamp relationship

[Path]
PathExists=$TRIGGER_FILE
Unit=$STAMP_UNIT
TriggerLimitIntervalSec=10s
TriggerLimitBurst=5
EOF

"${SYSTEMCTL[@]}" daemon-reload
"${SYSTEMCTL[@]}" start "$PATH_UNIT"
touch "$TRIGGER_FILE"

for _attempt in $(seq 1 100); do
	if [ "$("${SYSTEMCTL[@]}" show "$PATH_UNIT" -p Result --value)" = "trigger-limit-hit" ]; then
		break
	fi
	sleep 0.05
done

path_result=$("${SYSTEMCTL[@]}" show "$PATH_UNIT" -p Result --value)
stamp_result=$("${SYSTEMCTL[@]}" show "$STAMP_UNIT" -p Result --value)

"${JOURNALCTL[@]}" \
	-u "$PATH_UNIT" \
	-u "$STAMP_UNIT" \
	-u "$WORKER_UNIT" \
	--since "1 minute ago" \
	--no-pager

printf '\npath result: %s\nstamp result: %s\n' "$path_result" "$stamp_result"

if [ -e "$MARKER_FILE" ]; then
	echo "Unexpected result: the post-restart marker exists." >&2
	exit 1
fi

if [ "$path_result" != "trigger-limit-hit" ]; then
	echo "The path unit did not reach its trigger limit." >&2
	exit 1
fi

echo "Reproduced: restarting a required worker terminated the stamp before marker creation."