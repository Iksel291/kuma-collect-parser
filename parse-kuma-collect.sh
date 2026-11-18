#!/usr/bin/env bash
# Разбор диагностического коллекта KUMA.
# В терминале это отдельные экраны: сводка, выбор компонента, выбор ID, что анализировать, логи.
# Экран очищается при каждом переходе. --logs печатает отчёт подряд, без меню.
#
# Как устроен разбор и куда добавлять секции: README.md
# Версию поднимайте при смене состава отчёта или правил группировки.
set -euo pipefail
case "${LC_ALL:-${LANG:-C}}" in
    *.UTF-8|*.utf8|*.UTF8) ;;
    *) export LC_ALL=C.UTF-8 ;;
esac

PARSER_VERSION="0.6"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AWK_PROG="$SCRIPT_DIR/kuma-log-errors.awk"
EXTRACT_PROG="$SCRIPT_DIR/kuma-log-extract.py"

SUFFIX_HOSTNAME="environment/hostname.txt"
SUFFIX_VERSION="kaspersky/KUMA/execvers.txt"
SUFFIX_SERVICES="kaspersky/KUMA/services.txt"
SUFFIX_HDD="environment/hdd.txt"
SUFFIX_IPA="environment/ipa.txt"
SUFFIX_IFCONFIG="environment/ifconfig.txt"
SUFFIX_CPU="environment/cpuinfo.txt"
SUFFIX_SYSCTL="environment/sysctl.txt"
SUFFIX_TOP="environment/top.txt"
SUFFIX_UPTIME="environment/uptime.txt"
SUFFIX_TIMEDATE="environment/timedatectl.txt"
SUFFIX_DATE="environment/date.txt"
SUFFIX_DATE_EN="environment/date_en.txt"
SUFFIX_MEMORY="environment/memory.txt"
SUFFIX_LOGS="kaspersky/KUMA/logs.tar"
SUFFIX_KESL="kaspersky/KESL/appinfo.txt"
SUFFIX_KESL_EX="kaspersky/KESL/exset.txt"
SUFFIX_KESL_EXP="kaspersky/KESL/expset.txt"

TOP=10
INCLUDE_WARN=0
KEEP=0
DEBUG_FILE=""
DEBUG_PID=""
COLOR_FLAG="auto"
OUT=""
LOGS_MODE="ask"
REPORT=0
REPORT_QUIET=0
LAUNCH_DIR=""
ARCHIVE=""

USE_COLOR=0
RST="" BOLD="" DIM=""
C_TITLE="" C_HOST="" C_VER="" C_DISK="" C_SVC="" C_LOG=""
C_OK="" C_BAD="" C_WARN="" C_ASK=""

work=""
LOGS_READY=0
LOGS_TAR=""
log_role=()
log_id=()
log_path=()
skipped_logs=()
UI_ALT=0
UI_QUIT=0
HAS_CFG=0
CFG_NAMES=()
CFG_FILES=()
SKIP_OUT=0
MENU_NOTE=""
UI_CAPTURE=0
UI_KEY_MODE="log"
MOUSE_ON=0
FIND_QUERY=""
FIND_NOTE=""
FIND_POS=0
FIND_EDIT=0
FIND_HITS=()
CURSOR_HIDDEN=0
AWK_TOP=""
LOG_VIEW="all"

usage() {
    cat <<'EOF'
Использование:
  parse-kuma-collect.sh [опции] <collect.tar.gz | каталог>

В терминале открывает сводку на одном экране. Логи не читает, пока в меню
не выбран компонент и конкретный ID. Экран очищается на каждом шаге.
Ключ --logs печатает отчёт подряд, без меню: так удобно сохранять файл.

Опции:
  --top N             для --logs: сколько групп печатать (по умолчанию 10).
                      В меню терминала список полный, его листают колёсиком.
  --logs all          разобрать логи всех служб без вопросов
  --logs none         не спрашивать и не разбирать логи
  --logs core,storage разобрать только эти роли, без вопросов
  --include-warn      добавить warn/warning в рейтинг ошибок
  --out FILE          дополнительно записать отчёт без цветов
  --report            записать первую страницу в txt в текущую папку
  --report=all        в тот же файл — всё, что скрипт разобрал, включая логи
  --color / --no-color
  --keep-work         не удалять временный каталог
  --debug FILE        писать этапы и память в FILE раз в секунду
  -h, --help

Сводка читается одним проходом по архиву. Файлы логов из logs.tar на диск
не копируются: в awk они идут потоком. Временный каталог удаляется в конце.

Меню в терминале: номер или имя компонента (core, collector, storage…).
Однозначный номер и имя открываются сразу, Enter подтверждает незаконченное.
Сводку и логи листают колёсико, стрелки и PgUp/PgDn.
Текст выделяется мышкой, как в обычном терминале. Поиск по всему списку: /.
Перед логом спрашивается, что показать: 1 ошибки, 2 debug, 3 всё.
b — к выбору компонента, i — к списку ID, c — конфигурация collector, q — выход.
EOF
}

die() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

pad() {
    local s="$1"
    local width="$2"
    local n=${#s}
    while (( n < width )); do
        s+=" "
        n=$((n + 1))
    done
    printf '%s' "$s"
}

rule() {
    local n="$1" i out=""
    for ((i = 0; i < n; i++)); do out+="─"; done
    printf '%s' "$out"
}

setup_colors() {
    USE_COLOR=0
    RST="" BOLD="" DIM=""
    C_TEXT="" C_TITLE="" C_HOST="" C_OS="" C_MEM="" C_VER="" C_DISK="" C_SVC="" C_LOG=""
    C_OK="" C_BAD="" C_WARN="" C_ASK=""
    BG_BASE="" BG_ROW=""
    if [[ "$COLOR_FLAG" == "never" ]]; then return; fi
    if [[ "$COLOR_FLAG" == "auto" && ! -t 1 ]]; then return; fi
    USE_COLOR=1
    RST=$'\033[0m'
    BOLD=$'\033[1m'
    C_TEXT=$'\033[38;2;213;222;232m'
    DIM=$'\033[38;2;125;139;153m'
    C_TITLE=$'\033[38;2;213;222;232m'
    C_HOST=$'\033[38;2;53;198;208m'
    C_OS=$'\033[38;2;213;222;232m'
    C_MEM=$'\033[38;2;213;222;232m'
    C_VER=$'\033[38;2;167;139;250m'
    C_DISK=$'\033[38;2;213;222;232m'
    C_SVC=$'\033[38;2;213;222;232m'
    C_LOG=$'\033[38;2;53;198;208m'
    C_OK=$'\033[38;2;57;217;138m'
    C_BAD=$'\033[38;2;240;100;100m'
    C_WARN=$'\033[38;2;240;180;77m'
    C_ASK=$'\033[38;2;53;198;208m'
}

record() {
    [[ -n "$OUT" && "$SKIP_OUT" -eq 0 ]] || return 0
    printf '%s\n' "$1" >> "$OUT"
}

# plain — строка для файла, colored — та же строка с уже подставленными ESC-кодами.
view_put() {
    local plain="$1" colored="$2"
    if (( UI_CAPTURE )); then
        VIEW_PLAIN+=("$plain")
        VIEW_DRAW+=("$colored")
        record "$plain"
        return 0
    fi
    if (( REPORT_QUIET )); then
        record "$plain"
        return 0
    fi
    if (( USE_COLOR )); then
        printf '%s\n' "$colored"
    else
        printf '%s\n' "$plain"
    fi
    record "$plain"
}

emit() {
    view_put "$1" "$1"
}

emit_c() {
    local color="$1" text="$2" colored="$2"
    if (( USE_COLOR )); then
        colored="${color}${text}${RST}"
    fi
    view_put "$text" "$colored"
}

left_put() {
    local plain="$1" colored="$2"
    view_put "  ${plain}" "  ${colored}"
}

left_emit() {
    local text="$1" color="$2" colored
    colored=$text
    if (( USE_COLOR )); then
        colored="${color}${text}${RST}"
    fi
    left_put "$text" "$colored"
}

menu_hit() {
    local typed="${1,,}" label="${2,,}" num="$3"
    [[ -n "$typed" ]] || return 1
    if [[ "$typed" =~ ^[0-9]+$ ]]; then
        [[ "$num" == "$typed"* ]]
        return
    fi
    [[ "$label" == "$typed"* ]]
}

char_len() {
    local s="$1" stripped
    stripped=${s//[$'\x80'-$'\xBF']/}
    printf '%s' "${#stripped}"
}

emit_kv() {
    local label="$1" value="$2" vcolor="${3:-$C_TEXT}"
    local plain colored cols gap pad
    [[ -z "$value" ]] && value="—"
    cols=$(char_len "$label")
    gap=$((8 - cols))
    if (( gap < 0 )); then
        gap=0
    fi
    pad=$(printf '%*s' "$gap" "")
    plain=$(printf '  %s%s %s' "$label" "$pad" "$value")
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '  %s%s%s%s %s%s%s' "$DIM" "$label" "$RST" "$pad" "$vcolor" "$value" "$RST")
    fi
    view_put "$plain" "$colored"
}

emit_pick() {
    local mark="$1" text="$2" color="$3"
    local plain="  $text" colored
    colored=$plain
    if (( USE_COLOR )); then
        if [[ "$mark" == "1" ]]; then
            colored=$(printf '%s%s  %s\033[K%s' "$BG_ROW" "$C_HOST" "$text" "$RST")
        else
            colored=$(printf '%s  %s%s' "$color" "$text" "$RST")
        fi
    fi
    view_put "$plain" "$colored"
}

field() {
    local color="$1" label="$2" value="$3" vcolor="${4:-}"
    local plain colored
    [[ -z "$value" ]] && value="—"
    plain="  $(pad "$label" 16) $value"
    colored=$plain
    if (( USE_COLOR )); then
        if [[ -n "$vcolor" ]]; then
            colored=$(printf '  %s%s%s %s%s%s' "$color" "$(pad "$label" 16)" "$RST" "$vcolor" "$value" "$RST")
        else
            colored=$(printf '  %s%s%s %s' "$color" "$(pad "$label" 16)" "$RST" "$value")
        fi
    fi
    view_put "$plain" "$colored"
}

section() {
    local color="$1" title="$2" source="${3:-}"
    emit ""
    emit_c "${BOLD}${color}" "$title"
    emit_c "$color" "$(rule "${#title}")"
    if [[ -n "$source" ]]; then
        field "$color" "источник" "$source"
    fi
}

progress() {
    dbg "$*"
    if (( USE_COLOR )); then
        printf '%b%s%b\n' "$DIM" "$*" "$RST" >&2
    else
        printf '%s\n' "$*" >&2
    fi
}

debug_write() {
    [[ -n "${DEBUG_FILE:-}" ]] || return 0
    {
        flock -w 5 9 || return 0
        printf '%s\n' "$1" >&9
    } 9>>"$DEBUG_FILE"
}

dbg() {
    [[ -n "${DEBUG_FILE:-}" ]] || return 0
    debug_write "$(date +%H:%M:%S)  $*"
}

debug_stage() {
    DEBUG_STAGE="$*"
    [[ -n "${DEBUG_FILE:-}" ]] || return 0
    printf '%s\n' "$DEBUG_STAGE" > "$DEBUG_FILE.stage"
    dbg "этап: $DEBUG_STAGE"
    if [[ -n "${work:-}" && -d "$work" ]]; then
        dbg "временный каталог $(du -sk "$work" 2>/dev/null | awk '{print $1 " КБ"}')"
    fi
}

debug_sample() {
    [[ -n "${DEBUG_FILE:-}" ]] || return 0
    local ts stage mem top
    ts=$(date +%H:%M:%S)
    stage=$(cat "$DEBUG_FILE.stage" 2>/dev/null || printf '%s' "-")
    mem=$(awk '/^(MemTotal|MemFree|MemAvailable|Buffers|Cached):/ {printf "%s=%dMB ", $1, int($2/1024)}' /proc/meminfo 2>/dev/null || true)
    top=$(ps -eo rss,comm --sort=-rss 2>/dev/null | awk 'NR>1 && ++n<=6 {printf "%s:%dMB ", $2, int($1/1024)}')
    debug_write "$ts  stage=$stage  $mem top[$top]"
}

debug_sampler() {
    set +e
    while :; do
        debug_sample
        sleep 1
    done
}

debug_start() {
    [[ -n "${DEBUG_FILE:-}" ]] || return 0
    : > "$DEBUG_FILE" || die "не могу записать $DEBUG_FILE"
    printf '%s\n' "старт" > "$DEBUG_FILE.stage"
    dbg "parser $PARSER_VERSION pid=$$ archive=$ARCHIVE logs=${LOGS_MODE:-}"
    debug_sampler &
    DEBUG_PID=$!
}

debug_stop() {
    [[ -n "${DEBUG_FILE:-}" ]] || return 0
    if [[ -n "${DEBUG_PID:-}" ]]; then
        kill "$DEBUG_PID" 2>/dev/null || true
        wait "$DEBUG_PID" 2>/dev/null || true
        DEBUG_PID=""
    fi
    debug_sample
    dbg "стоп"
    rm -f "$DEBUG_FILE.stage"
}

usage_bar() {
    local pct="${1:-0}" filled empty i bar=""
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    if (( pct > 100 )); then pct=100; fi
    filled=$((pct * 20 / 100))
    # 1% иначе даёт пустую полоску: целочисленное деление обнуляет её.
    if (( pct > 0 && filled == 0 )); then filled=1; fi
    empty=$((20 - filled))
    for ((i = 0; i < filled; i++)); do bar+="#"; done
    for ((i = 0; i < empty; i++)); do bar+="-"; done
    printf '%s' "$bar"
}

pct_color() {
    local n="${1:-0}"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if (( n >= 90 )); then printf '%s' "$C_BAD"
    elif (( n >= 75 )); then printf '%s' "$C_WARN"
    else printf '%s' "$C_OK"
    fi
}

status_color() {
    local s="$1"
    if [[ "$s" == *running* ]]; then printf '%s' "$C_OK"
    elif [[ "$s" == *failed* || "$s" == *dead* || "$s" == *inactive* ]]; then printf '%s' "$C_BAD"
    else printf '%s' "$C_WARN"
    fi
}

pressure_color() {
    case "$1" in
        ok) printf '%s' "$C_OK" ;;
        warn) printf '%s' "$C_WARN" ;;
        *) printf '%s' "$C_BAD" ;;
    esac
}

level_color() {
    case "$1" in
        error|fatal|panic|dpanic) printf '%s' "$C_BAD" ;;
        warn|warning) printf '%s' "$C_WARN" ;;
        *) printf '%s' "$C_TITLE" ;;
    esac
}

# LOG_VIEW: error — только ошибки, debug — только debug, all — все уровни.
level_wanted() {
    local lvl="${1,,}"
    case "${LOG_VIEW:-all}" in
        error)
            case "$lvl" in
                error|fatal|panic|dpanic) return 0 ;;
            esac
            return 1
            ;;
        debug)
            case "$lvl" in
                debug|trace) return 0 ;;
            esac
            return 1
            ;;
    esac
    return 0
}

groups_word() {
    local n="$1" n10 n100
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n10=$((n % 10))
    n100=$((n % 100))
    if (( n100 >= 11 && n100 <= 14 )); then
        printf 'групп'
    elif (( n10 == 1 )); then
        printf 'группа'
    elif (( n10 >= 2 && n10 <= 4 )); then
        printf 'группы'
    else
        printf 'групп'
    fi
}

human_mb() {
    awk -v b="${1:-0}" 'BEGIN { printf "%.2f МБ", (b+0)/1024/1024 }'
}

file_bytes() {
    stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"
}

# Windows-путь C:\... → /mnt/c/... когда скрипт запущен внутри WSL.
normalize_path() {
    local p="$1" drive
    if [[ "$p" =~ ^[A-Za-z]:[\\/] ]]; then
        drive=${p:0:1}
        drive=${drive,,}
        p=${p:2}
        p=${p//\\//}
        p="/mnt/${drive}${p}"
    fi
    printf '%s' "$p"
}

mouse_off() {
    if [[ "$MOUSE_ON" -eq 1 ]]; then
        printf '\033[?1007l\033[?1000l\033[?1006l' >/dev/tty 2>/dev/null || true
        MOUSE_ON=0
    fi
}

cursor_show() {
    if [[ "$CURSOR_HIDDEN" -eq 1 ]]; then
        printf '\033[?25h' >/dev/tty 2>/dev/null || true
        CURSOR_HIDDEN=0
    fi
}

leave_ui() {
    mouse_off
    cursor_show
    if (( USE_COLOR )); then
        RST=$'\033[0m'
        BG_BASE=""
        BG_ROW=""
        printf '\033[0m\033]110\007\033]111\007' >/dev/tty 2>/dev/null || true
    fi
    if [[ "$UI_ALT" -eq 1 ]]; then
        tput rmcup >/dev/tty 2>/dev/null || true
        UI_ALT=0
    fi
}

drop_file_cache() {
    local f="$1"
    [[ -n "$f" && -f "$f" ]] || return 0
    python3 - "$f" <<'PY' 2>/dev/null || true
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
os.close(fd)
PY
}

cleanup() {
    debug_stop
    leave_ui
    if [[ "$KEEP" -eq 0 && -n "$work" && -d "$work" ]]; then
        rm -rf "$work"
    elif [[ "$KEEP" -eq 1 && -n "$work" ]]; then
        progress "Временный каталог оставлен: $work"
    fi
}
on_stop() {
    cleanup
    exit 130
}
trap cleanup EXIT
trap on_stop INT TERM

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --top)
                [[ $# -ge 2 ]] || die "--top нуждается в числе"
                TOP="$2"
                [[ "$TOP" =~ ^[0-9]+$ && "$TOP" -ge 1 && "$TOP" -le 100 ]] || die "--top от 1 до 100"
                shift 2 ;;
            --logs)
                [[ $# -ge 2 ]] || die "--logs нуждается в значении: all, none или список ролей"
                LOGS_MODE="$2"
                shift 2 ;;
            --include-warn) INCLUDE_WARN=1; shift ;;
            --keep-work) KEEP=1; shift ;;
            --debug)
                [[ $# -ge 2 ]] || die "--debug нуждается в пути к файлу"
                DEBUG_FILE="$2"
                shift 2 ;;
            --no-color) COLOR_FLAG="never"; shift ;;
            --color) COLOR_FLAG="always"; shift ;;
            --out)
                [[ $# -ge 2 ]] || die "--out нуждается в пути"
                OUT="$2"
                shift 2 ;;
            --report|--report=all)
                if [[ "$1" == "--report=all" ]]; then
                    REPORT=2
                    shift
                elif [[ $# -ge 2 && "$2" == "all" ]]; then
                    REPORT=2
                    shift 2
                else
                    REPORT=1
                    shift
                fi
                ;;
            --report=*) die "--report: нужно --report или --report=all" ;;
            --) shift; break ;;
            -*) die "неизвестный ключ: $1" ;;
            *)
                [[ -z "$ARCHIVE" ]] || die "лишний аргумент: $1"
                ARCHIVE="$1"
                shift ;;
        esac
    done
    [[ -n "$ARCHIVE" ]] || die "укажите архив коллекта или уже распакованный каталог"
}

# Самый короткий путь с нужным суффиксом. Регистр сначала точный.
pick_entry() {
    local suffix="$1" best="" e low
    local suffix_low=${suffix,,}
    for e in "${entries[@]}"; do
        if [[ "$e" == *"$suffix" ]]; then
            if [[ -z "$best" || ${#e} -lt ${#best} ]]; then best=$e; fi
        fi
    done
    if [[ -z "$best" ]]; then
        for e in "${entries[@]}"; do
            low=${e,,}
            if [[ "$low" == *"$suffix_low" ]]; then
                if [[ -z "$best" || ${#e} -lt ${#best} ]]; then best=$e; fi
            fi
        done
    fi
    printf '%s' "$best"
}

find_suffix() {
    local root="$1" suffix="$2" f norm best=""
    [[ -d "$root" ]] || return 0
    while IFS= read -r -d '' f; do
        norm=${f//\\//}
        if [[ "$norm" == *"$suffix" ]]; then
            if [[ -z "$best" || ${#f} -lt ${#best} ]]; then best=$f; fi
        fi
    done < <(find "$root" -type f -print0)
    printf '%s' "$best"
}

add_ipv4() {
    local ip="$1" have
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 0
    [[ "$ip" == 127.* ]] && return 0
    if (( ${#HOST_IP[@]} > 0 )); then
        for have in "${HOST_IP[@]}"; do
            [[ "$have" == "$ip" ]] && return 0
        done
    fi
    HOST_IP+=("$ip")
}

load_ips() {
    HOST_IP=()
    local file="$1" line iface="" addr scope ip
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if [[ "$line" =~ ^[0-9]+:[[:space:]]+([^:]+) ]]; then
            iface=${BASH_REMATCH[1]}
            iface=${iface%%@*}
            iface=${iface%% *}
            continue
        fi
        [[ "$iface" == "lo" ]] && continue
        if [[ "$line" =~ inet[[:space:]]+([^[:space:]]+) ]]; then
            addr=${BASH_REMATCH[1]}
            add_ipv4 "${addr%%/*}"
        fi
    done < "$file"
}

load_ifconfig() {
    local file="$1" line iface="" addr
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if [[ "$line" =~ ^([^[:space:]:]+):[[:space:]]+flags= ]]; then
            iface=${BASH_REMATCH[1]}
            continue
        fi
        [[ "$iface" == "lo" || "$iface" == "lo0" ]] && continue
        if [[ "$line" =~ inet[[:space:]]+([0-9.]+) ]]; then
            add_ipv4 "${BASH_REMATCH[1]}"
        fi
    done < "$file"
}

load_cpu() {
    HOST_CPU_N=0
    HOST_CPU_PHYS=0
    HOST_CPU_MODEL=""
    local file="$1" line phys="" core="" key
    local -A seen=()
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if [[ "$line" =~ ^processor[[:space:]]*: ]]; then
            HOST_CPU_N=$((HOST_CPU_N + 1))
            phys=""
            core=""
        elif [[ -z "$HOST_CPU_MODEL" && "$line" =~ ^model\ name[[:space:]]*:[[:space:]]*(.*)$ ]]; then
            HOST_CPU_MODEL=${BASH_REMATCH[1]}
            HOST_CPU_MODEL=${HOST_CPU_MODEL%"${HOST_CPU_MODEL##*[![:space:]]}"}
        elif [[ "$line" =~ ^physical\ id[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
            phys=${BASH_REMATCH[1]}
        elif [[ "$line" =~ ^core\ id[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
            core=${BASH_REMATCH[1]}
            [[ -n "$phys" ]] || continue
            key="${phys}:${core}"
            if [[ -z "${seen[$key]:-}" ]]; then
                seen[$key]=1
                HOST_CPU_PHYS=$((HOST_CPU_PHYS + 1))
            fi
        fi
    done < "$file"
}

load_cpu_sysctl() {
    local file="$1" line
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if [[ "$line" =~ ^hw\.ncpu[[:space:]]*[:=][[:space:]]*([0-9]+) ]]; then
            HOST_CPU_N=${BASH_REMATCH[1]}
        elif [[ "$line" =~ ^machdep\.cpu\.brand_string[[:space:]]*[:=][[:space:]]*(.*)$ ]]; then
            HOST_CPU_MODEL=${BASH_REMATCH[1]}
            HOST_CPU_MODEL=${HOST_CPU_MODEL%"${HOST_CPU_MODEL##*[![:space:]]}"}
        elif [[ -z "$HOST_CPU_MODEL" && "$line" =~ ^hw\.model[[:space:]]*[:=][[:space:]]*(.*)$ ]]; then
            HOST_CPU_MODEL=${BASH_REMATCH[1]}
            HOST_CPU_MODEL=${HOST_CPU_MODEL%"${HOST_CPU_MODEL##*[![:space:]]}"}
        fi
    done < "$file"
}

# Числа top приводятся к МиБ по подписи рядом с числом, не по месту в строке.
# У procps порядок полей менялся: раньше used стоял сразу после total.
read_mem_awk() {
    LC_NUMERIC=C awk '
        function num(s) {
            gsub(/[[:space:]]/, "", s)
            if (s ~ /,[0-9]+$/ && s ~ /\./) {
                gsub(/\./, "", s)
                gsub(/,/, ".", s)
            } else if (s ~ /\.[0-9]+$/ && s ~ /,/) {
                gsub(/,/, "", s)
            } else {
                gsub(/,/, ".", s)
            }
            return s + 0
        }
        function to_mib(tok,    n, u, ch) {
            ch = substr(tok, length(tok), 1)
            if (ch ~ /[KMGT]/) {
                n = num(substr(tok, 1, length(tok) - 1))
                u = ch
            } else {
                return num(tok)
            }
            if (u == "K") return n / 1024
            if (u == "G") return n * 1024
            if (u == "T") return n * 1024 * 1024
            return n
        }
        function human(m) {
            if (m >= 1024) return sprintf("%.1f ГБ", m / 1024)
            return sprintf("%.0f МиБ", m)
        }
        function take_labeled(line,    token, parts, key) {
            while (match(line, /[0-9]+([.,][0-9]+)?[[:space:]]+(total|free|used|avail)/)) {
                token = substr(line, RSTART, RLENGTH)
                split(token, parts, /[[:space:]]+/)
                key = parts[2]
                if (!(key in val)) val[key] = num(parts[1])
                line = substr(line, RSTART + RLENGTH)
            }
        }
        function sentence(    s, t) {
            if (!("total" in val)) return ""
            t = val["total"]
            if (t >= 1024) s = "всего " human(t) " (" sprintf("%.1f МиБ", t) ")"
            else s = "всего " human(t)
            if ("used" in val) s = s ", занято " human(val["used"])
            if ("free" in val) s = s ", свободно " human(val["free"])
            if ("avail" in val) s = s ", доступно " human(val["avail"])
            return s
        }
        {
            sub(/\r$/, "")
            if (unit == "" && $0 ~ /^(KiB|MiB|GiB)[[:space:]]+Mem[[:space:]]*:/) {
                unit = substr($0, 1, 3)
                take_labeled($0)
                next
            }
            if (unit != "" && !("avail" in val) && match($0, /[0-9]+([.,][0-9]+)?[[:space:]]+avail[[:space:]]+Mem/)) {
                split(substr($0, RSTART, RLENGTH), parts, /[[:space:]]+/)
                val["avail"] = num(parts[1])
            }
            if (!("total" in val) && $0 ~ /^PhysMem:/) {
                if (match($0, /[0-9]+([.,][0-9]+)?[KMGT][[:space:]]+used([^A-Za-z]|$)/)) {
                    split(substr($0, RSTART, RLENGTH), parts, /[[:space:]]+/)
                    val["used"] = to_mib(parts[1])
                }
                if (match($0, /[0-9]+([.,][0-9]+)?[KMGT][[:space:]]+unused/)) {
                    split(substr($0, RSTART, RLENGTH), parts, /[[:space:]]+/)
                    val["free"] = to_mib(parts[1])
                }
                if (("used" in val) && ("free" in val)) val["total"] = val["used"] + val["free"]
            }
            if (!("total" in val) && $0 ~ /^Mem:/ && $0 ~ /(Active|Inact|Wired|Free|Total)/) {
                line = $0
                sum = 0
                while (match(line, /[0-9]+([.,][0-9]+)?[KMGT][[:space:]]+[A-Za-z]+/)) {
                    split(substr(line, RSTART, RLENGTH), parts, /[[:space:]]+/)
                    part[parts[2]] = to_mib(parts[1])
                    sum += part[parts[2]]
                    line = substr(line, RSTART + RLENGTH)
                }
                if ("Total" in part) val["total"] = part["Total"]
                else if (sum > 0) val["total"] = sum
                if ("Free" in part) val["free"] = part["Free"]
                used = 0
                if ("Active" in part) used += part["Active"]
                if ("Wired" in part) used += part["Wired"]
                if ("Laundry" in part) used += part["Laundry"]
                if (used > 0) val["used"] = used
            }
        }
        END {
            if (unit == "KiB") {
                if ("total" in val) val["total"] /= 1024
                if ("used" in val) val["used"] /= 1024
                if ("free" in val) val["free"] /= 1024
                if ("avail" in val) val["avail"] /= 1024
            } else if (unit == "GiB") {
                if ("total" in val) val["total"] *= 1024
                if ("used" in val) val["used"] *= 1024
                if ("free" in val) val["free"] *= 1024
                if ("avail" in val) val["avail"] *= 1024
            }
            printf "%s", sentence()
        }
    ' "$1"
}

read_memory_file() {
    LC_NUMERIC=C awk '
        function num(s) {
            gsub(/[[:space:]]/, "", s)
            if (s ~ /,[0-9]+$/ && s ~ /\./) {
                gsub(/\./, "", s)
                gsub(/,/, ".", s)
            } else if (s ~ /\.[0-9]+$/ && s ~ /,/) {
                gsub(/,/, "", s)
            } else {
                gsub(/,/, ".", s)
            }
            return s + 0
        }
        function to_mib(tok,    n, u) {
            if (match(tok, /^[0-9]+([.,][0-9]+)?/)) {
                n = num(substr(tok, 1, RLENGTH))
                u = substr(tok, RLENGTH + 1, 1)
            } else return 0
            if (u == "K" || u == "k") return n / 1024
            if (u == "G" || u == "g") return n * 1024
            if (u == "T" || u == "t") return n * 1024 * 1024
            if (u == "M" || u == "m") return n
            if (tok ~ /kB$/) return n / 1024
            return n
        }
        function human(m) {
            if (m >= 1024) return sprintf("%.1f ГБ", m / 1024)
            return sprintf("%.0f МиБ", m)
        }
        {
            sub(/\r$/, "")
            if (total == 0 && $1 == "Mem:" && NF >= 4 && $2 ~ /[0-9]/) {
                total = to_mib($2); used = to_mib($3); free = to_mib($4)
                if (NF >= 7) avail = to_mib($7)
            }
            if ($1 == "MemTotal:") kb_total = $2 + 0
            if ($1 == "MemFree:") kb_free = $2 + 0
            if ($1 == "MemAvailable:") kb_avail = $2 + 0
        }
        END {
            if (total == 0 && kb_total > 0) {
                total = kb_total / 1024
                free = kb_free / 1024
                if (kb_avail > 0) avail = kb_avail / 1024
                if (total > avail && avail > 0) used = total - avail
            }
            if (total <= 0) exit
            s = "всего " human(total)
            if (total >= 1024) s = s " (" sprintf("%.1f МиБ", total) ")"
            if (used > 0) s = s ", занято " human(used)
            if (free > 0) s = s ", свободно " human(free)
            if (avail > 0) s = s ", доступно " human(avail)
            printf "%s", s
        }
    ' "$1"
}

load_mem() {
    HOST_MEM_TEXT=""
    local top="$1" mem="${2:-}"
    if [[ -f "$top" ]]; then
        HOST_MEM_TEXT=$(read_mem_awk "$top")
    fi
    if [[ -z "$HOST_MEM_TEXT" && -n "$mem" && -f "$mem" ]]; then
        HOST_MEM_TEXT=$(read_memory_file "$mem")
    fi
}

load_top_pressure() {
    HOST_LA1="" HOST_LA5="" HOST_LA15="" HOST_WA=""
    local file="$1" line
    [[ -n "$file" && -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if [[ -z "$HOST_LA1" && "$line" =~ [Ll]oad\ [Aa]verages?:[[:space:]]*([0-9]+([.,][0-9]+)?)[,[:space:]]+([0-9]+([.,][0-9]+)?)[,[:space:]]+([0-9]+([.,][0-9]+)?) ]]; then
            HOST_LA1=${BASH_REMATCH[1]//,/.}
            HOST_LA5=${BASH_REMATCH[3]//,/.}
            HOST_LA15=${BASH_REMATCH[5]//,/.}
        fi
        if [[ -z "$HOST_WA" && "$line" == *[Cc]pu* && "$line" =~ ([0-9]+([.,][0-9]+)?)[[:space:]]+%?wa ]]; then
            HOST_WA=${BASH_REMATCH[1]//,/.}
        fi
        [[ -n "$HOST_LA1" && -n "$HOST_WA" ]] && break
    done < "$file"
}

fill_pressure() {
    PRESS_LA_VALUE="" PRESS_LA_TAIL="" PRESS_LA_COLOR="$C_TEXT"
    PRESS_WA_VALUE="" PRESS_WA_COLOR="$C_TEXT"
    local band per word
    if [[ -n "${HOST_LA1:-}" ]]; then
        if [[ "${HOST_CPU_N:-0}" -eq 0 ]]; then
            PRESS_LA_VALUE="$HOST_LA1"
            PRESS_LA_COLOR="$C_WARN"
            PRESS_LA_TAIL="нет ядер"
        else
            per=$(awk -v la="$HOST_LA1" -v n="$HOST_CPU_N" 'BEGIN { printf "%.2f", (la + 0) / (n + 0) }')
            band=$(awk -v x="$per" 'BEGIN {
                x += 0
                if (x < 0.7) print "ok"
                else if (x < 1) print "warn"
                else if (x <= 2) print "high"
                else print "bad"
            }')
            case "$band" in
                ok) word="" ;;
                warn) word="занята" ;;
                high) word="очередь" ;;
                *) word="перегрузка" ;;
            esac
            PRESS_LA_COLOR=$(pressure_color "$band")
            if [[ -n "$word" ]]; then
                PRESS_LA_VALUE="${per}/ядро  ${word}"
            else
                PRESS_LA_VALUE="${per}/ядро"
            fi
            PRESS_LA_TAIL="${HOST_LA1}  ${HOST_LA5}  ${HOST_LA15}"
        fi
    fi
    if [[ -n "${HOST_WA:-}" ]]; then
        band=$(awk -v x="$HOST_WA" 'BEGIN {
            x += 0
            if (x < 10) print "ok"
            else if (x > 20) print "bad"
            else print "warn"
        }')
        PRESS_WA_COLOR=$(pressure_color "$band")
        PRESS_WA_VALUE="${HOST_WA}%"
    fi
}

squeeze_spaces() {
    local s="$1"
    while [[ "$s" == *"  "* ]]; do
        s=${s//  / }
    done
    printf '%s' "$s"
}

load_uptime() {
    HOST_UPTIME=""
    local file="$1" line rest
    [[ -f "$file" ]] || return 0
    IFS= read -r line < "$file" || return 0
    line=${line%$'\r'}
    [[ "$line" =~ up[[:space:]]+(.*) ]] || return 0
    rest=${BASH_REMATCH[1]}
    if [[ "$rest" =~ ^(.+),[[:space:]]+[0-9]+[[:space:]]+(users?|пользовател) ]]; then
        rest=${BASH_REMATCH[1]}
    elif [[ "$rest" =~ ^(.+),[[:space:]]*(load[[:space:]]+average|средн) ]]; then
        rest=${BASH_REMATCH[1]}
    fi
    rest=${rest#"${rest%%[![:space:]]*}"}
    rest=${rest%"${rest##*[![:space:]]}"}
    rest=${rest%,}
    HOST_UPTIME=$(squeeze_spaces "$rest")
}

load_timezone() {
    HOST_TZ=""
    local timedate="$1" date_en="$2" date_file="$3" line val
    if [[ -f "$timedate" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line=${line%$'\r'}
            if [[ "$line" =~ (Time[[:space:]]*zone|Timezone|Часовой[[:space:]]+пояс)[[:space:]]*:[[:space:]]*(.+)$ ]]; then
                val=${BASH_REMATCH[2]}
                val=${val%"${val##*[![:space:]]}"}
                HOST_TZ=$val
                return 0
            fi
        done < "$timedate"
    fi
    for line in "$date_en" "$date_file"; do
        [[ -f "$line" ]] || continue
        IFS= read -r val < "$line" || continue
        val=${val%$'\r'}
        if [[ "$val" =~ [[:space:]]([A-Za-z]{2,5})[[:space:]]+[0-9]{4}[[:space:]]*$ ]]; then
            HOST_TZ=${BASH_REMATCH[1]}
            return 0
        fi
    done
}

res_phrase() {
    local n="$1"
    if [[ "$n" =~ ^[0-9]+$ ]]; then
        if (( n >= 1048576 )); then
            awk -v n="$n" 'BEGIN { printf "%.1f GB", n / 1048576 }'
        elif (( n >= 1024 )); then
            awk -v n="$n" 'BEGIN { printf "%.0f MB", n / 1024 }'
        else
            printf '%s KB' "$n"
        fi
    else
        printf '%s' "$n"
    fi
}

load_top_procs() {
    TOP_PROC_CMD=()
    TOP_PROC_CPU=()
    TOP_PROC_MEM=()
    TOP_PROC_RES=()
    local file="$1" line cmd cpu mem res
    [[ -f "$file" ]] || return 0
    while IFS=$'\036' read -r cmd cpu mem res || [[ -n "${cmd:-}" ]]; do
        [[ -n "${cmd:-}" ]] || continue
        [[ "$cpu" == *% ]] || cpu="${cpu}%"
        [[ "$mem" == *% ]] || mem="${mem}%"
        TOP_PROC_CMD+=("$cmd")
        TOP_PROC_CPU+=("$cpu")
        TOP_PROC_MEM+=("$mem")
        TOP_PROC_RES+=("$(res_phrase "$res")")
    done < <(awk '
        BEGIN { cpu = 0; mem = 0; res = 0; cmd = 0; n = 0 }
        cpu == 0 {
            for (i = 1; i <= NF; i++) {
                if ($i == "%CPU") cpu = i
                else if ($i == "%MEM") mem = i
                else if ($i == "RES") res = i
                else if ($i == "COMMAND" || $i == "Command") cmd = i
            }
            next
        }
        $1 ~ /^[0-9]+$/ && cmd > 0 && NF >= cmd && n < 5 {
            name = $cmd
            for (i = cmd + 1; i <= NF; i++) name = name " " $i
            printf "%s\036%s\036%s\036%s\n", name, $cpu, $mem, $res
            n++
        }
    ' "$file")
}

svc_age() {
    local s="$1"
    [[ -n "$s" ]] || return 0
    if [[ "$s" == *";"* ]]; then
        s=${s##*;}
    fi
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    s=${s% ago}
    s=${s% назад}
    s=${s//min/ min}
    s=${s//sec/ sec}
    s=${s//мин/ мин}
    s=${s//сек/ сек}
    s=$(printf '%s' "$s" | sed -E 's/([0-9])s([^[:alpha:]]|$)/\1 s\2/g')
    squeeze_spaces "$s"
}

svc_age_label() {
    local since="$1" state="$2" age
    age=$(svc_age "$since")
    [[ -n "$age" ]] || return 0
    if [[ "$state" == *running* ]]; then
        printf 'up %s' "$age"
    else
        printf 'off %s' "$age"
    fi
}

emit_mem_cpu() {
    local cpu
    if [[ -z "${HOST_MEM_TEXT:-}" ]]; then
        field "$C_HOST" "RAM" "не найдена"
    else
        field "$C_HOST" "RAM" "$HOST_MEM_TEXT"
    fi
    if [[ "${HOST_CPU_N:-0}" -eq 0 ]]; then
        field "$C_HOST" "CPU" "не найден"
    elif [[ "${HOST_CPU_PHYS:-0}" -gt 0 && "$HOST_CPU_PHYS" -ne "$HOST_CPU_N" ]]; then
        cpu="${HOST_CPU_N} лог. / ${HOST_CPU_PHYS} физ."
        field "$C_HOST" "CPU" "${cpu}${HOST_CPU_MODEL:+  ${HOST_CPU_MODEL}}"
    else
        field "$C_HOST" "CPU" "${HOST_CPU_N}${HOST_CPU_MODEL:+  ${HOST_CPU_MODEL}}"
    fi
    fill_pressure
    if [[ -n "$PRESS_LA_VALUE" ]]; then
        field "$C_HOST" "LA" "${PRESS_LA_VALUE}${PRESS_LA_TAIL:+  ${PRESS_LA_TAIL}}" "$PRESS_LA_COLOR"
    fi
    if [[ -n "$PRESS_WA_VALUE" ]]; then
        field "$C_HOST" "WA" "$PRESS_WA_VALUE" "$PRESS_WA_COLOR"
    fi
    if [[ ${#TOP_PROC_CMD[@]} -eq 0 ]]; then
        field "$C_HOST" "top" "не распознан"
    else
        local i
        for i in "${!TOP_PROC_CMD[@]}"; do
            field "$C_HOST" "$((i + 1))" "${TOP_PROC_CMD[$i]}  CPU ${TOP_PROC_CPU[$i]}  RAM ${TOP_PROC_MEM[$i]}  ${TOP_PROC_RES[$i]}"
        done
    fi
}

host_is_fqdn() {
    local n="${1,,}"
    n=${n#"${n%%[![:space:]]*}"}
    n=${n%"${n##*[![:space:]]}"}
    n=${n%.}
    [[ -n "$n" ]] || return 1
    case "$n" in
        localhost|localhost.localdomain|n/a|unset|"(unset)"|none|-) return 1 ;;
    esac
    [[ "$n" == *.* ]] || return 1
    [[ "$n" =~ ^[0-9.]+$ ]] && return 1
    [[ "${n#*.}" == *[[:alpha:]]* ]] || return 1
    return 0
}

load_hostname() {
    HOST_NAME="" HOST_STATIC="" HOST_OS="" HOST_KERNEL="" HOST_ARCH="" HOST_VIRT="" HOST_CHASSIS=""
    HOST_HAS_FQDN=0
    local file="$1" line key val
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([^:]+):[[:space:]]*(.*)$ ]]; then
            key=${BASH_REMATCH[1]}
            key=${key,,}
            key=${key#"${key%%[![:space:]]*}"}
            val=${BASH_REMATCH[2]}
            val=${val%"${val##*[![:space:]]}"}
            case "$key" in
                "static hostname"|"статический hostname") HOST_STATIC=$val ;;
                "operating system"|"операционная система") HOST_OS=$val ;;
                "kernel"|"ядро") HOST_KERNEL=$val ;;
                "architecture"|"архитектура") HOST_ARCH=$val ;;
                "virtualization"|"виртуализация") HOST_VIRT=$val ;;
                "chassis"|"шасси") HOST_CHASSIS=$val ;;
            esac
        elif [[ -z "$HOST_NAME" ]]; then
            HOST_NAME=${line#"${line%%[![:space:]]*}"}
            HOST_NAME=${HOST_NAME%"${HOST_NAME##*[![:space:]]}"}
        fi
    done < "$file"
    [[ -n "$HOST_NAME" ]] || HOST_NAME=$HOST_STATIC
    if host_is_fqdn "${HOST_STATIC:-$HOST_NAME}"; then
        HOST_HAS_FQDN=1
    fi
}

load_version() {
    VER_LINES=()
    local file="$1" line
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ -z "${line//[[:space:]]/}" ]] && continue
        VER_LINES+=("$line")
    done < "$file"
}

load_services() {
    svc_role=(); svc_id=(); svc_state=(); svc_since=()
    svc_pid=(); svc_boot=(); svc_unit=(); svc_desc=()
    local file="$1"
    [[ -f "$file" ]] || return 0
    local line unit desc role id state since pid boot rest
    local -A svc_seen=()
    unit=""; desc=""; role=""; id=""; state=""; since=""; pid=""; boot=""
    # Служба — только заголовок systemctl status в начале строки.
    # Строка журнала «Started kuma-….service - …» начинается с даты и службой не считается.
    # Повтор того же юнита и блок без Active отбрасываются.
    flush_svc() {
        [[ -n "$unit" && -n "$state" ]] || return 0
        [[ -n "${svc_seen[$unit]:-}" ]] && return 0
        svc_seen[$unit]=1
        svc_unit+=("$unit"); svc_desc+=("$desc"); svc_role+=("$role"); svc_id+=("$id")
        svc_state+=("$state"); svc_since+=("$since"); svc_pid+=("$pid"); svc_boot+=("$boot")
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if ((${#line} < 400)) && [[ "$line" =~ ^[[:space:]]*[●○*]?[[:space:]]*(kuma-[A-Za-z0-9_.@-]+\.service)[[:space:]]+-[[:space:]]+(.+)$ ]]; then
            flush_svc
            unit=${BASH_REMATCH[1]}
            desc=${BASH_REMATCH[2]}
            desc=${desc%"${desc##*[![:space:]]}"}
            role=""; id=""; state=""; since=""; pid=""; boot=""
            if [[ "$unit" =~ ^kuma-([a-z0-9]+)-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.service$ ]]; then
                role=${BASH_REMATCH[1]}
                id=${BASH_REMATCH[2]}
            elif [[ "$unit" =~ ^kuma-([a-z0-9]+)\.service$ ]]; then
                role=${BASH_REMATCH[1]}
            fi
            continue
        fi
        [[ -n "$unit" ]] || continue
        if [[ -z "$boot" && "$line" =~ Loaded:[[:space:]]+(.+)$ ]]; then
            rest=${BASH_REMATCH[1]}
            if [[ "$rest" =~ \;[[:space:]]*(enabled|disabled|static|masked|indirect|generated|transient)\; ]]; then
                boot=${BASH_REMATCH[1]}
            elif [[ "$rest" == *not-found* ]]; then
                boot="not-found"
            fi
        fi
        if [[ -z "$state" && "$line" =~ Active:[[:space:]]+(.+)$ ]]; then
            rest=${BASH_REMATCH[1]}
            rest=${rest%"${rest##*[![:space:]]}"}
            if [[ "$rest" == *" since "* ]]; then
                state=${rest%% since *}
                since=${rest#* since }
            else
                state=$rest
            fi
        fi
        if [[ -z "$pid" && "$line" =~ Main\ PID:[[:space:]]+([0-9]+) ]]; then
            pid=${BASH_REMATCH[1]}
        fi
    done < "$file"
    flush_svc
}

role_rank() {
    case "$1" in
        core) echo 1 ;;
        collector) echo 2 ;;
        correlator) echo 3 ;;
        storage) echo 4 ;;
        metrics) echo 5 ;;
        *) echo 9 ;;
    esac
}

sorted_service_indexes() {
    local i
    for i in "${!svc_role[@]}"; do
        printf '%s\t%s\t%s\n' "$(role_rank "${svc_role[$i]}")" "${svc_unit[$i]}" "$i"
    done | sort -t $'\t' -k1,1n -k2,2 | cut -f3
}

load_disks() {
    disk_mnt=(); disk_fs=(); disk_dev=(); disk_size=(); disk_used=(); disk_avail=(); disk_pct=()
    DISK_MOUNT_TOTAL=0
    local file="$1"
    [[ -f "$file" ]] || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ "$line" == DISK* ]] || continue
        IFS=$'\t' read -r _ mnt fs dev size used avail pct <<<"$line"
        disk_mnt+=("$mnt"); disk_fs+=("$fs"); disk_dev+=("$dev")
        disk_size+=("$size"); disk_used+=("$used"); disk_avail+=("$avail"); disk_pct+=("$pct")
    done < <(awk '
        function is_s3(dev, fs) {
            if (fs ~ /s3/ || fs ~ /goofys/ || fs ~ /geesefs/) return 1
            if (dev ~ /^s3fs/ || dev ~ /^s3:/ || dev ~ /^mount-s3/ || dev ~ /^mountpoint-s3/) return 1
            if (dev ~ /^goofys/ || dev ~ /^geesefs/) return 1
            return 0
        }
        function is_disk(dev, fs) {
            if (fs ~ /^(ext[234]|xfs|btrfs|zfs|vfat|fat32|ntfs|fuseblk|reiserfs|f2fs|apfs|hfs|ufs|ffs|msdos|exfat)$/) return 1
            if (fs ~ /^(nfs|nfs4|cifs|smb3|smbfs)$/) return 1
            if (is_s3(dev, fs)) return 1
            return 0
        }
        function mount_key(m) { return (m == "/" ? "0/" : "1" m) }
        function remember(dev, mnt, fs) {
            mounts++
            if (!is_disk(dev, fs)) return
            if (mnt in fs_of) return
            fs_of[mnt] = fs
            dev_of[mnt] = dev
            order[++nd] = mnt
        }
        BEGIN { sect = "" }
        {
            sub(/\r$/, "")
            if ($0 ~ /^[A-Za-z].*:[[:space:]]*$/ && $0 !~ / on /) {
                if ($0 ~ /^mount:/) sect = "mount"
                else if ($0 ~ /^df -h:/) sect = "df"
                else sect = "other"
                next
            }
            if ($0 ~ /^Filesystem/) {
                if ($0 ~ /(^|[[:space:]])(Size|Used|1K-blocks)([[:space:]]|$)/) {
                    if (sect != "df") sect = "plaindf"
                } else {
                    sect = "other"
                }
                next
            }
            if (sect == "mount" && $0 ~ / on / && $0 ~ / type /) {
                n = split($0, a, " type ")
                if (n < 2) next
                left = a[1]
                split(a[2], b, " ")
                fs = b[1]
                p = index(left, " on ")
                if (!p) next
                dev = substr(left, 1, p - 1)
                mnt = substr(left, p + 4)
                sub(/[[:space:]]+$/, "", mnt)
                remember(dev, mnt, fs)
            } else if (sect == "" && $0 ~ / on / && index($0, " (") > 0) {
                p = index($0, " (")
                left = substr($0, 1, p - 1)
                fs = substr($0, p + 2)
                sub(/[,)].*$/, "", fs)
                p = index(left, " on ")
                if (!p || fs == "") next
                dev = substr(left, 1, p - 1)
                mnt = substr(left, p + 4)
                sub(/[[:space:]]+$/, "", mnt)
                remember(dev, mnt, fs)
            } else if ((sect == "df" || sect == "plaindf") && $0 !~ /^[[:space:]]/ && NF >= 5 && $1 != "Filesystem") {
                p = 0
                for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+%$/) { p = i; break }
                if (!p || p < 4) next
                size = $(p - 3); used = $(p - 2); avail = $(p - 1); pct = $p
                gsub(/,/, ".", size); gsub(/,/, ".", used); gsub(/,/, ".", avail)
                lastp = p
                for (i = p; i <= NF; i++) if ($i ~ /%$/) lastp = i
                if (lastp >= NF) next
                mnt = $(lastp + 1)
                for (i = lastp + 2; i <= NF; i++) mnt = mnt " " $i
                df_dev[mnt] = $1
                df_size[mnt] = size; df_used[mnt] = used; df_avail[mnt] = avail; df_pct[mnt] = pct
            }
        }
        function by_mnt(i1, v1, i2, v2) {
            k1 = mount_key(v1); k2 = mount_key(v2)
            if (k1 < k2) return -1
            if (k1 > k2) return 1
            return 0
        }
        END {
            if (nd == 0) {
                for (m in df_size) {
                    dev = df_dev[m]
                    if (dev ~ /^(tmpfs|devtmpfs|devfs|udev|none|overlay|map|autofs|procfs|linprocfs|fdescfs|squashfs)/) continue
                    if (!is_s3(dev, "") && dev !~ /^\// && dev !~ /:/) continue
                    fs_of[m] = "?"
                    dev_of[m] = dev
                    order[++nd] = m
                }
            }
            print "TOTAL\t" mounts + 0
            if (nd > 0) asort(order, sorted, "by_mnt")
            for (i = 1; i <= nd; i++) {
                m = sorted[i]
                size = (m in df_size ? df_size[m] : "—")
                used = (m in df_used ? df_used[m] : "—")
                avail = (m in df_avail ? df_avail[m] : "—")
                pct = (m in df_pct ? df_pct[m] : "—")
                print "DISK\t" m "\t" fs_of[m] "\t" dev_of[m] "\t" size "\t" used "\t" avail "\t" pct
            }
        }
    ' "$file")
    if [[ "$line" == TOTAL* ]]; then
        DISK_MOUNT_TOTAL=${line#TOTAL$'\t'}
    fi
}

# load_disks читает TOTAL отдельной строкой, но цикл выше её пропускает
# через фильтр DISK*. Сохраняем итог прямым вызовом ниже, если awk его отдал.
# Перечитываем TOTAL из того же потока нельзя — он уже съеден. Считаем в awk
# ещё раз коротко, если массив пуст это не страшно: итог кладётся так:
capture_mount_total() {
    local file="$1"
    DISK_MOUNT_TOTAL=0
    [[ -f "$file" ]] || return 0
    DISK_MOUNT_TOTAL=$(awk '
        BEGIN { sect=""; n=0 }
        {
            sub(/\r$/, "")
            if ($0 ~ /^Filesystem/) next
            if ($0 ~ /^[A-Za-z].*:[[:space:]]*$/ && $0 !~ / on /) {
                sect = ($0 ~ /^mount:/ ? "mount" : "other"); next
            }
            if (sect == "mount" && $0 ~ / on / && $0 ~ / type /) n++
            else if (sect == "" && $0 ~ / on / && $0 ~ /\(/) n++
        }
        END { print n + 0 }
    ' "$file")
}

summarize_disks() {
    DISK_SUM_TEXT=""
    ((${#disk_mnt[@]})) || return 0
    local i dev key
    local -A seen=()
    local rows=()
    for i in "${!disk_mnt[@]}"; do
        dev=${disk_dev[$i]}
        key=${dev:-${disk_mnt[$i]}}
        [[ -n "${seen[$key]:-}" ]] && continue
        seen[$key]=1
        rows+=("${disk_size[$i]}"$'\t'"${disk_used[$i]}"$'\t'"${disk_avail[$i]}")
    done
    DISK_SUM_TEXT=$(printf '%s\n' "${rows[@]}" | LC_NUMERIC=C awk '
        function bytes_of(s,    n, u) {
            if (s == "" || s == "—" || s == "-") return 0
            if (!match(s, /^[0-9]+(\.[0-9]+)?/)) return 0
            n = substr(s, 1, RLENGTH) + 0
            u = substr(s, RLENGTH + 1)
            sub(/i$/, "", u)
            if (u == "K" || u == "k") return n * 1024
            if (u == "M" || u == "m") return n * 1024 * 1024
            if (u == "G" || u == "g") return n * 1024 * 1024 * 1024
            if (u == "T" || u == "t") return n * 1024 * 1024 * 1024 * 1024
            return n
        }
        function human_b(b) {
            if (b >= 1024 ^ 4) return sprintf("%.1f ТБ", b / (1024 ^ 4))
            if (b >= 1024 ^ 3) return sprintf("%.1f ГБ", b / (1024 ^ 3))
            if (b >= 1024 ^ 2) return sprintf("%.0f МБ", b / (1024 ^ 2))
            return sprintf("%.0f КБ", b / 1024)
        }
        BEGIN { FS = "\t" }
        {
            ts += bytes_of($1); tu += bytes_of($2); ta += bytes_of($3)
        }
        END {
            if (ts <= 0 && tu <= 0 && ta <= 0) exit
            printf "всего %s, занято %s, свободно %s", human_b(ts), human_b(tu), human_b(ta)
        }
    ')
}

print_banner() {
    local base when="" host_in_name="" size_txt prefix_txt
    base=$(basename "$ARCHIVE_RAW")
    emit ""
    emit_c "${BOLD}${C_TITLE}" "KUMA collect    parser ${PARSER_VERSION}"
    emit_c "$DIM" "визуальные улучшения"
    emit_c "$DIM" "линейный отчёт. меню с очисткой экрана открывается в терминале без --logs"
    field "$DIM" "архив" "$base"
    if [[ "$IS_DIR" -eq 0 && -f "$ARCHIVE" ]]; then
        field "$DIM" "размер" "$(human_mb "$(file_bytes "$ARCHIVE")")"
    fi
    if [[ "$base" =~ ^(.+)-([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2})_collect\.tar\.gz$ ]]; then
        host_in_name=${BASH_REMATCH[1]}
        when="${BASH_REMATCH[2]} ${BASH_REMATCH[3]}:${BASH_REMATCH[4]}"
        field "$DIM" "снят" "$when  (из имени файла)"
        if [[ -n "$HOST_NAME" && "$host_in_name" != "$HOST_NAME" ]]; then
            field "$C_WARN" "имя в файле" "$host_in_name"
            emit_c "$C_WARN" "  Имя в названии архива и hostname.txt различаются. Берите hostname.txt."
        fi
    fi
    if [[ -n "${PREFIX_NOTE:-}" ]]; then
        prefix_txt=$PREFIX_NOTE
    else
        prefix_txt="(корень архива)"
    fi
    field "$DIM" "префикс" "$prefix_txt"
}

print_host() {
    local ip
    section "$C_HOST" "Хост" "$SUFFIX_HOSTNAME"
    if [[ ! -f "${FILE_HOSTNAME:-}" ]]; then
        emit "  Файл не найден."
    else
        if (( HOST_HAS_FQDN )); then
            field "$C_HOST" "hostname" "$HOST_NAME" "$BOLD"
        else
            field "$C_HOST" "hostname" "${HOST_NAME:-—}" "${BOLD}${C_BAD}"
            emit_c "$C_BAD" "  FQDN не задан"
        fi
    fi
    if [[ ${#HOST_IP[@]} -eq 0 ]]; then
        field "$C_HOST" "IPv4" "не найден"
    else
        for ip in "${HOST_IP[@]}"; do
            field "$C_HOST" "IPv4" "$ip"
        done
    fi
    field "$C_HOST" "uptime" "${HOST_UPTIME:-не найден}"
    field "$C_HOST" "пояс" "${HOST_TZ:-не найден}"
    field "$C_HOST" "ОС" "$HOST_OS"
    field "$C_HOST" "ядро" "$HOST_KERNEL"
    emit ""
    emit_mem_cpu
}

disk_load_row() {
    local i="$1"
    mnt=${disk_mnt[$i]}
    dev=${disk_dev[$i]:-—}
    [[ -n "$dev" && "$dev" != "?" ]] || dev="—"
    fs=${disk_fs[$i]:-—}
    [[ -n "$fs" && "$fs" != "?" ]] || fs="—"
    used=${disk_used[$i]:-—}
    avail=${disk_avail[$i]:-—}
    size=${disk_size[$i]:-—}
    [[ -n "$used" ]] || used="—"
    [[ -n "$avail" ]] || avail="—"
    [[ -n "$size" ]] || size="—"
    pair=$(size_ratio "$used" "$size")
    free=""
    if [[ "$avail" != "—" && -n "$avail" ]]; then
        free="free $(size_phrase "$avail")"
    fi
    pct=""
    if [[ "${disk_pct[$i]:-}" =~ ^[0-9]+([.][0-9]+)?%?$ ]]; then
        pct=${disk_pct[$i]%%%}
        pct=${pct%.*}
    fi
}

disk_measure() {
    DISK_W_DEV=1 DISK_W_MNT=1 DISK_W_FS=1 DISK_W_PAIR=1
    DISK_W_AVAIL=1 DISK_W_USED=1 DISK_W_SIZE=1
    local i n
    [[ ${#disk_mnt[@]} -gt 0 ]] || return 0
    for i in "${!disk_mnt[@]}"; do
        disk_load_row "$i"
        n=$(char_len "$dev")
        if (( n > DISK_W_DEV )); then DISK_W_DEV=$n; fi
        n=$(char_len "$mnt")
        if (( n > DISK_W_MNT )); then DISK_W_MNT=$n; fi
        n=$(char_len "$fs")
        if (( n > DISK_W_FS )); then DISK_W_FS=$n; fi
        n=$(char_len "$pair")
        if (( n > DISK_W_PAIR )); then DISK_W_PAIR=$n; fi
        n=$(char_len "$avail")
        if (( n > DISK_W_AVAIL )); then DISK_W_AVAIL=$n; fi
        n=$(char_len "$used")
        if (( n > DISK_W_USED )); then DISK_W_USED=$n; fi
        n=$(char_len "$size")
        if (( n > DISK_W_SIZE )); then DISK_W_SIZE=$n; fi
    done
}

emit_disk_rows() {
    local i mnt dev fs used avail size pair free pct tag plain colored
    local dev_f mnt_f fs_f avail_f used_f size_f
    if [[ ${#disk_mnt[@]} -eq 0 ]]; then
        emit "  дисковые точки не распознаны"
        return 0
    fi
    disk_measure
    for i in "${!disk_mnt[@]}"; do
        disk_load_row "$i"
        tag=""
        if [[ "$mnt" == "/kuma" || "$mnt" == /opt/kaspersky || "$mnt" == /opt/kaspersky/* ]]; then
            tag="   данные KUMA"
        fi
        dev_f=$(pad "$dev" "$DISK_W_DEV")
        mnt_f=$(pad "$mnt" "$DISK_W_MNT")
        fs_f=$(pad "$fs" "$DISK_W_FS")
        avail_f=$(pad "$avail" "$DISK_W_AVAIL")
        used_f=$(pad "$used" "$DISK_W_USED")
        size_f=$(pad "$size" "$DISK_W_SIZE")
        plain=$(printf '  %s  %s  %s  свободно %s  занято %s  всего %s%s' \
            "$dev_f" "$mnt_f" "$fs_f" "$avail_f" "$used_f" "$size_f" "$tag")
        colored=$plain
        if (( USE_COLOR )); then
            colored=$(printf '  %s%s%s  %s%s%s  %s%s%s  свободно %s  занято %s  всего %s%s%s%s' \
                "$C_TEXT" "$dev_f" "$RST" "$C_DISK" "$mnt_f" "$RST" "$C_HOST" "$fs_f" "$RST" \
                "$avail_f" "$used_f" "$size_f" "$BOLD$C_DISK" "$tag" "$RST")
        fi
        view_put "$plain" "$colored"
    done
}

print_version() {
    emit ""
    if [[ ${#VER_LINES[@]} -eq 0 ]]; then
        emit_c "$C_BAD" "  версия бинаря KUMA - не найдена"
        return
    fi
    emit_c "${BOLD}${C_VER}" "  версия бинаря KUMA - ${VER_LINES[0]}"
    local i
    if [[ ${#VER_LINES[@]} -gt 1 ]]; then
        for ((i = 1; i < ${#VER_LINES[@]}; i++)); do
            emit "    ${VER_LINES[$i]}"
        done
    fi
}

print_disks() {
    section "$C_DISK" "Диски" "$SUFFIX_HDD"
    if [[ ! -f "${FILE_HDD:-}" ]]; then
        emit "  Файл не найден."
        return
    fi
    emit "  По каждой дисковой точке: устройство, тип ФС, свободно, занято, всего. proc, sysfs, tmpfs и snap не показаны. nfs, cifs и S3 показаны."
    emit ""
    emit_disk_rows
}

kesl_is_status() {
    local v="${1,,}"
    case "$v" in
        "available and "*|unavailable*|disabled|"not supported"*|stopped|running|started) return 0 ;;
        "задача доступна и "*|недоступн*|не\ поддерживается\ лицензией|остановлен*|выключен*) return 0 ;;
    esac
    return 1
}

kesl_is_active() {
    local v="${1,,}"
    case "$v" in
        "available and running"|running|started) return 0 ;;
        "задача доступна и выполняется") return 0 ;;
    esac
    return 1
}

kesl_empty_text() {
    if (( ${KESL_SAW:-0} )); then
        printf '%s' "активных компонентов нет"
    else
        printf '%s' "модули не распознаны"
    fi
}

# Папка KUMA или сам каталог /opt. Чужой файл вроде /opt/kaspersky/klnagent не считается.
kesl_path_covers_kuma() {
    local p="${1,,}"
    p=${p//\\//}
    p=${p#\"}
    p=${p%\"}
    p=${p#\'}
    p=${p%\'}
    p=${p%/}
    [[ -n "$p" && "$p" != "/" && "$p" != "*" ]] || return 1
    local bare=${p%%\*}
    bare=${bare%/}
    [[ "$bare" == "/opt" ]] && return 0
    case "/${p}/" in
        */kuma/*) return 0 ;;
    esac
    return 1
}

kesl_ex_add() {
    local p="$1" have
    p=${p#"${p%%[![:space:]]*}"}
    p=${p%"${p##*[![:space:]]}"}
    p=${p#\"}
    p=${p%\"}
    p=${p#\'}
    p=${p%\'}
    [[ -n "$p" ]] || return 0
    kesl_path_covers_kuma "$p" || return 0
    if (( ${#KESL_EX[@]} )); then
        for have in "${KESL_EX[@]}"; do
            [[ "${have,,}" == "${p,,}" ]] && return 0
        done
    fi
    KESL_EX+=("$p")
}

kesl_ex_flush() {
    local enabled="$1"
    shift
    (( enabled )) || return 0
    local p
    for p in "$@"; do
        kesl_ex_add "$p"
    done
}

load_kesl_exclusions() {
    KESL_EX=()
    KESL_EX_FOUND=0
    local file="$1" line excl=0 enabled=1 key val klow vlow
    local -a pending=()
    [[ -n "$file" && -f "$file" ]] || return 0
    KESL_EX_FOUND=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n "$line" && "$line" != \#* && "$line" != \;* ]] || continue
        if [[ "$line" == \[*\] ]]; then
            if (( excl )); then
                kesl_ex_flush "$enabled" "${pending[@]}"
            fi
            pending=()
            excl=0
            enabled=1
            line=${line#[}
            line=${line%]}
            case "${line,,}" in
                *exclud*|*исключ*) excl=1 ;;
            esac
            continue
        fi
        [[ "$line" == *=* ]] || continue
        key=${line%%=*}
        val=${line#*=}
        key=${key#"${key%%[![:space:]]*}"}
        key=${key%"${key##*[![:space:]]}"}
        val=${val#"${val%%[![:space:]]*}"}
        val=${val%"${val##*[![:space:]]}"}
        klow=${key,,}
        vlow=${val,,}
        if (( excl )); then
            case "$klow" in
                use*|enabled|active)
                    case "$vlow" in
                        no|false|0|off|выкл|нет) enabled=0 ;;
                    esac
                    ;;
                path|mountpoint|programpath|excludemask|excludedpath|folder|mask|путь|*exclud*|*исключ*)
                    case "$vlow" in
                        yes|no|true|false|0|1|on|off|да|нет|"*"|"/") ;;
                        *) pending+=("$val") ;;
                    esac
                    ;;
            esac
            continue
        fi
        case "$klow" in
            *exclud*|*исключ*)
                case "$vlow" in
                    yes|no|true|false|0|1|on|off|да|нет|"*"|"/") ;;
                    *) kesl_ex_add "$val" ;;
                esac
                ;;
        esac
    done < "$file"
    if (( excl )); then
        kesl_ex_flush "$enabled" "${pending[@]}"
    fi
}

kesl_status_color() {
    local v="${1,,}"
    case "$v" in
        "available and running"|running|started) printf '%s' "$C_OK" ;;
        "задача доступна и выполняется") printf '%s' "$C_OK" ;;
        "available and stopped"|stopped|disabled) printf '%s' "$C_WARN" ;;
        "задача доступна и не выполняется"|остановлен*|выключен*) printf '%s' "$C_WARN" ;;
        *) printf '%s' "$C_BAD" ;;
    esac
}

load_kesl() {
    KESL_NAME=()
    KESL_STATUS=()
    KESL_PRESENT=0
    KESL_SAW=0
    local file="$1" line key val
    [[ -n "$file" && -f "$file" ]] || return 0
    KESL_PRESENT=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ "$line" == *:* ]] || continue
        key=${line%%:*}
        val=${line#*:}
        key=${key#"${key%%[![:space:]]*}"}
        key=${key%"${key##*[![:space:]]}"}
        val=${val#"${val%%[![:space:]]*}"}
        val=${val%"${val##*[![:space:]]}"}
        [[ -n "$key" && -n "$val" ]] || continue
        kesl_is_status "$val" || continue
        KESL_SAW=1
        kesl_is_active "$val" || continue
        KESL_NAME+=("$key")
        KESL_STATUS+=("$val")
    done < "$file"
}

print_kesl() {
    (( ${KESL_PRESENT:-0} )) || return 0
    local i color plain colored
    section "$C_SVC" "KESL" "$SUFFIX_KESL"
    emit "  Активные компоненты из appinfo.txt."
    emit ""
    if [[ ${#KESL_NAME[@]} -eq 0 ]]; then
        emit "  $(kesl_empty_text)."
    else
    for i in "${!KESL_NAME[@]}"; do
        color=$(kesl_status_color "${KESL_STATUS[$i]}")
        plain=$(printf '  %s  %s' "${KESL_NAME[$i]}" "${KESL_STATUS[$i]}")
        colored=$plain
        if (( USE_COLOR )); then
            colored=$(printf '  %s%s%s  %s%s%s' \
                "$C_TEXT" "${KESL_NAME[$i]}" "$RST" \
                "$color" "${KESL_STATUS[$i]}" "$RST")
        fi
        view_put "$plain" "$colored"
    done
    fi
    emit ""
    if (( ${#KESL_EX[@]} )); then
        emit_c "$C_OK" "  исключения для KUMA добавлены"
        for i in "${KESL_EX[@]}"; do
            emit_c "$C_OK" "    $i"
        done
    else
        emit_c "$C_BAD" "  исключения для KUMA не добавлены"
        if (( ! ${KESL_EX_FOUND:-0} )); then
            emit "  файл исключений не найден (exset.txt или expset.txt)"
        fi
    fi
}

print_services() {
    section "$C_SVC" "Службы KUMA" "$SUFFIX_SERVICES"
    emit "  Берутся только заголовки systemctl status из services.txt. Строки журнала под блоком службой не считаются."
    emit ""
    if [[ ! -f "${FILE_SERVICES:-}" ]]; then
        emit "  Файл не найден."
        return
    fi
    if [[ ${#svc_unit[@]} -eq 0 ]]; then
        emit "  Службы не распознаны. Формат services.txt изменился или файл пуст."
        return
    fi
    local idx role title state sc pid boot age running=0
    while IFS= read -r idx; do
        role=${svc_role[$idx]}
        [[ -n "$role" ]] || role=${svc_unit[$idx]}
        title="$role"
        [[ -n "${svc_desc[$idx]}" ]] && title="$role   ${svc_desc[$idx]}"
        emit_c "${BOLD}${C_SVC}" "  $title"
        field "$C_SVC" "ID" "$([[ -n ${svc_id[$idx]} ]] && printf '%s' "${svc_id[$idx]}" || printf '%s' "не распознан")"
        state=${svc_state[$idx]}
        sc=$(status_color "$state")
        field "$C_SVC" "статус" "${state:-—}" "$sc$BOLD"
        age=$(svc_age "${svc_since[$idx]}")
        if [[ -n "$age" ]]; then
            field "$C_SVC" "uptime" "$age"
        fi
        [[ -n "${svc_since[$idx]}" ]] && field "$C_SVC" "с" "${svc_since[$idx]}"
        pid=${svc_pid[$idx]}
        field "$C_SVC" "PID" "${pid:-нет}"
        boot=${svc_boot[$idx]}
        field "$C_SVC" "автозапуск" "${boot:-не указан}"
        field "$C_SVC" "юнит" "${svc_unit[$idx]}"
        emit ""
        [[ "$state" == *running* ]] && running=$((running + 1))
    done < <(sorted_service_indexes)
    emit "  Итого служб: ${#svc_unit[@]}, из них running: ${running}."
}

tty_ok() { [[ -r /dev/tty && -w /dev/tty ]]; }

have_gawk() {
    local ver
    command -v awk >/dev/null || return 1
    ver=$(awk --version 2>/dev/null || true)
    [[ "$ver" == *GNU* ]]
}

ensure_logs() {
    (( LOGS_READY )) && return 0
    if [[ "${LOGS_FAILED:-0}" -eq 1 ]]; then return 1; fi
    if [[ "$IS_DIR" -eq 1 ]]; then
        if [[ -z "${LOGS_TAR:-}" || ! -f "$LOGS_TAR" ]]; then
            emit "  logs.tar не найден. Разобрать логи нельзя."
            LOGS_FAILED=1
            return 1
        fi
    else
        debug_stage "логи"
        progress "Читаю только папку выбранной службы. Чужие логи не разбираю."
        dbg "сырые логи на диск не пишутся, сохраняется только готовый отчёт"
    fi
    LOGS_READY=1
}

render_log_protocol() {
    local file="$1" tag c1 c2 c3 c4 c5 c6 c7 c8 c9 n=0 lc plain colored
    # Разделитель — не пробел: пустая причина или назначение не должны схлопываться.
    while IFS=$'\036' read -r tag c1 c2 c3 c4 c5 c6 c7 c8 c9 || [[ -n "${tag:-}" ]]; do
        [[ -n "${tag:-}" ]] || continue
        case "$tag" in
            STAT)
                local begin="$c9"
                [[ -n "$begin" ]] || begin="$c6"
                emit "  лог начинается:     ${begin:-неизвестно}"
                emit "  лог заканчивается:  ${c7:-неизвестно}"
                emit "  сгруппировано за:   ${c6:-?}  ..  ${c7:-?}"
                case "${LOG_VIEW:-all}" in
                    error) emit "  это последние 10% лога. Показаны только ошибки." ;;
                    debug) emit "  это последние 10% лога. Показан только debug." ;;
                    *) emit "  это последние 10% лога. Показаны все уровни: info, warn, debug, error." ;;
                esac
                emit "  событий в этом куске: ${c2}"
                emit ""
                ;;
            ITEM)
                level_wanted "$c2" || continue
                n=$((n + 1))
                if (( n > 2000 )); then
                    emit "  Показаны первые 2000 групп. Остальные не выводятся, чтобы список не занял всю память."
                    emit ""
                    break
                fi
                lc=$(level_color "$c2")
                plain=$(printf '  %2d. %6s×  [%s]  %s' "$n" "$c1" "$c2" "$c3")
                if (( USE_COLOR )); then
                    colored=$(printf '  %s%2d.%s %s%6s×%s  [%s%s%s]  %s' \
                        "$BOLD" "$n" "$RST" "$BOLD" "$c1" "$RST" "$lc" "$c2" "$RST" "$c3")
                else
                    colored=$plain
                fi
                view_put "$plain" "$colored"
                [[ -n "$c4" ]] && emit "      $c4"
                if [[ -n "$c7" ]]; then
                    emit "      ${c7}"
                fi
                emit ""
                ;;
            MORE)
                if [[ "${AWK_TOP:-}" == "all" ]]; then
                    plain="  Показаны первые 2000 групп. Ещё ${c1} не выводятся."
                else
                    plain="  Показаны первые ${TOP} $(groups_word "$TOP") из $((TOP + c1)). Остальные в этот отчёт не вошли. Чтобы напечатать все, запустите с --top $((TOP + c1))."
                fi
                [[ "${LOG_VIEW:-all}" == "all" ]] || continue
                emit "$plain"
                emit ""
                ;;
        esac
    done < "$file"
    if (( n == 0 )); then
        emit "  В этом куске таких строк нет."
        emit ""
    fi
}

# Живой процесс, не зомби. kill -0 на зомби тоже успешен и вечный цикл не кончается.
proc_alive() {
    local pid="$1" stat=""
    [[ -n "$pid" && -r "/proc/${pid}/stat" ]] || return 1
    stat=$(awk '{print $3}' "/proc/${pid}/stat" 2>/dev/null || true)
    [[ -n "$stat" && "$stat" != "Z" ]]
}

analyze_service() {
    local idx="$1" role id proto needle use_top src py_rc aw_rc stage last aw py
    role=${svc_role[$idx]}
    id=${svc_id[$idx]}
    ensure_logs || return 0
    emit ""
    emit_c "${BOLD}${C_LOG}" "  ${role:-служба}    ${id:-без id}"
    if [[ -z "$role" || -z "$id" ]]; then
        emit "  У службы нет роли или ID, файл лога не выбрать."
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        emit "  Нужен python3, чтобы читать лог из архива."
        return 0
    fi
    proto="$work/proto-${role}-${id}.txt"
    if [[ -f "$proto.ok" ]]; then
        debug_stage "отчёт ${role}/${id}"
        emit "  отчёт уже посчитан, архив не читается"
        render_log_protocol "$proto"
        return 0
    fi
    # Лог всегда в папке своей роли: collector/<id>/log/, не в core и не в чужом id.
    needle="/kuma/${role}/${id}/log/"
    use_top="${AWK_TOP:-$TOP}"
    debug_stage "поток ${role}/${id}"
    emit "  читаю только ${role}/${id}/log/"
    progress "проматываю до ${role}/${id}"
    rm -f "$proto" "$work/pass-stage" "$work/extract-err.txt"
    if [[ "$IS_DIR" -eq 1 ]]; then
        src=(--archive "$LOGS_TAR")
    else
        src=(--archive "$ARCHIVE" --outer "kaspersky/KUMA/logs.tar")
    fi
    PASS_CANCEL=0
    py=""
    aw=""
    LOG_PY=""
    LOG_AW=""
    rm -f "$work/log.pipe" "$work/tick.pipe"
    mkfifo "$work/log.pipe"
    mkfifo "$work/tick.pipe"
    # Оба конца держим открытыми, чтобы read -t ждал секунду, а не конец файла.
    # read — встроенная команда: Ctrl+C во время неё не закрывает весь скрипт, в отличие от sleep.
    exec 7<>"$work/tick.pipe"
    local cfg_args=()
    if [[ "$role" == "collector" ]]; then
        rm -rf "$work/cfg-${id}"
        cfg_args=(--config-out "$work/cfg-${id}")
    fi
    python3 "$EXTRACT_PROG" "${src[@]}" --needle "$needle" --label "${role}/${id}" --stage "$work/pass-stage" \
        "${cfg_args[@]}" \
        >"$work/log.pipe" 2>"$work/extract-err.txt" &
    py=$!
    LOG_PY=$py
    LC_ALL=C awk -v "TOP=${use_top}" -v "INCLUDE_WARN=${INCLUDE_WARN}" -v "ROLE=${role}" -f "$AWK_PROG" <"$work/log.pipe" >"$proto" 2>>"$work/extract-err.txt" &
    aw=$!
    LOG_AW=$aw
    trap 'PASS_CANCEL=1; [[ -n "${LOG_PY:-}" ]] && kill "$LOG_PY" 2>/dev/null || true; [[ -n "${LOG_AW:-}" ]] && kill "$LOG_AW" 2>/dev/null || true' INT TERM
    stage=""
    last=""
    while proc_alive "$aw" || proc_alive "$py"; do
        if (( PASS_CANCEL == 1 )); then
            break
        fi
        stage=$(cat "$work/pass-stage" 2>/dev/null || true)
        if [[ -n "$stage" && "$stage" != "$last" ]]; then
            last=$stage
            progress "$stage"
            debug_stage "$stage"
        fi
        read -t 1 -u 7 || true
    done
    trap on_stop INT TERM
    exec 7<&- || true
    rm -f "$work/tick.pipe"
    py_rc=0
    aw_rc=0
    wait "$py" 2>/dev/null || py_rc=$?
    wait "$aw" 2>/dev/null || aw_rc=$?
    rm -f "$work/log.pipe"
    if (( PASS_CANCEL == 1 )); then
        rm -f "$proto" "$proto.ok"
        emit "  Подсчёт прерван."
        return 0
    fi
    if [[ -s "$work/extract-err.txt" ]]; then
        dbg "extract $(tr '\n' ' ' < "$work/extract-err.txt")"
    fi
    if (( py_rc == 2 )); then
        rm -f "$proto" "$proto.ok"
        emit "  В архиве нет ${role}/${id}/log/."
        return 0
    fi
    if (( py_rc != 0 || aw_rc != 0 )) || [[ ! -s "$proto" ]]; then
        rm -f "$proto" "$proto.ok"
        emit "  Этот лог разобрать не удалось. Остальные службы на месте."
        return 0
    fi
    : >"$proto.ok"
    debug_stage "отчёт ${role}/${id}"
    render_log_protocol "$proto"
}

service_wanted() {
    local role="$1"
    [[ "$LOGS_MODE" == "all" ]] && return 0
    [[ "$LOGS_MODE" == "ask" || "$LOGS_MODE" == "none" ]] && return 1
    local item
    IFS=',' read -r -a _parts <<<"$LOGS_MODE"
    for item in "${_parts[@]}"; do
        item=${item//[[:space:]]/}
        [[ "$item" == "$role" ]] && return 0
    done
    return 1
}

print_skipped_logs() {
    (( LOGS_READY )) || return 0
    [[ ${#skipped_logs[@]} -eq 0 ]] && return 0
    emit "  Файлы в logs.tar вне маски opt/kaspersky/kuma/<роль>/<id>/log/:"
    local rel i=0
    for rel in "${skipped_logs[@]}"; do
        i=$((i + 1))
        (( i > 20 )) && break
        emit "    $rel"
    done
    if [[ ${#skipped_logs[@]} -gt 20 ]]; then
        emit "    … и ещё $((${#skipped_logs[@]} - 20))"
    fi
}

run_logs() {
    section "$C_LOG" "Логи служб KUMA" "$SUFFIX_LOGS"
    emit "  В группы хвоста входят все уровни: info, warn, debug, error и остальные."
    emit "  Берутся последние 10% лога. Стеки горутин и версии не показываются."
    emit "  Одинаковый текст после замены UUID и URL склеивается в одну строку. IP и числа остаются."
    emit ""
    if [[ ! -f "$AWK_PROG" ]]; then
        emit "  Нет файла разбора логов: $AWK_PROG"
        return
    fi
    if [[ ${#svc_unit[@]} -eq 0 ]]; then
        emit "  Служб нет — разбирать нечего."
        return
    fi

    local idx
    if [[ "$LOGS_MODE" == "none" ]]; then
        emit "  Разбор логов пропущен (--logs none)."
        return
    fi
    if [[ "$LOGS_MODE" == "ask" ]]; then
        emit "  Логи не разбирались: нет терминала для меню."
        emit "  Запустите снова в терминале или передайте --logs all либо --logs core,collector"
        return
    fi
    have_gawk || die "для логов нужен GNU awk (gawk)"
    while IFS= read -r idx; do
        service_wanted "${svc_role[$idx]}" || continue
        analyze_service "$idx"
    done < <(sorted_service_indexes)
    print_skipped_logs
}

screen_clear() {
    if (( USE_COLOR )) && [[ -n "$BG_BASE" ]]; then
        printf '%s\033[H\033[2J\033[3J' "$BG_BASE" >/dev/tty
    else
        printf '\033[H\033[2J\033[3J' >/dev/tty
    fi
}

enter_ui() {
    if tput smcup >/dev/tty 2>/dev/null; then
        UI_ALT=1
    fi
    if (( USE_COLOR )); then
        BG_BASE=$'\033[48;2;11;15;20m'
        BG_ROW=$'\033[48;2;22;29;38m'
        RST=$'\033[0m\033[38;2;213;222;232m\033[48;2;11;15;20m'
        printf '\033]10;#D5DEE8\007\033]11;#0B0F14\007' >/dev/tty
    fi
    screen_clear
}

read_choice() {
    local ans=""
    printf '%b  > %b' "${BOLD}${C_ASK}" "$RST" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    ans=${ans#"${ans%%[![:space:]]*}"}
    ans=${ans%"${ans##*[![:space:]]}"}
    printf '%s' "$ans"
}

fill_role_menu() {
    ROLE_MENU=()
    local seen="" idx role
    while IFS= read -r idx; do
        role=${svc_role[$idx]}
        [[ -n "$role" ]] || role="прочее"
        case ",${seen}," in
            *",${role},"*) continue ;;
        esac
        seen+="${seen:+,}${role}"
        ROLE_MENU+=("$role")
    done < <(sorted_service_indexes)
}

role_count() {
    local want="$1" idx n=0 role
    for idx in "${!svc_role[@]}"; do
        role=${svc_role[$idx]}
        [[ -n "$role" ]] || role="прочее"
        [[ "$role" == "$want" ]] && n=$((n + 1))
    done
    printf '%s' "$n"
    return 0
}

indexes_for_role() {
    local want="$1" idx role
    while IFS= read -r idx; do
        role=${svc_role[$idx]}
        [[ -n "$role" ]] || role="прочее"
        [[ "$role" == "$want" ]] && printf '%s\n' "$idx"
    done < <(sorted_service_indexes)
}

clip_vis() {
    local s="$1" max="$2" n
    n=$(char_len "$s")
    if (( n <= max )); then
        printf '%s' "$s"
        return
    fi
    if (( max <= 1 )); then
        printf '…'
        return
    fi
    printf '%s…' "${s:0:max-1}"
}

size_unit() {
    case "$1" in
        k) printf KB ;;
        m) printf MB ;;
        g) printf GB ;;
        t) printf TB ;;
        *) printf '%s' "$1" ;;
    esac
}

size_ratio() {
    local used="$1" size="$2" un uu sn su
    if [[ ! "$used" =~ ^([0-9]+([.][0-9]+)?)([KkMmGgTt])$ ]]; then
        printf '%s / %s' "$used" "$size"
        return
    fi
    un=${BASH_REMATCH[1]}
    uu=${BASH_REMATCH[3],,}
    if [[ ! "$size" =~ ^([0-9]+([.][0-9]+)?)([KkMmGgTt])$ ]]; then
        printf '%s / %s' "$used" "$size"
        return
    fi
    sn=${BASH_REMATCH[1]}
    su=${BASH_REMATCH[3],,}
    if [[ "$uu" == "$su" ]]; then
        printf '%s / %s %s' "$un" "$sn" "$(size_unit "$uu")"
    else
        printf '%s %s / %s %s' "$un" "$(size_unit "$uu")" "$sn" "$(size_unit "$su")"
    fi
}

size_phrase() {
    local raw="$1" n u
    if [[ "$raw" =~ ^([0-9]+([.][0-9]+)?)([KkMmGgTt])$ ]]; then
        n=${BASH_REMATCH[1]}
        printf '%s %s' "$n" "$(size_unit "${BASH_REMATCH[3],,}")"
        return
    fi
    printf '%s' "$raw"
}

mount_label() {
    case "$1" in
        /) printf ROOT ;;
        /boot) printf BOOT ;;
        /kuma|/opt/kaspersky) printf KUMA ;;
        *) printf '%s' "$1" ;;
    esac
}

mib_of() {
    awk -v n="$1" -v u="$2" 'BEGIN {
        if (u == "ГБ") printf "%.4f", n * 1024
        else if (u == "ТБ") printf "%.4f", n * 1024 * 1024
        else printf "%.4f", n + 0
    }'
}

mem_amount() {
    local n="$1" u="$2" name
    name=$u
    case "$u" in
        ГБ) name=GB ;;
        МиБ) name=MB ;;
        ТБ) name=TB ;;
    esac
    printf '%s %s' "$n" "$name"
}

mem_card() {
    MEM_PAIR=""
    MEM_FREE=""
    MEM_PCT=""
    local text="${HOST_MEM_TEXT:-}" tn tu un uu an au name um tm
    [[ "$text" =~ всего[[:space:]]+([0-9]+([.][0-9]+)?)[[:space:]]+(ГБ|МиБ|ТБ) ]] || return 1
    tn=${BASH_REMATCH[1]}
    tu=${BASH_REMATCH[3]}
    [[ "$text" =~ занято[[:space:]]+([0-9]+([.][0-9]+)?)[[:space:]]+(ГБ|МиБ|ТБ) ]] || return 1
    un=${BASH_REMATCH[1]}
    uu=${BASH_REMATCH[3]}
    if [[ "$uu" == "$tu" ]]; then
        case "$tu" in
            ГБ) name=GB ;;
            МиБ) name=MB ;;
            ТБ) name=TB ;;
        esac
        MEM_PAIR="${un} / ${tn} ${name}"
    else
        MEM_PAIR="$(mem_amount "$un" "$uu") / $(mem_amount "$tn" "$tu")"
    fi
    if [[ "$text" =~ доступно[[:space:]]+([0-9]+([.][0-9]+)?)[[:space:]]+(ГБ|МиБ|ТБ) ]]; then
        an=${BASH_REMATCH[1]}
        au=${BASH_REMATCH[3]}
        MEM_FREE="free $(mem_amount "$an" "$au")"
    elif [[ "$text" =~ свободно[[:space:]]+([0-9]+([.][0-9]+)?)[[:space:]]+(ГБ|МиБ|ТБ) ]]; then
        an=${BASH_REMATCH[1]}
        au=${BASH_REMATCH[3]}
        MEM_FREE="free $(mem_amount "$an" "$au")"
    fi
    um=$(mib_of "$un" "$uu")
    tm=$(mib_of "$tn" "$tu")
    MEM_PCT=$(awk -v u="$um" -v t="$tm" 'BEGIN { if (t + 0 <= 0) print ""; else printf "%d", (u / t) * 100 }')
}

cpu_short() {
    local m="$1"
    m=${m//(R)/}
    m=${m//(TM)/}
    m=${m// CPU/}
    m=${m%% @*}
    m=${m//  / }
    m=${m#"${m%%[![:space:]]*}"}
    m=${m%"${m##*[![:space:]]}"}
    printf '%s' "$m"
}

svc_word() {
    local s="${1,,}"
    if [[ "$s" == *running* ]]; then printf RUNNING
    elif [[ "$s" == *failed* ]]; then printf FAILED
    elif [[ "$s" == *dead* ]]; then printf DEAD
    elif [[ "$s" == *inactive* ]]; then printf STOPPED
    elif [[ "$s" == *exited* ]]; then printf EXITED
    else printf '%s' "$1"
    fi
}

box_emit() {
    local plain="$1" colored="$2" mark="${3:-0}"
    local vis pad spaces p c
    vis=$(char_len "$plain")
    pad=$((BOX_IN - vis))
    if (( pad < 0 )); then
        pad=0
    fi
    spaces=$(printf '%*s' "$pad" "")
    p="│${plain}${spaces}│"
    if (( USE_COLOR )); then
        if [[ "$mark" == "1" ]]; then
            c=$(printf '%s│%s%s%s%s%s%s%s│%s' \
                "$DIM" "$RST" "$BG_ROW" "$C_HOST" "$plain" "$spaces" "$RST" "$DIM" "$RST")
        else
            c=$(printf '%s│%s%s%s%s%s│%s' \
                "$DIM" "$RST" "$colored" "$spaces" "$DIM" "$RST")
        fi
    else
        c=$p
    fi
    view_put "$p" "$c"
}

box_banner() {
    local left="$1" right="$2" title="$3"
    local tlen dash_n dashes plain colored
    tlen=$(char_len "$title")
    dash_n=$((BOX_IN - tlen - 3))
    if (( dash_n < 1 )); then
        title=$(clip_vis "$title" $((BOX_IN - 4)))
        tlen=$(char_len "$title")
        dash_n=$((BOX_IN - tlen - 3))
    fi
    if (( dash_n < 1 )); then
        dash_n=1
    fi
    dashes=$(rule "$dash_n")
    plain="${left}─ ${title} ${dashes}${right}"
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '%s%s─ %s%s%s%s%s %s%s%s' \
            "$DIM" "$left" \
            "$RST" "${BOLD}${C_HOST}" "$title" "$RST" "$DIM" \
            "$dashes" "$right" "$RST")
    fi
    view_put "$plain" "$colored"
}

box_bottom() {
    local plain="╰$(rule "$BOX_IN")╯" colored
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '%s%s%s' "$DIM" "$plain" "$RST")
    fi
    view_put "$plain" "$colored"
}

home_kv() {
    local label="$1" value="$2" vcolor="${3:-$C_TEXT}"
    local lab room plain colored
    lab=$(pad "$label" 11)
    room=$((BOX_IN - 14))
    if (( room < 1 )); then
        room=1
    fi
    value=$(clip_vis "$value" "$room")
    plain="  ${lab} ${value}"
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '  %s%s%s %s%s%s' "$DIM" "$lab" "$RST" "$vcolor" "$value" "$RST")
    fi
    box_emit "$plain" "$colored" 0
}

home_metric() {
    local label="$1" value="$2" vcolor="$3" tail="${4:-}"
    local lab plain colored
    lab=$(pad "$label" 11)
    if [[ -n "$tail" ]]; then
        plain="  ${lab} ${value}  ${tail}"
    else
        plain="  ${lab} ${value}"
    fi
    if (( $(char_len "$plain") > BOX_IN )); then
        plain=$(clip_vis "$plain" "$BOX_IN")
        colored=$plain
        if (( USE_COLOR )); then
            colored="${vcolor}${plain}${RST}"
        fi
        box_emit "$plain" "$colored" 0
        return
    fi
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '  %s%s%s %s%s%s' "$DIM" "$lab" "$RST" "$vcolor" "$value" "$RST")
        if [[ -n "$tail" ]]; then
            colored+=$(printf '  %s%s%s' "$DIM" "$tail" "$RST")
        fi
    fi
    box_emit "$plain" "$colored" 0
}

home_meter() {
    local label="$1" pair="$2" pct="$3" extra="${4:-}" fs="${5:-}"
    local lab fs_show="" room pair_show bar="" bar_f="" bar_e="" filled=0 i
    local pcolor="$C_TEXT" bar_col="$C_OK" need use_bar=0 use_extra=0
    local plain colored prefix
    if [[ "$pct" =~ ^[0-9]+$ ]]; then
        if (( pct >= 90 )); then
            pcolor="$C_BAD"
            bar_col="$C_BAD"
        elif (( pct >= 75 )); then
            pcolor="$C_WARN"
            bar_col="$C_WARN"
        fi
        filled=$(( (pct * 10 + 50) / 100 ))
        if (( pct > 0 && filled == 0 )); then
            filled=1
        fi
        if (( filled > 10 )); then
            filled=10
        fi
        for ((i = 0; i < filled; i++)); do bar_f+="█"; done
        for ((i = filled; i < 10; i++)); do bar_e+="░"; done
        bar="[${bar_f}${bar_e}]"
    fi
    lab=$(pad "$label" 11)
    prefix="  ${lab}"
    if [[ -n "$fs" && "$fs" != "?" ]]; then
        fs_show=$(pad "$fs" 8)
        prefix+=" ${fs_show}"
    fi
    room=$((BOX_IN - $(char_len "$prefix") - 1))
    if (( room < 8 )); then
        room=8
    fi
    pair_show=$(pad "$pair" 16)
    need=$(char_len "$pair_show")
    if [[ -n "$bar" ]] && (( need + 14 <= room )); then
        use_bar=1
        need=$((need + 14))
    fi
    if [[ -n "$extra" ]] && (( need + 2 + $(char_len "$extra") <= room )); then
        use_extra=1
    fi
    plain="${prefix} ${pair_show}"
    if (( use_bar )); then
        plain+="  ${bar}"
    fi
    if (( use_extra )); then
        plain+="  ${extra}"
    fi
    if (( $(char_len "$plain") > BOX_IN )); then
        pair_show=$(clip_vis "$pair" "$room")
        plain="${prefix} ${pair_show}"
        use_bar=0
        use_extra=0
    fi
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '  %s%s%s' "$DIM" "$lab" "$RST")
        if [[ -n "$fs_show" ]]; then
            colored+=$(printf ' %s%s%s' "$C_HOST" "$fs_show" "$RST")
        fi
        colored+=$(printf ' %s%s%s' "$pcolor" "$pair_show" "$RST")
        if (( use_bar )); then
            colored+=$(printf '  %s[%s%s%s%s%s]%s' "$DIM" "$RST" "$bar_col" "$bar_f" "$DIM" "$bar_e" "$RST")
        fi
        if (( use_extra )); then
            colored+=$(printf '  %s%s%s' "$DIM" "$extra" "$RST")
        fi
    fi
    box_emit "$plain" "$colored" 0
}

disk_bar() {
    local pct="$1" filled=0 i
    DISK_BAR=""
    DISK_BAR_F=""
    DISK_BAR_E=""
    [[ "$pct" =~ ^[0-9]+$ ]] || return 0
    filled=$(( (pct * 10 + 50) / 100 ))
    if (( pct > 0 && filled == 0 )); then
        filled=1
    fi
    if (( filled > 10 )); then
        filled=10
    fi
    for ((i = 0; i < filled; i++)); do DISK_BAR_F+="█"; done
    for ((i = filled; i < 10; i++)); do DISK_BAR_E+="░"; done
    DISK_BAR="[${DISK_BAR_F}${DISK_BAR_E}]"
    printf '%s' "$DISK_BAR"
}

disk_row_text() {
    local dev_f mnt_f fs_f pair_f bar text
    dev_f=$(pad "$1" "${DISK_W_DEV:-1}")
    mnt_f=$(pad "$2" "${DISK_W_MNT:-1}")
    fs_f=$(pad "$3" "${DISK_W_FS:-1}")
    pair_f=$(pad "$4" "${DISK_W_PAIR:-1}")
    bar=$(disk_bar "$5")
    [[ -n "$bar" ]] || bar="            "
    text="  ${dev_f}  ${mnt_f}  ${fs_f}  ${pair_f}  ${bar}"
    [[ -n "${6:-}" ]] && text+="  ${6}"
    printf '%s' "$text"
}

home_disk() {
    local dev="$1" mnt="$2" fs="$3" pair="$4" pct="$5" free="${6:-}"
    local pcolor="$C_TEXT" bar_col="$C_OK" plain colored
    local dev_f mnt_f fs_f pair_f
    disk_bar "$pct" >/dev/null
    if [[ "$pct" =~ ^[0-9]+$ ]]; then
        if (( pct >= 90 )); then
            pcolor="$C_BAD"
            bar_col="$C_BAD"
        elif (( pct >= 75 )); then
            pcolor="$C_WARN"
            bar_col="$C_WARN"
        fi
    fi
    dev_f=$(pad "$dev" "${DISK_W_DEV:-1}")
    mnt_f=$(pad "$mnt" "${DISK_W_MNT:-1}")
    fs_f=$(pad "$fs" "${DISK_W_FS:-1}")
    pair_f=$(pad "$pair" "${DISK_W_PAIR:-1}")
    plain=$(disk_row_text "$dev" "$mnt" "$fs" "$pair" "$pct" "$free")
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '  %s%s%s  %s%s%s  %s%s%s  %s%s%s  ' \
            "$C_TEXT" "$dev_f" "$RST" \
            "$C_DISK" "$mnt_f" "$RST" \
            "$C_HOST" "$fs_f" "$RST" \
            "$pcolor" "$pair_f" "$RST")
        if [[ -n "$DISK_BAR" ]]; then
            colored+=$(printf '%s[%s%s%s%s%s]%s' \
                "$DIM" "$RST" "$bar_col" "$DISK_BAR_F" "$DIM" "$DISK_BAR_E" "$RST")
        else
            colored+="            "
        fi
        if [[ -n "$free" ]]; then
            colored+=$(printf '  %s%s%s' "$DIM" "$free" "$RST")
        fi
    fi
    box_emit "$plain" "$colored" 0
}

home_split() {
    local title="$1" tlen dash_n dashes plain colored
    tlen=$(char_len "$title")
    dash_n=$((BOX_IN - tlen - 6))
    if (( dash_n < 2 )); then
        dash_n=2
    fi
    dashes=$(rule "$dash_n")
    plain=$(printf '  ── %s %s' "$title" "$dashes")
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '  %s── %s%s%s %s%s' \
            "$DIM" "$RST${C_HOST}" "$title" "$RST" "$DIM" "${dashes}${RST}")
    fi
    box_emit "$plain" "$colored" 0
}

service_row_text() {
    local role="$1" state="$2" pid="$3" sid="${4:-}"
    local word role_f state_f pid_f plain
    word=$(svc_word "$state")
    role_f=$(pad "$role" 12)
    state_f=$(pad "$word" 9)
    [[ -n "$pid" ]] || pid="—"
    [[ -n "$sid" ]] || sid="—"
    pid_f=$(pad "$pid" 8)
    plain=$(printf '  ● %s%sPID %s%s' "$role_f" "$state_f" "$pid_f" "$sid")
    printf '%s' "$plain"
}

top_measure() {
    TOP_W_CMD=1
    TOP_W_CPU=1
    TOP_W_MEM=1
    TOP_W_RES=1
    local i n
    [[ ${#TOP_PROC_CMD[@]} -gt 0 ]] || return 0
    for i in "${!TOP_PROC_CMD[@]}"; do
        n=$(char_len "${TOP_PROC_CMD[$i]}")
        if (( n > TOP_W_CMD )); then TOP_W_CMD=$n; fi
        n=$(char_len "${TOP_PROC_CPU[$i]}")
        if (( n > TOP_W_CPU )); then TOP_W_CPU=$n; fi
        n=$(char_len "${TOP_PROC_MEM[$i]}")
        if (( n > TOP_W_MEM )); then TOP_W_MEM=$n; fi
        n=$(char_len "${TOP_PROC_RES[$i]}")
        if (( n > TOP_W_RES )); then TOP_W_RES=$n; fi
    done
}

top_row_text() {
    local cmd_f cpu_f mem_f res_f
    cmd_f=$(pad "$1" "${TOP_W_CMD:-1}")
    cpu_f=$(pad "$2" "${TOP_W_CPU:-1}")
    mem_f=$(pad "$3" "${TOP_W_MEM:-1}")
    res_f=$(pad "$4" "${TOP_W_RES:-1}")
    printf '  %s  CPU %s  RAM %s  %s' "$cmd_f" "$cpu_f" "$mem_f" "$res_f"
}

home_proc() {
    local plain colored wide cmd_f cpu_f mem_f res_f
    plain=$(top_row_text "$1" "$2" "$3" "$4")
    wide=0
    if (( $(char_len "$plain") > BOX_IN )); then
        plain=$(clip_vis "$plain" "$BOX_IN")
        wide=1
    fi
    colored=$plain
    if (( USE_COLOR )); then
        if (( wide )); then
            colored="${C_TEXT}${plain}${RST}"
        else
            cmd_f=$(pad "$1" "${TOP_W_CMD:-1}")
            cpu_f=$(pad "$2" "${TOP_W_CPU:-1}")
            mem_f=$(pad "$3" "${TOP_W_MEM:-1}")
            res_f=$(pad "$4" "${TOP_W_RES:-1}")
            colored=$(printf '  %s%s%s  %sCPU %s%s  %sRAM %s%s  %s%s%s' \
                "$C_TEXT" "$cmd_f" "$RST" \
                "$DIM" "$cpu_f" "$RST" \
                "$DIM" "$mem_f" "$RST" \
                "$C_HOST" "$res_f" "$RST")
        fi
    fi
    box_emit "$plain" "$colored" 0
}

home_service() {
    local role="$1" state="$2" pid="$3" sid="${4:-}"
    local word scol role_f state_f pid_f plain colored
    word=$(svc_word "$state")
    scol=$(status_color "$state")
    role_f=$(pad "$role" 12)
    state_f=$(pad "$word" 9)
    [[ -n "$pid" ]] || pid="—"
    [[ -n "$sid" ]] || sid="—"
    pid_f=$(pad "$pid" 8)
    plain=$(service_row_text "$role" "$state" "$pid" "$sid")
    if (( $(char_len "$plain") > BOX_IN )); then
        plain=$(clip_vis "$plain" "$BOX_IN")
        colored=$plain
        if (( USE_COLOR )); then
            colored="${scol}${plain}${RST}"
        fi
        box_emit "$plain" "$colored" 0
        return
    fi
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '  %s●%s %s%s%s%s%s%s%sPID %s%s%s' \
            "$scol" "$RST" \
            "$C_TEXT" "$role_f" "$RST" \
            "$scol" "$state_f" "$RST" \
            "$DIM" "$pid_f" "$sid" "$RST")
    fi
    box_emit "$plain" "$colored" 0
}

home_note() {
    local text="$1" color="$2"
    local plain="  ${text}" colored
    if (( $(char_len "$plain") > BOX_IN )); then
        plain=$(clip_vis "$plain" "$BOX_IN")
    fi
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '%s%s%s' "$color" "$plain" "$RST")
    fi
    box_emit "$plain" "$colored" 0
}

home_kesl() {
    local name="$1" status="$2"
    local color plain colored room gap nlen slen
    color=$(kesl_status_color "$status")
    nlen=$(char_len "$name")
    slen=$(char_len "$status")
    room=$((BOX_IN - 2))
    if (( room < 1 )); then
        room=1
    fi
    if (( nlen + 2 + slen <= room )); then
        gap=$((room - nlen - slen))
        plain=$(printf '  %s%*s%s' "$name" "$gap" "" "$status")
        colored=$plain
        if (( USE_COLOR )); then
            colored=$(printf '  %s%s%s%*s%s%s%s' \
                "$C_TEXT" "$name" "$RST" "$gap" "" "$color" "$status" "$RST")
        fi
        box_emit "$plain" "$colored" 0
        return
    fi
    plain=$(printf '  %s' "$name")
    if (( $(char_len "$plain") > BOX_IN )); then
        plain=$(clip_vis "$plain" "$BOX_IN")
    fi
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '%s%s%s' "$C_TEXT" "$plain" "$RST")
    fi
    box_emit "$plain" "$colored" 0
    plain=$(printf '    %s' "$status")
    if (( $(char_len "$plain") > BOX_IN )); then
        plain=$(clip_vis "$plain" "$BOX_IN")
    fi
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '%s%s%s' "$color" "$plain" "$RST")
    fi
    box_emit "$plain" "$colored" 0
}

home_menu_row() {
    local mark="$1" num="$2" title="$3" tail="$4" extra="$5"
    local num_f title_f plain colored
    num_f=$(pad "[$num]" 4)
    title_f=$(pad "$title" 16)
    plain="  ${num_f}${title_f}${tail}${extra}"
    if (( $(char_len "$plain") > BOX_IN )); then
        plain=$(clip_vis "$plain" "$BOX_IN")
        colored=$plain
        if (( USE_COLOR )); then
            colored="${C_TEXT}${plain}${RST}"
        fi
        box_emit "$plain" "$colored" "$mark"
        return
    fi
    colored=$plain
    if (( USE_COLOR )); then
        colored=$(printf '  %s%s%s%s%s%s%s%s%s' \
            "$DIM" "$num_f" "$RST" \
            "$C_TEXT" "$title_f" "$RST" \
            "$DIM" "${tail}${extra}" "$RST")
    fi
    box_emit "$plain" "$colored" "$mark"
}

home_prompt() {
    local typed="$1" left ver gap ln vn plain colored
    if [[ -n "$typed" ]]; then
        left="  > ${typed}"
    else
        left="  > Select component or enter name"
    fi
    ver="parser ${PARSER_VERSION}"
    ln=$(char_len "$left")
    vn=$(char_len "$ver")
    if (( ln + 2 + vn <= BOX_IN )); then
        gap=$((BOX_IN - ln - vn))
        plain="${left}$(printf '%*s' "$gap" "")${ver}"
        colored=$plain
        if (( USE_COLOR )); then
            if [[ -n "$typed" ]]; then
                colored=$(printf '  %s>%s %s%s%s%*s%s%s%s' \
                    "$DIM" "$RST" "$C_HOST" "$typed" "$RST" \
                    "$gap" "" "$DIM" "$ver" "$RST")
            else
                colored=$(printf '%s%s%*s%s%s%s' \
                    "$DIM" "$left" "$gap" "" "$DIM" "$ver" "$RST")
            fi
        fi
    else
        plain=$(clip_vis "$left" "$BOX_IN")
        colored=$plain
        if (( USE_COLOR )); then
            colored=$(printf '%s%s%s' "$C_HOST" "$plain" "$RST")
        fi
    fi
    box_emit "$plain" "$colored" 0
}

draw_home() {
    local typed="${1:-}" i=1 role extra ip name state pid age mnt dev fs used avail size
    local mark cpu model pct="" free="" pair label count noun
    local need=78 dlen text
    term_size
    disk_measure
    if [[ ${#disk_mnt[@]} -gt 0 ]]; then
        for i in "${!disk_mnt[@]}"; do
            disk_load_row "$i"
            text=$(disk_row_text "$dev" "$mnt" "$fs" "$pair" "$pct" "$free")
            dlen=$(char_len "$text")
            if (( dlen > need )); then
                need=$dlen
            fi
            break
        done
    fi
    top_measure
    if (( ${#TOP_PROC_CMD[@]} )); then
        for i in "${!TOP_PROC_CMD[@]}"; do
            text=$(top_row_text "${TOP_PROC_CMD[$i]}" "${TOP_PROC_CPU[$i]}" "${TOP_PROC_MEM[$i]}" "${TOP_PROC_RES[$i]}")
            dlen=$(char_len "$text")
            if (( dlen > need )); then need=$dlen; fi
        done
    fi
    if (( ${#svc_unit[@]} )); then
        while IFS= read -r i; do
            text=$(service_row_text "${svc_role[$i]:-прочее}" "${svc_state[$i]:-?}" "${svc_pid[$i]:-—}" "${svc_id[$i]:-без id}")
            dlen=$(char_len "$text")
            if (( dlen > need )); then need=$dlen; fi
        done < <(sorted_service_indexes)
    fi
    if (( ${KESL_PRESENT:-0} )); then
        text="  исключения для KUMA добавлены"
        dlen=$(char_len "$text")
        if (( dlen > need )); then need=$dlen; fi
        text="  исключения для KUMA не добавлены"
        dlen=$(char_len "$text")
        if (( dlen > need )); then need=$dlen; fi
        if (( ${#KESL_EX[@]} )); then
            for text in "${KESL_EX[@]}"; do
                dlen=$(char_len "    ${text}")
                if (( dlen > need )); then need=$dlen; fi
            done
        fi
    fi
    BOX_IN=$((TERM_COLS - 3))
    if (( BOX_IN > need )); then
        BOX_IN=$need
    fi
    if (( BOX_IN < 36 )); then
        BOX_IN=36
    fi
    name=${HOST_NAME:-${HOST_STATIC:-—}}
    box_banner "╭" "╮" "KUMA / HOST DIAGNOSTICS"
    box_emit "" "" 0
    if (( HOST_HAS_FQDN )); then
        home_kv "HOST" "$name" "${BOLD}${C_HOST}"
    else
        home_kv "HOST" "$name" "${BOLD}${C_BAD}"
        home_kv "FQDN" "не задан" "$C_BAD"
    fi
    if [[ ${#HOST_IP[@]} -eq 0 ]]; then
        home_kv "ADDRESS" "не найден" "$C_WARN"
    else
        for ip in "${HOST_IP[@]}"; do
            home_kv "ADDRESS" "$ip"
        done
    fi
    if [[ -n "${HOST_UPTIME:-}" ]]; then
        home_kv "UPTIME" "$HOST_UPTIME"
    else
        home_kv "UPTIME" "не найден" "$C_WARN"
    fi
    if [[ -n "${HOST_TZ:-}" ]]; then
        home_kv "TZ" "$HOST_TZ"
    else
        home_kv "TZ" "не найден" "$C_WARN"
    fi
    home_kv "SYSTEM" "${HOST_OS:-—}"
    home_kv "KERNEL" "${HOST_KERNEL:-—}"
    if [[ ${#VER_LINES[@]} -gt 0 ]]; then
        home_kv "KUMA" "v${VER_LINES[0]}" "$C_VER"
    else
        home_kv "KUMA" "не найдена" "$C_BAD"
    fi
    box_emit "" "" 0
    box_banner "├" "┤" "SYSTEM RESOURCES"
    box_emit "" "" 0
    model=""
    [[ -n "${HOST_CPU_MODEL:-}" ]] && model=$(cpu_short "$HOST_CPU_MODEL")
    if [[ "${HOST_CPU_N:-0}" -eq 0 ]]; then
        home_kv "CPU" "не найден" "$C_WARN"
    elif [[ "${HOST_CPU_PHYS:-0}" -gt 0 && "$HOST_CPU_PHYS" -ne "$HOST_CPU_N" ]]; then
        cpu="${HOST_CPU_N} logical / ${HOST_CPU_PHYS} physical"
        [[ -n "$model" ]] && cpu+="   ${model}"
        home_kv "CPU" "$cpu"
    else
        cpu="${HOST_CPU_N} cores"
        [[ -n "$model" ]] && cpu+="   ${model}"
        home_kv "CPU" "$cpu"
    fi
    fill_pressure
    if [[ -n "$PRESS_LA_VALUE" ]]; then
        home_metric "LA" "$PRESS_LA_VALUE" "$PRESS_LA_COLOR" "$PRESS_LA_TAIL"
    fi
    if [[ -n "$PRESS_WA_VALUE" ]]; then
        home_metric "WA" "$PRESS_WA_VALUE" "$PRESS_WA_COLOR"
    fi
    if mem_card; then
        home_meter "MEMORY" "$MEM_PAIR" "$MEM_PCT" "$MEM_FREE"
    elif [[ -n "${HOST_MEM_TEXT:-}" ]]; then
        home_kv "MEMORY" "$HOST_MEM_TEXT"
    else
        home_kv "MEMORY" "не найдена" "$C_WARN"
    fi
    home_split "TOP"
    if [[ ${#TOP_PROC_CMD[@]} -eq 0 ]]; then
        home_kv "TOP" "не распознан" "$C_WARN"
    else
        for i in "${!TOP_PROC_CMD[@]}"; do
            home_proc "${TOP_PROC_CMD[$i]}" "${TOP_PROC_CPU[$i]}" "${TOP_PROC_MEM[$i]}" "${TOP_PROC_RES[$i]}"
        done
    fi
    home_split "DISK"
    if [[ ${#disk_mnt[@]} -eq 0 ]]; then
        home_kv "DISK" "не распознаны" "$C_WARN"
    else
        for i in "${!disk_mnt[@]}"; do
            disk_load_row "$i"
            home_disk "$dev" "$mnt" "$fs" "$pair" "$pct" "$free"
        done
    fi
    box_emit "" "" 0
    box_banner "├" "┤" "KUMA SERVICES"
    box_emit "" "" 0
    if [[ ${#svc_unit[@]} -eq 0 ]]; then
        home_kv "SERVICE" "не распознаны" "$C_WARN"
    else
        while IFS= read -r i; do
            role=${svc_role[$i]}
            [[ -n "$role" ]] || role="прочее"
            state=${svc_state[$i]:-?}
            pid=${svc_pid[$i]:-—}
            home_service "$role" "$state" "$pid" "${svc_id[$i]:-без id}"
            age=$(svc_age_label "${svc_since[$i]:-}" "$state")
            [[ -n "$age" ]] && home_note "  $age" "$DIM"
        done < <(sorted_service_indexes)
    fi
    if (( ${KESL_PRESENT:-0} )); then
        box_emit "" "" 0
        box_banner "├" "┤" "KESL"
        box_emit "" "" 0
        if [[ ${#KESL_NAME[@]} -eq 0 ]]; then
            home_kv "KESL" "$(kesl_empty_text)" "$C_WARN"
        else
            for i in "${!KESL_NAME[@]}"; do
                home_kesl "${KESL_NAME[$i]}" "${KESL_STATUS[$i]}"
            done
        fi
        box_emit "" "" 0
        if (( ${#KESL_EX[@]} )); then
            home_note "исключения для KUMA добавлены" "$C_OK"
            for text in "${KESL_EX[@]}"; do
                home_note "  ${text}" "$C_OK"
            done
        else
            home_note "исключения для KUMA не добавлены" "$C_BAD"
            if (( ! ${KESL_EX_FOUND:-0} )); then
                home_note "файл исключений не найден" "$C_BAD"
            fi
        fi
    fi
    box_emit "" "" 0
    box_banner "├" "┤" "LOG ANALYZER"
    box_emit "" "" 0
    if [[ ${#ROLE_MENU[@]} -eq 0 ]]; then
        home_kv "LOG" "выбирать не из чего" "$DIM"
    fi
    i=1
    for role in "${ROLE_MENU[@]}"; do
        extra=""
        mark=0
        menu_hit "$typed" "$role" "$i" && mark=1
        count=$(role_count "$role")
        if [[ "$count" == "1" ]]; then
            noun="log"
        else
            noun="logs"
        fi
        home_menu_row "$mark" "$i" "${role^}" "${count} ${noun}" "$extra"
        i=$((i + 1))
    done
    box_emit "" "" 0
    if [[ -n "$MENU_NOTE" ]]; then
        home_kv "NOTE" "$MENU_NOTE" "$C_BAD"
    fi
    home_prompt "$typed"
    box_emit "" "" 0
    box_bottom
}

draw_id_menu() {
    local role="$1" typed="${2:-}" n=1 idx pid mark
    ID_MENU=()
    left_emit "${role}" "${BOLD}${C_HOST}"
    left_emit "номер открывает логи, b компоненты, q выход" "$DIM"
    emit ""
    while IFS= read -r idx; do
        ID_MENU+=("$idx")
        pid=${svc_pid[$idx]}
        [[ -n "$pid" ]] || pid="—"
        mark=0
        menu_hit "$typed" "$n" "$n" && mark=1
        emit_pick "$mark" "$(printf '%s   %s    %s    pid %s' "$n" "${svc_id[$idx]:-без id}" "${svc_state[$idx]:-?}" "$pid")" "$C_TEXT"
        n=$((n + 1))
    done < <(indexes_for_role "$role")
    if [[ ${#ID_MENU[@]} -eq 0 ]]; then
        emit "  служб этой роли нет"
    fi
    emit ""
    emit "  b  к компонентам"
    emit "  q  выход"
    if [[ -n "$MENU_NOTE" ]]; then
        emit_c "$C_BAD" "  ${MENU_NOTE}"
    fi
}

term_size() {
    TERM_ROWS=$(tput lines 2>/dev/null || printf '%s' 24)
    TERM_COLS=$(tput cols 2>/dev/null || printf '%s' 80)
    [[ "$TERM_ROWS" =~ ^[0-9]+$ ]] || TERM_ROWS=24
    [[ "$TERM_COLS" =~ ^[0-9]+$ ]] || TERM_COLS=80
    if (( TERM_ROWS < 6 )); then TERM_ROWS=6; fi
    if (( TERM_COLS < 40 )); then TERM_COLS=40; fi
}

ui_charset() {
    [[ -n "${UI_BYTE:-}" ]] && return 0
    local mark="─"
    if (( ${#mark} > 1 )); then
        UI_BYTE=1
    else
        UI_BYTE=0
    fi
}

wrap_into_screen() {
    local s="$1" width="$2" out="" vis=0 i=0 n ch extra ord
    ui_charset
    n=${#s}
    if (( n == 0 || width < 1 )); then
        SCREEN_ROWS+=("")
        return 0
    fi
    while (( i < n )); do
        ch=${s:i:1}
        if [[ "$ch" == $'\033' ]]; then
            out+=$'\033'
            i=$((i + 1))
            while (( i < n )); do
                ch=${s:i:1}
                out+="$ch"
                i=$((i + 1))
                [[ "$ch" == "m" ]] && break
            done
            continue
        fi
        if (( vis >= width )); then
            SCREEN_ROWS+=("$out")
            out=""
            vis=0
        fi
        out+="$ch"
        i=$((i + 1))
        if (( UI_BYTE )); then
            printf -v ord '%d' "'$ch"
            extra=0
            if (( ord >= 240 )); then extra=3
            elif (( ord >= 224 )); then extra=2
            elif (( ord >= 192 )); then extra=1
            fi
            while (( extra > 0 && i < n )); do
                out+="${s:i:1}"
                i=$((i + 1))
                extra=$((extra - 1))
            done
        fi
        vis=$((vis + 1))
    done
    SCREEN_ROWS+=("$out")
}

build_screen_rows() {
    local width=$((TERM_COLS - 1)) i
    SCREEN_ROWS=()
    if [[ ${#VIEW_DRAW[@]} -eq 0 ]]; then
        SCREEN_ROWS+=("  Пусто.")
        return 0
    fi
    for i in "${!VIEW_DRAW[@]}"; do
        wrap_into_screen "${VIEW_DRAW[$i]}" "$width"
    done
}

view_prepare() {
    local max_top
    term_size
    if [[ "${ROW_COLS:-}" != "$TERM_COLS" || ${#SCREEN_ROWS[@]} -eq 0 ]]; then
        build_screen_rows
        ROW_COLS=$TERM_COLS
    fi
    VIEW_BODY=$((TERM_ROWS - 1))
    VIEW_TOTAL=${#SCREEN_ROWS[@]}
    max_top=$((VIEW_TOTAL - VIEW_BODY))
    if (( max_top < 0 )); then max_top=0; fi
    if (( SCROLL < 0 )); then SCROLL=0; fi
    if (( SCROLL > max_top )); then SCROLL=$max_top; fi
}

paint_rows() {
    local foot="$1" color="${2:-$DIM}" i line hit h row plain
    if (( USE_COLOR )) && [[ -n "$BG_BASE" ]]; then
        printf '%s\033[H' "$BG_BASE" >/dev/tty
    else
        printf '\033[H' >/dev/tty
    fi
    for ((i = 0; i < VIEW_BODY; i++)); do
        line=""
        row=$((SCROLL + i))
        if (( row < VIEW_TOTAL )); then
            line=${SCREEN_ROWS[$row]}
        fi
        hit=0
        if (( ${#FIND_HITS[@]} )) && (( row < VIEW_TOTAL )); then
            for h in "${!FIND_HITS[@]}"; do
                if (( FIND_HITS[h] == row && h == FIND_POS )); then
                    hit=1
                    break
                fi
            done
        fi
        if (( hit )); then
            plain=$(strip_ansi "$line")
            if (( USE_COLOR )); then
                printf '\033[2K\033[38;2;11;15;20m\033[48;2;240;180;77m%s%s\n' "$plain" "$RST" >/dev/tty
            else
                printf '\033[2K%s\n' "$plain" >/dev/tty
            fi
            continue
        fi
        if (( USE_COLOR )) && [[ -n "$BG_BASE" ]]; then
            printf '%s\033[2K%s\n' "$BG_BASE" "$line" >/dev/tty
        else
            printf '\033[2K%s\n' "$line" >/dev/tty
        fi
    done
    if [[ "${FIND_EDIT:-0}" -eq 0 ]]; then
        if [[ -n "${FIND_NOTE:-}" ]]; then
            foot="${FIND_NOTE} · ${foot}"
        else
            foot="/ поиск · ${foot}"
        fi
    fi
    if (( ${#foot} > TERM_COLS - 1 )); then
        foot=${foot:0:TERM_COLS-1}
    fi
    printf '\033[2K%s%s%s' "$color" "$foot" "$RST" >/dev/tty
}

strip_ansi() {
    printf '%s' "$1" | sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g'
}

ui_find_step() {
    local dir="$1" n idx
    n=${#FIND_HITS[@]}
    (( n > 0 )) || return 0
    FIND_POS=$(( (FIND_POS + dir + n) % n ))
    idx=${FIND_HITS[$FIND_POS]}
    SCROLL=$idx
    FIND_NOTE="$((FIND_POS + 1))/${n}  «${FIND_QUERY}»  n дальше  N назад"
}

ui_find_run() {
    local q="$1" i plain low
    FIND_QUERY=$q
    FIND_HITS=()
    FIND_POS=0
    low=${q,,}
    view_prepare
    for i in "${!SCREEN_ROWS[@]}"; do
        plain=$(strip_ansi "${SCREEN_ROWS[$i]}")
        [[ "${plain,,}" == *"$low"* ]] && FIND_HITS+=("$i")
    done
    if (( ${#FIND_HITS[@]} == 0 )); then
        FIND_NOTE="нет «${FIND_QUERY}»"
        return 0
    fi
    ui_find_step 0
}

ui_find_prompt() {
    local saved=$UI_KEY_MODE q="" ev ch
    UI_KEY_MODE=find
    FIND_EDIT=1
    cursor_show
    while true; do
        view_prepare
        paint_rows "  / ${q}   Enter · Esc отмена" "$C_ASK"
        ev=$(read_ui_event)
        case "$ev" in
            submit)
                [[ -n "$q" ]] && ui_find_run "$q"
                break
                ;;
            esc) break ;;
            bs) q=${q%?} ;;
            key:*)
                ch=${ev#key:}
                q+="$ch"
                ;;
        esac
    done
    FIND_EDIT=0
    UI_KEY_MODE=$saved
    printf '\033[?25l' >/dev/tty
    CURSOR_HIDDEN=1
}

ui_find_clear() {
    FIND_QUERY=""
    FIND_NOTE=""
    FIND_POS=0
    FIND_HITS=()
}

ui_find_event() {
    case "$1" in
        find) ui_find_prompt ;;
        findnext) ui_find_step 1 ;;
        findprev) ui_find_step -1 ;;
    esac
}

paint_log_view() {
    local foot hint=""
    view_prepare
    if (( HAS_CFG )); then
        hint=" · c конфигурация"
    fi
    if (( VIEW_TOTAL <= VIEW_BODY )); then
        foot="  весь список на экране · b компоненты · i другой ID${hint} · q выход"
    else
        foot=$(printf '  строки %d–%d из %d · колёсико или ↑↓ · b компоненты · i другой ID%s · q выход' \
            $((SCROLL + 1)) \
            $((SCROLL + VIEW_BODY < VIEW_TOTAL ? SCROLL + VIEW_BODY : VIEW_TOTAL)) \
            "$VIEW_TOTAL" "$hint")
    fi
    paint_rows "$foot"
}

paint_home_view() {
    local typed="$1" foot color="$DIM" span
    view_prepare
    if (( VIEW_TOTAL <= VIEW_BODY )); then
        foot="  q  выход"
    else
        span=$((SCROLL + VIEW_BODY < VIEW_TOTAL ? SCROLL + VIEW_BODY : VIEW_TOTAL))
        foot=$(printf '  строки %d–%d из %d · колёсико или ↑↓ · q выход' \
            $((SCROLL + 1)) "$span" "$VIEW_TOTAL")
    fi
    if [[ -n "$MENU_NOTE" ]]; then
        foot="${MENU_NOTE}   ${foot}"
        color="$C_BAD"
    fi
    paint_rows "$foot" "$color"
}

paint_id_view() {
    local typed="$1" foot color="$DIM" span
    view_prepare
    if (( VIEW_TOTAL <= VIEW_BODY )); then
        foot=$(printf '  > %s   номер · b компоненты · q выход' "$typed")
    else
        span=$((SCROLL + VIEW_BODY < VIEW_TOTAL ? SCROLL + VIEW_BODY : VIEW_TOTAL))
        foot=$(printf '  > %s   строки %d–%d из %d · колёсико · b компоненты · q выход' \
            "$typed" $((SCROLL + 1)) "$span" "$VIEW_TOTAL")
    fi
    if [[ -n "$MENU_NOTE" ]]; then
        foot="${MENU_NOTE}   ${foot}"
        color="$C_BAD"
    fi
    paint_rows "$foot" "$color"
}

read_ui_event() {
    local k c seq btn bxy
    # -N, не -n: Enter это перевод строки, а -n считает его концом ввода и возвращает пусто.
    IFS= read -rsN1 k </dev/tty || { printf 'quit'; return 0; }
    if [[ "$k" != $'\033' ]]; then
        if [[ "$UI_KEY_MODE" != "find" && ( "$k" == $'\x06' || "$k" == '/' ) ]]; then
            printf 'find'
            return 0
        fi
        if [[ "$UI_KEY_MODE" == "find" ]]; then
            case "$k" in
                $'\n'|$'\r') printf 'submit' ;;
                $'\x7f'|$'\b') printf 'bs' ;;
                [[:print:]]) printf 'key:%s' "$k" ;;
                *) printf 'none' ;;
            esac
            return 0
        fi
        if [[ "$UI_KEY_MODE" == "menu" ]]; then
            case "$k" in
                $'\n'|$'\r') printf 'submit' ;;
                $'\x7f'|$'\b') printf 'bs' ;;
                ' ') printf 'pagedown' ;;
                [[:print:]]) printf 'key:%s' "$k" ;;
                *) printf 'none' ;;
            esac
            return 0
        fi
        case "$k" in
            b|B) printf 'back' ;;
            i|I) printf 'id' ;;
            c|C) printf 'config' ;;
            q|Q) printf 'quit' ;;
            ' ') printf 'pagedown' ;;
            j|J) printf 'down' ;;
            k|K) printf 'up' ;;
            n)
                if [[ -n "$FIND_QUERY" ]]; then printf 'findnext'; else printf 'none'; fi
                ;;
            N)
                if [[ -n "$FIND_QUERY" ]]; then printf 'findprev'; else printf 'none'; fi
                ;;
            *) printf 'none' ;;
        esac
        return 0
    fi
    IFS= read -rsN1 -t 0.1 c </dev/tty || { printf 'esc'; return 0; }
    if [[ "$c" != '[' && "$c" != 'O' ]]; then
        printf 'none'
        return 0
    fi
    seq=$c
    while IFS= read -rsN1 -t 0.1 c; do
        seq+="$c"
        if [[ "$seq" == "[M" ]]; then
            IFS= read -rsN3 -t 0.1 bxy || true
            seq+="$bxy"
            break
        fi
        [[ "$c" =~ [A-Za-z~] ]] && break
        if (( ${#seq} > 48 )); then break; fi
    done
    case "$seq" in
        '[A'|'OA'|'[1;2A'|'[1;5A') printf 'up' ;;
        '[B'|'OB'|'[1;2B'|'[1;5B') printf 'down' ;;
        '[5~'|'[5;2~'|'[5;5~') printf 'pageup' ;;
        '[6~'|'[6;2~'|'[6;5~') printf 'pagedown' ;;
        '[H'|'[1~'|'[7~'|'OH') printf 'home' ;;
        '[F'|'[4~'|'[8~'|'OF') printf 'end' ;;
        \[\<64*) printf 'wheelup' ;;
        \[\<65*) printf 'wheeldown' ;;
        '[M'*)
            btn=${seq:3:1}
            if [[ -z "$btn" ]]; then
                printf 'none'
            else
                btn=$(printf '%d' "'$btn")
                if [[ "$btn" == "96" || "$btn" == "64" ]]; then printf 'wheelup'
                elif [[ "$btn" == "97" || "$btn" == "65" ]]; then printf 'wheeldown'
                else printf 'none'
                fi
            fi
            ;;
        *) printf 'none' ;;
    esac
}

arm_scroll() {
    # Только колесо как стрелки. Кнопки мыши остаются терминалу: выделение и копирование обычные.
    printf '\033[?1000l\033[?1006l\033[?1007h' >/dev/tty
    MOUSE_ON=1
    printf '\033[?25l' >/dev/tty
    CURSOR_HIDDEN=1
}

scroll_log_view() {
    local ev step
    ui_find_clear
    SCROLL=0
    ROW_COLS=-1
    UI_AFTER=home
    UI_KEY_MODE="log"
    arm_scroll
    while true; do
        paint_log_view
        ev=$(read_ui_event)
        step=$((TERM_ROWS - 2))
        case "$ev" in
            up) SCROLL=$((SCROLL - 1)) ;;
            down) SCROLL=$((SCROLL + 1)) ;;
            wheelup) SCROLL=$((SCROLL - 3)) ;;
            wheeldown) SCROLL=$((SCROLL + 3)) ;;
            pageup) SCROLL=$((SCROLL - step)) ;;
            pagedown) SCROLL=$((SCROLL + step)) ;;
            home) SCROLL=0 ;;
            end) SCROLL=999999 ;;
            find|findnext|findprev) ui_find_event "$ev" ;;
            back) UI_AFTER=home; break ;;
            id) UI_AFTER=id; break ;;
            config)
                if (( HAS_CFG )); then
                    UI_AFTER=config
                    break
                fi
                ;;
            quit) UI_AFTER=quit; break ;;
        esac
    done
    mouse_off
    cursor_show
}

number_ready() {
    local t="$1" n="$2" i hits=0
    READY_NUM=""
    [[ "$t" =~ ^[0-9]+$ ]] || return 1
    (( n >= 1 )) || return 1
    for ((i = 1; i <= n; i++)); do
        [[ "$i" == "$t"* ]] && hits=$((hits + 1))
    done
    if [[ "$hits" -eq 1 ]] && (( 10#$t >= 1 && 10#$t <= n )); then
        READY_NUM=$t
        return 0
    fi
    return 1
}

home_ready() {
    local t="${1,,}" r hits=0
    HOME_READY=""
    [[ -n "$t" ]] || return 1
    if [[ "$t" =~ ^[0-9]+$ ]]; then
        number_ready "$t" "${#ROLE_MENU[@]}" || return 1
        HOME_READY=$READY_NUM
        return 0
    fi
    for r in "${ROLE_MENU[@]}"; do
        if [[ "${r,,}" == "$t"* ]]; then
            hits=$((hits + 1))
            HOME_READY=$r
        fi
    done
    if [[ "$hits" -eq 1 ]]; then
        return 0
    fi
    HOME_READY=""
    return 1
}

scroll_home() {
    local ev ch step typed="" drawn="*"
    HOME_CHOICE=""
    ui_find_clear
    SCROLL=0
    ROW_COLS=-1
    UI_KEY_MODE="menu"
    arm_scroll
    while true; do
        if [[ "$typed" != "$drawn" ]]; then
            UI_CAPTURE=1
            VIEW_PLAIN=()
            VIEW_DRAW=()
            draw_home "$typed"
            UI_CAPTURE=0
            ROW_COLS=-1
            drawn=$typed
        fi
        paint_home_view "$typed"
        ev=$(read_ui_event)
        step=$((TERM_ROWS - 2))
        case "$ev" in
            up) SCROLL=$((SCROLL - 1)) ;;
            down) SCROLL=$((SCROLL + 1)) ;;
            wheelup) SCROLL=$((SCROLL - 3)) ;;
            wheeldown) SCROLL=$((SCROLL + 3)) ;;
            pageup) SCROLL=$((SCROLL - step)) ;;
            pagedown) SCROLL=$((SCROLL + step)) ;;
            home) SCROLL=0 ;;
            end) SCROLL=999999 ;;
            find|findnext|findprev) ui_find_event "$ev" ;;
            bs) typed=${typed%?} ;;
            submit)
                HOME_CHOICE=$typed
                break
                ;;
            key:*)
                ch=${ev#key:}
                if [[ -z "$typed" && -n "$FIND_QUERY" && "$ch" == "n" ]]; then
                    ui_find_step 1
                    continue
                fi
                if [[ -z "$typed" && -n "$FIND_QUERY" && "$ch" == "N" ]]; then
                    ui_find_step -1
                    continue
                fi
                if [[ -z "$typed" && ( "$ch" == "q" || "$ch" == "Q" ) ]]; then
                    HOME_CHOICE=q
                    break
                fi
                typed+="$ch"
                if home_ready "$typed"; then
                    HOME_CHOICE=$HOME_READY
                    break
                fi
                ;;
        esac
    done
    mouse_off
    cursor_show
}

scroll_id() {
    local ev ch step typed="" drawn="*" role="$1"
    ID_CHOICE=""
    ui_find_clear
    SCROLL=0
    ROW_COLS=-1
    UI_KEY_MODE="menu"
    arm_scroll
    while true; do
        if [[ "$typed" != "$drawn" ]]; then
            UI_CAPTURE=1
            VIEW_PLAIN=()
            VIEW_DRAW=()
            draw_id_menu "$role" "$typed"
            UI_CAPTURE=0
            ROW_COLS=-1
            drawn=$typed
        fi
        paint_id_view "$typed"
        ev=$(read_ui_event)
        step=$((TERM_ROWS - 2))
        case "$ev" in
            up) SCROLL=$((SCROLL - 1)) ;;
            down) SCROLL=$((SCROLL + 1)) ;;
            wheelup) SCROLL=$((SCROLL - 3)) ;;
            wheeldown) SCROLL=$((SCROLL + 3)) ;;
            pageup) SCROLL=$((SCROLL - step)) ;;
            pagedown) SCROLL=$((SCROLL + step)) ;;
            home) SCROLL=0 ;;
            end) SCROLL=999999 ;;
            find|findnext|findprev) ui_find_event "$ev" ;;
            bs) typed=${typed%?} ;;
            submit)
                ID_CHOICE=$typed
                break
                ;;
            key:*)
                ch=${ev#key:}
                if [[ -z "$typed" && -n "$FIND_QUERY" && "$ch" == "n" ]]; then
                    ui_find_step 1
                    continue
                fi
                if [[ -z "$typed" && -n "$FIND_QUERY" && "$ch" == "N" ]]; then
                    ui_find_step -1
                    continue
                fi
                if [[ -z "$typed" && ( "$ch" == "q" || "$ch" == "Q" ) ]]; then
                    ID_CHOICE=q
                    break
                fi
                if [[ -z "$typed" && ( "$ch" == "b" || "$ch" == "B" ) ]]; then
                    ID_CHOICE=b
                    break
                fi
                typed+="$ch"
                if number_ready "$typed" "${#ID_MENU[@]}"; then
                    ID_CHOICE=$READY_NUM
                    break
                fi
                ;;
        esac
    done
    mouse_off
    cursor_show
}

load_configs() {
    local dir="$1" line name file
    CFG_NAMES=()
    CFG_FILES=()
    [[ -f "$dir/index.tsv" ]] || return 0
    while IFS=$'\t' read -r name file || [[ -n "${name:-}" ]]; do
        [[ -n "${name:-}" && -n "${file:-}" && -f "$dir/$file" ]] || continue
        CFG_NAMES+=("$name")
        CFG_FILES+=("$dir/$file")
    done <"$dir/index.tsv"
}

scroll_plain() {
    local foot="$1" ev step
    ui_find_clear
    SCROLL=0
    ROW_COLS=-1
    UI_KEY_MODE="log"
    arm_scroll
    while true; do
        paint_rows_foot "$foot"
        ev=$(read_ui_event)
        step=$((TERM_ROWS - 2))
        case "$ev" in
            up) SCROLL=$((SCROLL - 1)) ;;
            down) SCROLL=$((SCROLL + 1)) ;;
            wheelup) SCROLL=$((SCROLL - 3)) ;;
            wheeldown) SCROLL=$((SCROLL + 3)) ;;
            pageup) SCROLL=$((SCROLL - step)) ;;
            pagedown) SCROLL=$((SCROLL + step)) ;;
            home) SCROLL=0 ;;
            end) SCROLL=999999 ;;
            find|findnext|findprev) ui_find_event "$ev" ;;
            back) UI_AFTER=back; break ;;
            config) UI_AFTER=back; break ;;
            quit) UI_AFTER=quit; break ;;
            id) ;;
        esac
    done
    mouse_off
    cursor_show
}

paint_rows_foot() {
    local foot="$1"
    view_prepare
    paint_rows "$foot"
}

show_one_config() {
    local name="$1" file="$2" line
    UI_CAPTURE=1
    VIEW_PLAIN=()
    VIEW_DRAW=()
    emit_c "${BOLD}${C_LOG}" "  Конфигурация    ${name}"
    emit ""
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        emit "  $line"
    done <"$file"
    UI_CAPTURE=0
    SKIP_OUT=1
    scroll_plain "  b к списку конфигураций · q выход"
}

show_config_browser() {
    local dir="$1" ev ch step typed="" n
    load_configs "$dir"
    if [[ ${#CFG_NAMES[@]} -eq 0 ]]; then
        UI_CAPTURE=1
        VIEW_PLAIN=()
        VIEW_DRAW=()
        emit_c "${BOLD}${C_LOG}" "  Конфигурация"
        emit ""
        emit "  В логе collector нет строки init с JSON конфигурации."
        UI_CAPTURE=0
        SKIP_OUT=1
        scroll_plain "  b к логам · q выход"
        return 0
    fi
    while true; do
        typed=""
        UI_CAPTURE=1
        VIEW_PLAIN=()
        VIEW_DRAW=()
        emit_c "${BOLD}${C_LOG}" "  Конфигурация collector"
        emit ""
        emit "  JSON со строки init. Номер открывает его целиком."
        emit ""
        n=0
        while (( n < ${#CFG_NAMES[@]} )); do
            emit_c "$C_SVC" "  $((n + 1)). ${CFG_NAMES[$n]}"
            n=$((n + 1))
        done
        UI_CAPTURE=0
        SKIP_OUT=1
        SCROLL=0
        ROW_COLS=-1
        UI_KEY_MODE="menu"
        UI_CAPTURE=0
        arm_scroll
        while true; do
            paint_rows_foot "$(printf '  > %s   номер · b к логам · q выход' "$typed")"
            ev=$(read_ui_event)
            step=$((TERM_ROWS - 2))
            case "$ev" in
                up) SCROLL=$((SCROLL - 1)) ;;
                down) SCROLL=$((SCROLL + 1)) ;;
                wheelup) SCROLL=$((SCROLL - 3)) ;;
                wheeldown) SCROLL=$((SCROLL + 3)) ;;
                pageup) SCROLL=$((SCROLL - step)) ;;
                pagedown) SCROLL=$((SCROLL + step)) ;;
                home) SCROLL=0 ;;
                end) SCROLL=999999 ;;
                find|findnext|findprev) ui_find_event "$ev" ;;
                bs) typed=${typed%?} ;;
                submit)
                    if number_ready "$typed" "${#CFG_NAMES[@]}"; then
                        n=$((10#$READY_NUM))
                        mouse_off
                        cursor_show
                        show_one_config "${CFG_NAMES[$((n - 1))]}" "${CFG_FILES[$((n - 1))]}"
                        [[ "$UI_AFTER" == "quit" ]] && return 0
                    fi
                    break
                    ;;
                key:*)
                    ch=${ev#key:}
                    if [[ -z "$typed" && -n "$FIND_QUERY" && "$ch" == "n" ]]; then
                        ui_find_step 1
                        continue
                    fi
                    if [[ -z "$typed" && -n "$FIND_QUERY" && "$ch" == "N" ]]; then
                        ui_find_step -1
                        continue
                    fi
                    if [[ -z "$typed" && ( "$ch" == "q" || "$ch" == "Q" ) ]]; then
                        UI_AFTER=quit
                        mouse_off
                        cursor_show
                        return 0
                    fi
                    if [[ -z "$typed" && ( "$ch" == "b" || "$ch" == "B" ) ]]; then
                        UI_AFTER=back
                        mouse_off
                        cursor_show
                        return 0
                    fi
                    typed+="$ch"
                    if number_ready "$typed" "${#CFG_NAMES[@]}"; then
                        n=$((10#$READY_NUM))
                        mouse_off
                        cursor_show
                        show_one_config "${CFG_NAMES[$((n - 1))]}" "${CFG_FILES[$((n - 1))]}"
                        [[ "$UI_AFTER" == "quit" ]] && return 0
                        break
                    fi
                    ;;
            esac
        done
    done
}

ask_log_scope() {
    local ev ch step typed=""
    LOG_VIEW=""
    UI_AFTER=""
    UI_CAPTURE=1
    VIEW_PLAIN=()
    VIEW_DRAW=()
    emit_c "${BOLD}${C_ASK}" "  Что анализировать"
    emit ""
    emit_c "$C_SVC" "  1. только ошибки"
    emit_c "$C_SVC" "  2. только debug"
    emit_c "$C_SVC" "  3. всё"
    emit ""
    emit_c "$DIM" "  номер открывает список сразу"
    UI_CAPTURE=0
    SKIP_OUT=1
    SCROLL=0
    ROW_COLS=-1
    UI_KEY_MODE="menu"
    arm_scroll
    while true; do
        paint_rows_foot "$(printf '  > %s   номер · b к ID · q выход' "$typed")"
        ev=$(read_ui_event)
        step=$((TERM_ROWS - 2))
        case "$ev" in
            up) SCROLL=$((SCROLL - 1)) ;;
            down) SCROLL=$((SCROLL + 1)) ;;
            wheelup) SCROLL=$((SCROLL - 3)) ;;
            wheeldown) SCROLL=$((SCROLL + 3)) ;;
            pageup) SCROLL=$((SCROLL - step)) ;;
            pagedown) SCROLL=$((SCROLL + step)) ;;
            home) SCROLL=0 ;;
            end) SCROLL=999999 ;;
            bs) typed=${typed%?} ;;
            submit|"")
                ;;
            key:*)
                ch=${ev#key:}
                if [[ -z "$typed" && ( "$ch" == "q" || "$ch" == "Q" ) ]]; then
                    UI_AFTER=quit
                    mouse_off
                    cursor_show
                    return 0
                fi
                if [[ -z "$typed" && ( "$ch" == "b" || "$ch" == "B" ) ]]; then
                    UI_AFTER=id
                    mouse_off
                    cursor_show
                    return 0
                fi
                typed+="$ch"
                ;;
        esac
        if number_ready "$typed" 3; then
            case "$READY_NUM" in
                1) LOG_VIEW=error ;;
                2) LOG_VIEW=debug ;;
                *) LOG_VIEW=all ;;
            esac
            mouse_off
            cursor_show
            return 0
        fi
    done
}

show_logs() {
    local idx="$1" role id
    role=${svc_role[$idx]}
    id=${svc_id[$idx]}
    [[ -n "$role" ]] || role="прочее"
    screen_clear
    ask_log_scope
    if [[ "$UI_AFTER" == "id" || "$UI_AFTER" == "quit" ]]; then
        return 0
    fi
    HAS_CFG=0
    [[ "$role" == "collector" ]] && HAS_CFG=1
    while true; do
        screen_clear
        SKIP_OUT=1
        emit_c "${BOLD}${C_LOG}" "  Логи    ${role}    ${id:-без id}"
        if [[ -f "$work/proto-${role}-${id}.txt.ok" ]]; then
            emit_c "$DIM" "  Отчёт этой службы уже посчитан."
        else
            emit_c "$DIM" "  Последние 10% ${role}/${id}/log/. Без стека и версий."
        fi
        if (( HAS_CFG )); then
            emit_c "$DIM" "  c — конфигурация со строки init."
        fi
        SKIP_OUT=0
        UI_CAPTURE=1
        VIEW_PLAIN=()
        VIEW_DRAW=()
        case "$LOG_VIEW" in
            error) emit_c "$DIM" "  Список: только ошибки." ;;
            debug) emit_c "$DIM" "  Список: только debug." ;;
            *) emit_c "$DIM" "  Список: все уровни." ;;
        esac
        if [[ ! -f "$AWK_PROG" ]]; then
            emit "  Нет файла разбора логов: $AWK_PROG"
        elif ! have_gawk; then
            emit "  Для логов нужен GNU awk (gawk)."
        else
            AWK_TOP=all
            analyze_service "$idx"
            AWK_TOP=""
            print_skipped_logs
        fi
        UI_CAPTURE=0
        SKIP_OUT=1
        scroll_log_view
        if [[ "$UI_AFTER" != "config" ]]; then
            break
        fi
        show_config_browser "$work/cfg-${id}"
        if [[ "$UI_AFTER" == "quit" ]]; then
            break
        fi
    done
    HAS_CFG=0
}

id_loop() {
    local role="$1" choice n idx
    while (( UI_QUIT == 0 )); do
        scroll_id "$role"
        choice=$ID_CHOICE
        case "$choice" in
            b|B|назад) MENU_NOTE=""; return ;;
            q|Q|выход) UI_QUIT=1; return ;;
            "") MENU_NOTE=""; continue ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            n=$((10#$choice))
            if (( n >= 1 && n <= ${#ID_MENU[@]} )); then
                idx=${ID_MENU[$((n - 1))]}
                MENU_NOTE=""
                show_logs "$idx"
                case "$UI_AFTER" in
                    id) continue ;;
                    quit) UI_QUIT=1; return ;;
                    *) MENU_NOTE=""; return ;;
                esac
            fi
        fi
        MENU_NOTE="Нет такого пункта: ${choice}"
    done
}

ui_loop() {
    local choice role r n first=1
    fill_role_menu
    enter_ui
    while (( UI_QUIT == 0 )); do
        if (( first )); then SKIP_OUT=0; else SKIP_OUT=1; fi
        scroll_home
        first=0
        SKIP_OUT=1
        choice=$HOME_CHOICE
        case "$choice" in
            q|Q|выход) UI_QUIT=1; continue ;;
            "") MENU_NOTE=""; continue ;;
        esac
        role=""
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            n=$((10#$choice))
            if (( n >= 1 && n <= ${#ROLE_MENU[@]} )); then
                role=${ROLE_MENU[$((n - 1))]}
            fi
        else
            for r in "${ROLE_MENU[@]}"; do
                [[ "${choice,,}" == "$r" ]] && role=$r
            done
        fi
        if [[ -z "$role" ]]; then
            MENU_NOTE="Нет такого пункта: ${choice}"
            continue
        fi
        MENU_NOTE=""
        id_loop "$role"
    done
    leave_ui
    printf '%s\n' "Готово."
    if [[ -n "$OUT" ]]; then
        progress "Отчёт без цветов: $OUT"
    fi
}

write_home_report() {
    local name safe file saved_out saved_skip
    name=${HOST_NAME:-report}
    safe=${name//[^[:alnum:]._-]/_}
    [[ -n "$safe" ]] || safe=report
    file="${LAUNCH_DIR}/${safe}-report.txt"
    saved_out=$OUT
    saved_skip=$SKIP_OUT
    OUT=$file
    : > "$OUT" || die "не могу записать $file"
    SKIP_OUT=0
    fill_role_menu
    UI_CAPTURE=1
    VIEW_PLAIN=()
    VIEW_DRAW=()
    draw_home ""
    UI_CAPTURE=0
    VIEW_PLAIN=()
    VIEW_DRAW=()
    OUT=$saved_out
    SKIP_OUT=$saved_skip
    progress "Отчёт первой страницы: $file"
}

report_path() {
    local name safe
    name=${HOST_NAME:-report}
    safe=${name//[^[:alnum:]._-]/_}
    [[ -n "$safe" ]] || safe=report
    printf '%s' "${LAUNCH_DIR}/${safe}-report.txt"
}

write_full_report() {
    local file saved_out saved_skip saved_logs saved_awk
    file=$(report_path)
    saved_out=$OUT
    saved_skip=$SKIP_OUT
    saved_logs=$LOGS_MODE
    saved_awk=${AWK_TOP:-}
    OUT=$file
    : > "$OUT" || die "не могу записать $file"
    SKIP_OUT=0
    # В меню логи ещё не выбраны. В полном отчёте разбираются все службы.
    if [[ "$LOGS_MODE" == "ask" ]]; then
        LOGS_MODE=all
    fi
    AWK_TOP=all
    if [[ -t 1 ]] && tty_ok; then
        REPORT_QUIET=1
    fi
    emit "Полный отчёт. Сюда входит всё, что скрипт разобрал."
    print_banner
    print_host
    print_disks
    print_version
    print_services
    print_kesl
    run_logs
    emit ""
    emit_c "$DIM" "$(rule 40)"
    emit_c "$DIM" "Конец отчёта."
    REPORT_QUIET=0
    LOGS_MODE=$saved_logs
    AWK_TOP=$saved_awk
    OUT=$saved_out
    SKIP_OUT=$saved_skip
    progress "Полный отчёт: $file"
}

main() {
    LAUNCH_DIR=$(pwd)
    parse_args "$@"
    setup_colors
    if [[ -n "$OUT" ]]; then
        : > "$OUT" || die "не могу записать $OUT"
    fi

    ARCHIVE=$(normalize_path "$ARCHIVE")
    ARCHIVE_RAW=$ARCHIVE
    [[ -e "$ARCHIVE" ]] || die "путь не найден: $ARCHIVE"
    if [[ -n "$DEBUG_FILE" ]]; then
        DEBUG_FILE=$(normalize_path "$DEBUG_FILE")
        debug_start
        debug_stage "старт"
        dbg "размер архива $(file_bytes "$ARCHIVE" 2>/dev/null || printf 0) байт"
    fi
    local parent="/tmp" fstype
    fstype=$(df -T /tmp 2>/dev/null | awk 'NR==2 { print $2 }')
    if [[ "$fstype" == "tmpfs" ]]; then
        parent="${HOME:-/var/tmp}"
        progress "/tmp находится в памяти, временные файлы кладу в $parent"
    fi
    work=$(mktemp -d "$parent/kuma-parse.XXXXXX")
    IS_DIR=0
    PREFIX_NOTE=""

    locate_inputs() {
        local root="$1"
        FILE_HOSTNAME=$(find_suffix "$root" "$SUFFIX_HOSTNAME")
        FILE_VERSION=$(find_suffix "$root" "$SUFFIX_VERSION")
        FILE_SERVICES=$(find_suffix "$root" "$SUFFIX_SERVICES")
        FILE_HDD=$(find_suffix "$root" "$SUFFIX_HDD")
        FILE_IPA=$(find_suffix "$root" "$SUFFIX_IPA")
        FILE_IFCONFIG=$(find_suffix "$root" "$SUFFIX_IFCONFIG")
        FILE_CPU=$(find_suffix "$root" "$SUFFIX_CPU")
        FILE_SYSCTL=$(find_suffix "$root" "$SUFFIX_SYSCTL")
        FILE_TOP=$(find_suffix "$root" "$SUFFIX_TOP")
        FILE_UPTIME=$(find_suffix "$root" "$SUFFIX_UPTIME")
        FILE_TIMEDATE=$(find_suffix "$root" "$SUFFIX_TIMEDATE")
        FILE_DATE=$(find_suffix "$root" "$SUFFIX_DATE")
        FILE_DATE_EN=$(find_suffix "$root" "$SUFFIX_DATE_EN")
        FILE_MEMORY=$(find_suffix "$root" "$SUFFIX_MEMORY")
        FILE_KESL=$(find_suffix "$root" "$SUFFIX_KESL")
        FILE_KESL_EX=$(find_suffix "$root" "$SUFFIX_KESL_EX")
        if [[ -z "$FILE_KESL_EX" ]]; then
            FILE_KESL_EX=$(find_suffix "$root" "$SUFFIX_KESL_EXP")
        fi
        LOGS_TAR=$(find_suffix "$root" "$SUFFIX_LOGS")
    }

    if [[ -d "$ARCHIVE" ]]; then
        IS_DIR=1
        locate_inputs "$ARCHIVE"
    else
        debug_stage "сводка"
        progress "Распаковываю сводку одним проходом. logs.tar откроется только если смотреть логи."
        local tar_err
        tar_err=$(tar -xzf "$ARCHIVE" -C "$work" --wildcards --no-anchored \
            '*/environment/hostname.txt' \
            '*/environment/hdd.txt' \
            '*/environment/ipa.txt' \
            '*/environment/ifconfig.txt' \
            '*/environment/cpuinfo.txt' \
            '*/environment/sysctl.txt' \
            '*/environment/top.txt' \
            '*/environment/uptime.txt' \
            '*/environment/timedatectl.txt' \
            '*/environment/date.txt' \
            '*/environment/date_en.txt' \
            '*/environment/memory.txt' \
            '*/kaspersky/KUMA/services.txt' \
            '*/kaspersky/KUMA/execvers.txt' \
            '*/kaspersky/KESL/appinfo.txt' \
            '*/kaspersky/KESL/exset.txt' \
            '*/kaspersky/KESL/expset.txt' 2>&1 >/dev/null) || true
        if [[ -n "$tar_err" ]]; then
            tar_err=$(printf '%s\n' "$tar_err" | grep -v -e 'Not found in archive' -e 'Exiting with failure status due to previous errors' || true)
            [[ -n "$tar_err" ]] && printf '%s\n' "$tar_err" >&2
        fi
        locate_inputs "$work"
        debug_stage "сводка-готова"
        [[ -n "${FILE_HOSTNAME:-}" ]] || die "в архиве нет $SUFFIX_HOSTNAME — это не похоже на коллект KUMA"
    fi
    if [[ -n "${FILE_HOSTNAME:-}" && "$FILE_HOSTNAME" == *"$SUFFIX_HOSTNAME" ]]; then
        local root="$work"
        [[ "$IS_DIR" -eq 1 ]] && root="$ARCHIVE"
        PREFIX_NOTE=${FILE_HOSTNAME#"$root/"}
        PREFIX_NOTE=${PREFIX_NOTE%"$SUFFIX_HOSTNAME"}
        PREFIX_NOTE=${PREFIX_NOTE%/}
    fi

    load_hostname "${FILE_HOSTNAME:-}"
    load_ips "${FILE_IPA:-}"
    if [[ ${#HOST_IP[@]} -eq 0 ]]; then
        load_ifconfig "${FILE_IFCONFIG:-}"
    fi
    load_cpu "${FILE_CPU:-}"
    if [[ "${HOST_CPU_N:-0}" -eq 0 ]]; then
        load_cpu_sysctl "${FILE_SYSCTL:-}"
    fi
    load_mem "${FILE_TOP:-}" "${FILE_MEMORY:-}"
    load_top_pressure "${FILE_TOP:-}"
    load_top_procs "${FILE_TOP:-}"
    load_uptime "${FILE_UPTIME:-}"
    load_timezone "${FILE_TIMEDATE:-}" "${FILE_DATE_EN:-}" "${FILE_DATE:-}"
    load_version "${FILE_VERSION:-}"
    load_services "${FILE_SERVICES:-}"
    load_kesl "${FILE_KESL:-}"
    load_kesl_exclusions "${FILE_KESL_EX:-}"
    load_disks "${FILE_HDD:-}"
    capture_mount_total "${FILE_HDD:-}"
    summarize_disks

    if (( REPORT == 1 )); then
        write_home_report
    elif (( REPORT == 2 )); then
        write_full_report
    fi

    if [[ "$LOGS_MODE" == "ask" && -t 1 ]] && tty_ok; then
        ui_loop
        return
    fi
    if (( REPORT == 2 )); then
        return
    fi

    print_banner
    print_host
    print_disks
    print_version
    print_services
    print_kesl
    run_logs

    emit ""
    emit_c "$DIM" "$(rule 40)"
    emit_c "$DIM" "Конец отчёта."
    if [[ -n "$OUT" ]]; then
        progress "Отчёт без цветов: $OUT"
    fi
}

main "$@"
