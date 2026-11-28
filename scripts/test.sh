#!/bin/bash
# ============================================================
#  沙箱场景测试：把 Sources/menulet.swift 的逻辑原样拿出来，
#  把 pmset/sudo/亮度/睡眠/通知/弹窗换成假的（tests/sim/fakes.swift），
#  再模拟合盖、定时到期、低电量暂停与自动恢复、sudo 失败、重启恢复、崩溃重开等 48 个场景。
#  不会改动电脑的任何设置，也不会碰正在运行的 App。
#
#  用法：./scripts/test.sh
# ============================================================
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 "$PROJECT_DIR/tests/sim/make_sim.py" "$PROJECT_DIR/Sources/menulet.swift" "$WORK/app_sim.swift" "$WORK" >/dev/null
swiftc -swift-version 5 -o "$WORK/nosleep-sim" "$WORK/app_sim.swift" \
    "$PROJECT_DIR/tests/sim/fakes.swift" "$PROJECT_DIR/tests/sim/main.swift" \
    -framework Cocoa -framework IOKit -framework ServiceManagement -framework UserNotifications
"$WORK/nosleep-sim" "$WORK"
