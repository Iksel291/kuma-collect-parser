# Разбор одного или нескольких файлов лога KUMA (zap, поля через TAB).
# Вызывается из parse-kuma-collect.sh. Печатает протокол, не готовый отчёт:
#   STAT  lines events errors unparsed stack first last levels versions
#   ITEM  count level message cause caller dests period sample
#   MORE  hidden_groups
# Поля разделены символом \036, не табом: таб для bash пробельный,
# и пустое поле схлопнуло бы причину с кодом.
#
# Группа ошибки: уровень + файл исходника (без :строка) + нормализованные
# сообщение и причина. Порядок нормализации менять нельзя: URL раньше UUID,
# числа в конце. Иначе query_id разрывает адрес и одна ошибка становится сотнями.
#
# Требуется GNU awk (match() с третьим аргументом и asort).
# Строки не-ошибок не идут в norm() и split: на многогигабайтном логе это
# основная стоимость. Считаются событие, уровень, период и version.
# Группировка ошибок (remember / norm) от этого не меняется.

function cut(s, n) {
    gsub(/\t/, " ", s)
    gsub(/\r/, "", s)
    gsub(/\036/, " ", s)
    if (length(s) > n) s = substr(s, 1, n - 3) "..."
    return s
}

function unescape(s,    out, i, len, c, n) {
    if (index(s, "\\") == 0) return s
    len = length(s)
    out = ""
    i = 1
    while (i <= len) {
        c = substr(s, i, 1)
        if (c == "\\" && i < len) {
            n = substr(s, i + 1, 1)
            if (n == "\"") out = out "\""
            else if (n == "\\") out = out "\\"
            else if (n == "/") out = out "/"
            else if (n == "n" || n == "r" || n == "t") out = out " "
            else out = out n
            i += 2
        } else {
            out = out c
            i++
        }
    }
    return out
}

function grab(json, key,    re, m) {
    re = "\"" key "\"[[:space:]]*:[[:space:]]*\"((\\\\.|[^\"\\\\])*)\""
    if (match(json, re, m)) return unescape(m[1])
    return ""
}

function debug_text(message, json,    j, t, low) {
    # event, event send to normalizer и init: JSON на этом экране не нужен.
    # init открывается отдельным экраном конфигурации.
    low = tolower(message)
    gsub(/[[:space:]]+/, " ", low)
    if (low == "event" || low == "event send to normalizer" || low == "init") return message
    # В остальных debug полезная часть часто не в error/message, а в JSON: сырой пакет, конфиг.
    # Версию убираем, стек горутины тоже.
    j = json
    if (j != "") {
        gsub(/"version"[[:space:]]*:[[:space:]]*"[^"]*"([[:space:]]*,)?/, "", j)
        gsub(/,[[:space:]]*}/, "}", j)
        if (j ~ /^[[:space:]]*\{[[:space:]]*\}[[:space:]]*$/) j = ""
        else j = unescape(j)
        sub(/, Stack trace.*/, "", j)
    }
    if (message != "" && j != "") t = message "  " j
    else if (message != "") t = message
    else t = j
    return cut(t, 1200)
}

function cause_of(json,    v) {
    if (json == "") return ""
    v = grab(json, "error")
    if (v != "") return v
    v = grab(json, "reason")
    if (v != "") return v
    return grab(json, "message")
}

function norm(s) {
    if (s == "") return ""
    gsub(/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z?/, "<время>", s)
    gsub(/https?:\/\/[^[:space:]"'<>]+/, "<url>", s)
    gsub(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/, "<id>", s)
    # Длинный hex с буквой: id части VictoriaMetrics и похожие. Чистые числа и IP не трогаем.
    gsub(/[0-9a-fA-F]{7,}[a-fA-F][0-9a-fA-F]*/, "<hex>", s)
    gsub(/[a-fA-F][0-9a-fA-F]{7,}/, "<hex>", s)
    gsub(/[[:space:]]+/, " ", s)
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return cut(s, 400)
}

function is_caller(s) {
    return (s ~ /\.go:[0-9]+$/ && s !~ /[[:space:]]/)
}

function is_error(lvl) {
    if (lvl == "error" || lvl == "fatal" || lvl == "panic" || lvl == "dpanic") return 1
    if (lvl == "debug" || lvl == "trace" || lvl == "info" || lvl == "warn" || lvl == "warning") return 1
    return 0
}

function join_from(arr, start, n,    i, s) {
    s = arr[start]
    for (i = start + 1; i <= n; i++) s = s "\t" arr[i]
    return s
}

function remember(ts, lvl, logger, caller, message, json,    src, raw, nm, nc, key, dest, ver, s) {
    events++
    levels[lvl]++
    if (log_first == "" || ts < log_first) log_first = ts
    if (ts > log_last) log_last = ts
    if (json ~ /"version"/ && match(json, /"version"[[:space:]]*:[[:space:]]*"([0-9]+\.[0-9]+(\.[0-9]+){0,4})"/, ver)) {
        versions[ver[1]]++
    }
    if (!is_error(lvl)) return
    errors++
    src = caller
    sub(/:[0-9]+$/, "", src)
    raw = cause_of(json)
    sub(/, Stack trace.*/, "", raw)
    nm = norm(message)
    nc = norm(raw)
    if (nc == nm) nc = ""
    # \001, не SUBSEP: ключ целиком лежит внутри индекса bucket[kind, key, name].
    key = lvl "\001" src "\001" nm "\001" nc
    if (!(key in cnt)) {
        cnt[key] = 0
        g_level[key] = lvl
        if (lvl == "debug" || lvl == "trace") {
            g_msg[key] = debug_text(message, json)
            g_cause[key] = ""
        } else {
            g_msg[key] = cut(nm, 180)
            g_cause[key] = nc
        }
        g_first[key] = ts
        g_last[key] = ts
        g_sample[key] = ""
    }
    cnt[key]++
    bucket["caller", key, caller]++
    if (match(logger, /destination '([^']*)'/, dest)) {
        if (dest[1] != "") bucket["dest", key, dest[1]]++
    }
    if (ts < g_first[key]) g_first[key] = ts
    if (ts > g_last[key]) g_last[key] = ts
    if (g_sample[key] == "") {
        s = ts "  " lvl "  " message
        if (raw != "") s = s "  |  " raw
        g_sample[key] = cut(s, 220)
    }
}

function parse_event(    n, p, lvl, logger, caller, message, json) {
    n = split($0, p, "\t")
    if (n < 4) { unparsed++; return }
    lvl = p[2]
    if (lvl !~ /^(debug|info|warn|warning|error|fatal|panic|dpanic)$/) { unparsed++; return }
    logger = ""
    caller = ""
    message = ""
    json = ""
    if (is_caller(p[3])) {
        caller = p[3]
        message = p[4]
        if (n >= 5) json = join_from(p, 5, n)
    } else if (n >= 5 && is_caller(p[4])) {
        logger = p[3]
        caller = p[4]
        message = p[5]
        if (n >= 6) json = join_from(p, 6, n)
    } else {
        unparsed++
        return
    }
    remember(p[1], lvl, logger, caller, message, json)
}

function by_count(i1, v1, i2, v2) {
    if (cnt[v1] < cnt[v2]) return 1
    if (cnt[v1] > cnt[v2]) return -1
    if (v1 < v2) return -1
    if (v1 > v2) return 1
    return 0
}

function sort_pairs(kind, key,    idx, parts, n, i, j, tmp) {
    n = 0
    for (idx in bucket) {
        split(idx, parts, SUBSEP)
        if (parts[1] != kind || parts[2] != key) continue
        n++
        pn[n] = parts[3]
        pc[n] = bucket[idx] + 0
    }
    for (i = 1; i <= n; i++) {
        for (j = i + 1; j <= n; j++) {
            if (pc[j] > pc[i] || (pc[j] == pc[i] && pn[j] < pn[i])) {
                tmp = pc[i]; pc[i] = pc[j]; pc[j] = tmp
                tmp = pn[i]; pn[i] = pn[j]; pn[j] = tmp
            }
        }
    }
    pair_total = n
}

function fmt_pairs(limit, with_count,    i, shown, out, rest, piece) {
    if (pair_total == 0) return ""
    shown = pair_total < limit ? pair_total : limit
    out = ""
    for (i = 1; i <= shown; i++) {
        if (i > 1) out = out ", "
        piece = pn[i]
        if (with_count) piece = piece " (" pc[i] ")"
        out = out piece
    }
    rest = pair_total - shown
    if (rest > 0) out = out ", ещё " rest
    return out
}

function fmt_hist(arr, limit,    n, i, j, names, counts, tmp, out, shown, rest) {
    n = 0
    for (i in arr) {
        n++
        names[n] = i
        counts[n] = arr[i] + 0
    }
    if (n == 0) return ""
    for (i = 1; i <= n; i++) {
        for (j = i + 1; j <= n; j++) {
            if (counts[j] > counts[i]) {
                tmp = counts[i]; counts[i] = counts[j]; counts[j] = tmp
                tmp = names[i]; names[i] = names[j]; names[j] = tmp
            }
        }
    }
    shown = n < limit ? n : limit
    out = ""
    for (i = 1; i <= shown; i++) {
        if (i > 1) out = out ", "
        out = out names[i] " " counts[i]
    }
    rest = n - shown
    if (rest > 0) out = out ", ещё " rest
    return out
}

function take_version(    p, v, c) {
    p = index($0, "\"version\":\"")
    if (p) p += 11
    else {
        p = index($0, "\"version\": \"")
        if (!p) return
        p += 12
    }
    v = substr($0, p, 32)
    c = index(v, "\"")
    if (c <= 1) return
    v = substr(v, 1, c - 1)
    if (v ~ /^[0-9]+\.[0-9]+(\.[0-9]+){0,4}$/) versions[v]++
}

function parse_clickhouse(    ts, lvl, msg, m) {
    if (!match($0, /^([0-9]{4})\.([0-9]{2})\.([0-9]{2}) ([0-9:.]+) .* <([A-Za-z]+)> [^:]+: (.*)$/, m)) {
        return
    }
    ts = m[1] "-" m[2] "-" m[3] "T" m[4]
    lvl = tolower(m[5])
    if (lvl == "critical") lvl = "fatal"
    else if (lvl == "warning") lvl = "warn"
    else if (lvl == "information") lvl = "info"
    else if (lvl == "trace") lvl = "debug"
    msg = m[6]
    sub(/, Stack trace.*/, "", msg)
    if (!is_error(lvl)) {
        events++
        levels[lvl]++
        if (log_first == "" || ts < log_first) log_first = ts
        if (ts > log_last) log_last = ts
        return
    }
    remember(ts, lvl, "", "clickhouse", msg, "")
}

function note_plain(ts, lvl,    t1) {
    events++
    levels[lvl]++
    t1 = index($0, "\t")
    if (t1 > 1) ts = substr($0, 1, t1 - 1)
    if (log_first == "" || ts < log_first) log_first = ts
    if (ts > log_last) log_last = ts
    take_version()
}

{
    sub(/\r$/, "")
    lines++
    if (substr($0, 1, 11) == "#KUMA-SPAN\t") {
        log_begin = substr($0, 12)
        next
    }
    # ClickHouse в storage: 2026.09.01 07:29:10.245809 [ pid ] {} <Error> Logger: текст
    if (ROLE == "storage" && substr($0, 5, 1) == "." && substr($0, 8, 1) == "." && substr($0, 1, 1) ~ /[0-9]/) {
        parse_clickhouse()
        next
    }
    # Дата zap без регулярки на всю строку: на многогигабайтном логе она была основной стоимостью.
    if (substr($0, 5, 1) == "-" && substr($0, 8, 1) == "-" && substr($0, 11, 1) == "T") {
        t1 = index($0, "\t")
        if (t1 > 1) {
            t2 = index(substr($0, t1 + 1, 24), "\t")
            if (t2 > 1) {
                lvl = substr($0, t1 + 1, t2 - 1)
                if (!is_error(lvl) && (lvl == "info" || lvl == "warn" || lvl == "warning")) {
                    note_plain("", lvl)
                    next
                }
            }
        }
        parse_event()
    } else if ($0 != "" && substr($0, 1, 1) !~ /[0-9]/) stack++
}

END {
    SEP = "\036"
    # TOP=all — весь список. Иначе нечисло и 0 означают десятку по умолчанию.
    unlimited = (TOP == "all")
    if (!unlimited && TOP + 0 <= 0) TOP = 10
    # В меню показываем не больше 2000 групп: дальше список не влезает, а разбор пар на сотнях тысяч ключей не заканчивается.
    max_show = unlimited ? 2000 : TOP + 0
    print "STAT" SEP (lines + 0) SEP (events + 0) SEP (errors + 0) SEP (unparsed + 0) SEP (stack + 0) SEP log_first SEP log_last SEP "" SEP log_begin
    nkeys = 0
    for (k in cnt) {
        nkeys++
        keys[nkeys] = k
    }
    if (nkeys > 0) asort(keys, sorted, "by_count")
    shown = 0
    for (i = 1; i <= nkeys && shown < max_show; i++) {
        shown++
        k = sorted[i]
        sort_pairs("caller", k)
        caller_s = fmt_pairs(1, 0)
        sort_pairs("dest", k)
        dest_s = fmt_pairs(3, 1)
        period = g_first[k]
        if (g_last[k] != "" && g_last[k] != g_first[k]) period = period "  ..  " g_last[k]
        print "ITEM" SEP cnt[k] SEP g_level[k] SEP g_msg[k] SEP g_cause[k] SEP caller_s SEP dest_s SEP period SEP g_sample[k]
    }
    if (nkeys > shown) print "MORE" SEP (nkeys - shown)
}
