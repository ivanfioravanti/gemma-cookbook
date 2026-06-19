#!/bin/bash
# ─────────────────────────────────────────────────────────────
# run.sh — Launch the multi-agent demo with terminal windows.
#
# Opens macOS Terminal/iTerm2 windows in a grid layout:
#   - Top row: live throughput dashboard
#   - Grid below: orchestrator + N specialist agents
#
# Usage:
#   bash run.sh --scenario <name> --topic <text> [--port <port>] [--tasks <n>]
#
# Examples:
#   bash run.sh --scenario translate --topic "Hello world"
#   bash run.sh --scenario svg_art --topic "Technology and AI" --tasks 15
# ─────────────────────────────────────────────────────────────

PORT="8080"
SCENARIO="translate"
TOPIC="Gemma is Google DeepMind most capable open AI model"
N_AGENTS=""
API_BASE=""
API_URL=""
SERVER_URL=""
SERVER_NAME="llama.cpp"
MODEL="${OPENAI_MODEL:-default}"
API_KEY=""
MAX_TOKENS="2048"
RUN_ID="$(date +%s)-$$"
WINDOW_STATE="${TMPDIR:-/tmp}/concurrent-demo-${RUN_ID}.windows"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)     PORT="$2";     shift 2 ;;
        --scenario) SCENARIO="$2"; shift 2 ;;
        --topic)    TOPIC="$2";    shift 2 ;;
        --tasks)   N_AGENTS="$2"; shift 2 ;;
        --api-base) API_BASE="$2"; shift 2 ;;
        --api-url)  API_URL="$2";  shift 2 ;;
        --server-url) SERVER_URL="$2"; shift 2 ;;
        --server-name) SERVER_NAME="$2"; shift 2 ;;
        --model)    MODEL="$2";    shift 2 ;;
        --api-key)  API_KEY="$2";  shift 2 ;;
        --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
        --omlx) SERVER_NAME="oMLX"; shift ;;
        --help)
            echo "Usage: bash run.sh --scenario <name> --topic <text> [--port <port>] [--tasks <n>]"
            echo ""
            echo "Options:"
            echo "  --scenario    Scenario name (translate, svg_art)       [default: translate]"
            echo "  --topic       Topic or text to work on                  [required]"
            echo "  --port        llama-server port                         [default: 8080]"
            echo "  --tasks       Number of LLMs to use                     [default: scenario default]"
            echo "  --api-base    OpenAI-compatible base URL                [default: http://127.0.0.1:<port>/v1]"
            echo "  --api-url     Full chat completions URL                 [overrides --api-base]"
            echo "  --server-url  Metrics base URL for dashboard            [default: API base without /v1]"
            echo "  --server-name Display name shown in dashboard           [default: llama.cpp]"
            echo "  --model       Model name passed to chat completions     [default: \$OPENAI_MODEL or default]"
            echo "  --api-key     API key passed to chat completions        [default: \$OPENAI_API_KEY or sk-no-key]"
            echo "  --max-tokens  Max generated tokens per specialist task  [default: 2048]"
            echo "  --omlx        Shorthand for --server-name oMLX"
            exit 0 ;;
        *) echo "❌ Unknown argument: $1. Use --help for usage."; exit 1 ;;
    esac
done

# Resolve paths — SCRIPT_DIR is where this script lives (project root)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEMO_DIR="$SCRIPT_DIR/demo"
PYTHON="$SCRIPT_DIR/.venv/bin/python"

if [ ! -f "$PYTHON" ]; then
    echo "❌ .venv not found at $SCRIPT_DIR/.venv — run 'uv sync' first"
    exit 1
fi

: > "$WINDOW_STATE"

if ! [[ "$MAX_TOKENS" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ --max-tokens must be a positive integer"
    exit 1
fi

if [ -z "$API_URL" ]; then
    if [ -z "$API_BASE" ]; then
        API_BASE="http://127.0.0.1:${PORT}/v1"
    fi
    API_BASE="${API_BASE%/}"
    if [[ "$API_BASE" == */chat/completions ]]; then
        API_URL="$API_BASE"
        API_BASE="${API_BASE%/chat/completions}"
    else
        API_URL="${API_BASE}/chat/completions"
    fi
else
    API_URL="${API_URL%/}"
    if [ -z "$API_BASE" ]; then
        if [[ "$API_URL" == */chat/completions ]]; then
            API_BASE="${API_URL%/chat/completions}"
        else
            API_BASE="$API_URL"
        fi
    fi
fi

if [ -z "$SERVER_URL" ]; then
    SERVER_URL="${API_BASE%/}"
    SERVER_URL="${SERVER_URL%/v1}"
fi

sh_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

applescript_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\r'/}
    value=${value//$'\n'/ }
    printf "%s" "$value"
}

is_iterm2_session() {
    [[ "${TERM_PROGRAM:-}" == "iTerm.app" || "${LC_TERMINAL:-}" == "iTerm2" || "${__CFBundleIdentifier:-}" == "com.googlecode.iterm2" ]]
}

detect_screen_bounds() {
    local detected
    detected=$(osascript -l JavaScript <<'JXA' 2>/dev/null
ObjC.import('AppKit');
ObjC.import('CoreGraphics');

function number(value) {
    return Number(value);
}

function bestScreen(screens) {
    if (!screens.length) {
        return null;
    }
    screens.sort(function(a, b) {
        if (b.area !== a.area) {
            return b.area - a.area;
        }
        if (a.main !== b.main) {
            return a.main ? -1 : 1;
        }
        if (a.top !== b.top) {
            return a.top - b.top;
        }
        return a.left - b.left;
    });
    return screens[0];
}

var nsScreens = $.NSScreen.screens;
var count = Number(nsScreens.count);
if (!count) {
    throw new Error('No screens found');
}

var mainScreen = $.NSScreen.mainScreen;
var mainFrame = mainScreen.frame;
var mainHeight = number(mainFrame.size.height);
var screens = [];
var externalScreens = [];

for (var i = 0; i < count; i++) {
    var screen = nsScreens.objectAtIndex(i);
    var visible = screen.visibleFrame;
    var left = Math.round(number(visible.origin.x));
    var top = Math.round(mainHeight - (number(visible.origin.y) + number(visible.size.height)));
    var right = Math.round(number(visible.origin.x) + number(visible.size.width));
    var bottom = Math.round(mainHeight - number(visible.origin.y));
    var width = right - left;
    var height = bottom - top;

    if (width <= 0 || height <= 0) {
        continue;
    }

    var displayID = 0;
    try {
        displayID = Number(ObjC.unwrap(screen.deviceDescription.objectForKey('NSScreenNumber')));
    } catch (error) {
        displayID = 0;
    }

    var localizedName = '';
    try {
        localizedName = String(ObjC.unwrap(screen.localizedName));
    } catch (error) {
        localizedName = '';
    }

    var builtIn = false;
    var detectedBuiltIn = false;
    try {
        if (displayID) {
            builtIn = Boolean($.CGDisplayIsBuiltin(displayID));
            detectedBuiltIn = true;
        }
    } catch (error) {
        detectedBuiltIn = false;
    }
    if (!detectedBuiltIn) {
        builtIn = /built-in|color lcd|liquid retina|retina display/i.test(localizedName);
    }

    var entry = {
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        area: width * height,
        external: !builtIn,
        main: Boolean(screen.isEqual(mainScreen))
    };
    screens.push(entry);
    if (entry.external) {
        externalScreens.push(entry);
    }
}

var selected = bestScreen(externalScreens);
if (!selected) {
    for (var j = 0; j < screens.length; j++) {
        if (screens[j].main) {
            selected = screens[j];
            break;
        }
    }
}
selected = selected || bestScreen(screens);
if (!selected) {
    throw new Error('No usable screen found');
}

[selected.left, selected.top, selected.right, selected.bottom].join(' ');
JXA
)

    if [[ "$detected" =~ ^-?[0-9]+[[:space:]]+-?[0-9]+[[:space:]]+-?[0-9]+[[:space:]]+-?[0-9]+$ ]]; then
        echo "$detected"
        return 0
    fi

    local bounds x1 y1 x2 y2 fallback_top fallback_bottom
    bounds=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null || true)
    bounds=${bounds//,/ }
    read -r x1 y1 x2 y2 <<< "$bounds"

    if [[ "$x1" =~ ^-?[0-9]+$ && "$y1" =~ ^-?[0-9]+$ && "$x2" =~ ^-?[0-9]+$ && "$y2" =~ ^-?[0-9]+$ ]]; then
        fallback_top=$((y1 + 25))
        fallback_bottom=$((y2 - 120))
        if (( fallback_bottom <= fallback_top )); then
            fallback_top=$y1
            fallback_bottom=$y2
        fi
        echo "$x1 $fallback_top $x2 $fallback_bottom"
        return 0
    fi

    echo "0 25 1440 900"
}

# ─── Load agents from scenario ──────────────────────────────

AGENT_DATA=$("$PYTHON" - "$SCENARIO" "$N_AGENTS" "$DEMO_DIR" <<'PY' 2>/dev/null
import sys
scenario = sys.argv[1]
n_agents = sys.argv[2]
demo_dir = sys.argv[3]
sys.path.insert(0, demo_dir)
from scenarios import get_scenario
kwargs = {}
if n_agents:
    kwargs["n_agents"] = int(n_agents)
s = get_scenario(scenario, **kwargs)
for a in s['agents']:
    print(f"{a['name']}|{a['emoji']}|{a['color']}")
PY
)

if [ -z "$AGENT_DATA" ]; then
    echo "❌ Failed to load scenario '$SCENARIO'"
    exit 1
fi

NAMES=()
EMOJIS=()
COLORS=()
while IFS='|' read -r name emoji color; do
    NAMES+=("$name")
    EMOJIS+=("$emoji")
    COLORS+=("$color")
done <<< "$AGENT_DATA"

NUM_AGENTS=${#NAMES[@]}

# ─── Calculate window layout ────────────────────────────────

read -r SCREEN_X1 SCREEN_Y1 SCREEN_X2 SCREEN_Y2 <<< "$(detect_screen_bounds)"

SCREEN_W=$((SCREEN_X2 - SCREEN_X1))
SCREEN_H=$((SCREEN_Y2 - SCREEN_Y1))

if (( SCREEN_W <= 0 || SCREEN_H <= 0 )); then
    echo "❌ Failed to calculate a usable screen area"
    exit 1
fi

# Dashboard: top 25%
DASH_HEIGHT=$((SCREEN_H * 25 / 100))
DASH_Y2=$((SCREEN_Y1 + DASH_HEIGHT))

# Grid: orchestrator + agents
TOTAL_CELLS=$((NUM_AGENTS + 1))

read COLS GRID_ROWS <<< $("$PYTHON" -c "
import math
n = $TOTAL_CELLS
cols = math.ceil(math.sqrt(n))
rows = math.ceil(n / cols)
print(cols, rows)
")

GRID_Y1=$DASH_Y2
GRID_HEIGHT=$((SCREEN_Y2 - GRID_Y1))
ROW_H=$((GRID_HEIGHT / GRID_ROWS))

# ─── Build AppleScript to open windows ──────────────────────

TERMINAL_APP="Terminal"
if is_iterm2_session; then
    TERMINAL_APP="iTerm2"
fi

if [ "$TERMINAL_APP" = "iTerm2" ]; then
    APPLESCRIPT=$'tell application "iTerm2"\n    activate\n'
else
    APPLESCRIPT=$'tell application "Terminal"\n    activate\n'
fi

queue_terminal_window() {
    local x1="$1" y1="$2" x2="$3" y2="$4" cmd="$5" title="$6" record_window="${7:-0}"
    local escaped_cmd escaped_title escaped_state snippet record_snippet
    escaped_cmd=$(applescript_escape "$cmd")
    escaped_title=$(applescript_escape "$title")
    escaped_state=$(applescript_escape "$WINDOW_STATE")
    record_snippet=""
    if [ "$record_window" = "1" ]; then
        printf -v record_snippet '    try\n        set stateLine to "Terminal" & (character id 9) & (id of newWindow as text) & (character id 9) & "%s"\n        do shell script "echo " & quoted form of stateLine & " >> " & quoted form of "%s"\n    end try\n' "$escaped_title" "$escaped_state"
    fi
    printf -v snippet '    set newTab to do script "%s"\n    delay 0.05\n    set newWindow to window of newTab\n    set custom title of newTab to "%s"\n    set bounds of newWindow to {%s, %s, %s, %s}\n%s' "$escaped_cmd" "$escaped_title" "$x1" "$y1" "$x2" "$y2" "$record_snippet"
    APPLESCRIPT+="$snippet"
}

queue_iterm2_window() {
    local x1="$1" y1="$2" x2="$3" y2="$4" cmd="$5" title="$6" record_window="${7:-0}"
    local escaped_cmd escaped_title escaped_state snippet record_snippet
    escaped_cmd=$(applescript_escape "$cmd")
    escaped_title=$(applescript_escape "$title")
    escaped_state=$(applescript_escape "$WINDOW_STATE")
    record_snippet=""
    if [ "$record_window" = "1" ]; then
        printf -v record_snippet '    try\n        set stateLine to "iTerm2" & (character id 9) & (id of newWindow as text) & (character id 9) & "%s"\n        do shell script "echo " & quoted form of stateLine & " >> " & quoted form of "%s"\n    end try\n' "$escaped_title" "$escaped_state"
    fi
    printf -v snippet '    create window with default profile\n    delay 0.05\n    set newWindow to current window\n    set bounds of newWindow to {%s, %s, %s, %s}\n%s    tell current session of newWindow\n        set name to "%s"\n        write text "%s"\n    end tell\n' "$x1" "$y1" "$x2" "$y2" "$record_snippet" "$escaped_title" "$escaped_cmd"
    APPLESCRIPT+="$snippet"
}

queue_window() {
    if [ "$TERMINAL_APP" = "iTerm2" ]; then
        queue_iterm2_window "$@"
    else
        queue_terminal_window "$@"
    fi
}

# Dashboard → top row
dash_cmd="cd $(sh_quote "$DEMO_DIR") && $(sh_quote "$PYTHON") dashboard.py --server-url $(sh_quote "$SERVER_URL") --server-name $(sh_quote "$SERVER_NAME") --terminal-app $(sh_quote "$TERMINAL_APP") --run-id $(sh_quote "$RUN_ID") --window-state $(sh_quote "$WINDOW_STATE") --scenario $(sh_quote "$SCENARIO") --topic $(sh_quote "$TOPIC")"
if [ -n "$N_AGENTS" ]; then
    dash_cmd+=" --tasks $(sh_quote "$N_AGENTS")"
fi
queue_window "$SCREEN_X1" "$SCREEN_Y1" "$SCREEN_X2" "$DASH_Y2" "$dash_cmd" "⚡ Dashboard [$RUN_ID]" "0"

# Orchestrator → first grid cell
orch_cmd="cd $(sh_quote "$DEMO_DIR") && $(sh_quote "$PYTHON") orchestrator.py --scenario $(sh_quote "$SCENARIO") --api-url $(sh_quote "$API_URL") --model $(sh_quote "$MODEL") --topic $(sh_quote "$TOPIC") --server-name $(sh_quote "$SERVER_NAME")"
if [ -n "$N_AGENTS" ]; then
    orch_cmd+=" --tasks $(sh_quote "$N_AGENTS")"
fi
if [ -n "$API_KEY" ]; then
    orch_cmd+=" --api-key $(sh_quote "$API_KEY")"
fi

# Place orchestrator + agents in grid
for (( i=0; i<TOTAL_CELLS; i++ )); do
    row=$((i / COLS))
    col=$((i % COLS))

    # Last row may have fewer cells — stretch them wider
    if (( row < GRID_ROWS - 1 )); then
        row_count=$COLS
    else
        remainder=$((TOTAL_CELLS % COLS))
        row_count=${remainder:-$COLS}
        if (( row_count == 0 )); then row_count=$COLS; fi
    fi

    win_w=$((SCREEN_W / row_count))
    x1=$((SCREEN_X1 + col * win_w))
    if (( col == row_count - 1 )); then
        x2=$SCREEN_X2
    else
        x2=$((SCREEN_X1 + (col + 1) * win_w))
    fi
    y1=$((GRID_Y1 + row * ROW_H))
    if (( row == GRID_ROWS - 1 )); then
        y2=$SCREEN_Y2
    else
        y2=$((GRID_Y1 + (row + 1) * ROW_H))
    fi

    if (( i == 0 )); then
        queue_window "$x1" "$y1" "$x2" "$y2" "$orch_cmd" "🧠 Orchestrator [$RUN_ID]" "1"
    else
        ai=$((i - 1))
        spec_cmd="cd $(sh_quote "$DEMO_DIR") && $(sh_quote "$PYTHON") specialist.py --name $(sh_quote "${NAMES[$ai]}") --emoji $(sh_quote "${EMOJIS[$ai]}") --color $(sh_quote "${COLORS[$ai]}") --api-url $(sh_quote "$API_URL") --model $(sh_quote "$MODEL") --max-tokens $(sh_quote "$MAX_TOKENS")"
        if [ -n "$API_KEY" ]; then
            spec_cmd+=" --api-key $(sh_quote "$API_KEY")"
        fi
        queue_window "$x1" "$y1" "$x2" "$y2" "$spec_cmd" "${NAMES[$ai]} [$RUN_ID]" "1"
    fi
done

# ─── Launch ────────────────────────────────────────────────

APPLESCRIPT+="end tell"
if ! printf "%s\n" "$APPLESCRIPT" | osascript >/dev/null; then
    echo "❌ Failed to launch windows with $TERMINAL_APP"
    exit 1
fi
echo "🚀 Launched with $TERMINAL_APP: $SCENARIO (${NUM_AGENTS} agents, ${COLS}×${GRID_ROWS} grid + dashboard)"
