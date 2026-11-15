#!/usr/bin/env python3
# Достаёт из logs.tar только файлы одной службы: .../kuma/<роль>/<id>/log/
# Чужие папки не разбираются. После файлов этой службы чтение останавливается.
# Сырой лог на диск не пишется: байты идут в stdout, дальше их читает awk.
import json
import os
import signal
import subprocess
import sys

CHUNK = 8 * 1024 * 1024
READ = 0
FOUND = 0
GZIP = None


def add_read(n):
    global READ
    READ += n


def read_exact(f, n):
    parts = []
    got = 0
    while got < n:
        chunk = f.read(n - got)
        if not chunk:
            break
        parts.append(chunk)
        got += len(chunk)
    add_read(got)
    if not parts:
        return b""
    if len(parts) == 1:
        return parts[0]
    return b"".join(parts)


def skip(f, n):
    left = n
    while left > 0:
        chunk = f.read(CHUNK if left > CHUNK else left)
        if not chunk:
            raise EOFError("усечённый tar")
        add_read(len(chunk))
        left -= len(chunk)


def parse_size(field):
    if not field or field == b"\0" * len(field):
        return 0
    if field[0] in (0x80, 0xFF):
        n = 0
        for b in field[1:]:
            n = (n << 8) | b
        if field[0] == 0xFF:
            n -= 1 << ((len(field) - 1) * 8)
        return n
    text = field.split(b"\0", 1)[0].strip()
    if not text:
        return 0
    return int(text, 8)


def padded(size):
    return (size + 511) & ~511


def header_name(block):
    name = block[0:100].split(b"\0", 1)[0].decode("utf-8", "surrogateescape")
    if block[257:262] == b"ustar":
        prefix = block[345:500].split(b"\0", 1)[0].decode("utf-8", "surrogateescape")
        if prefix:
            name = prefix + "/" + name
    while name.startswith("./"):
        name = name[2:]
    return name


def safe_rel(name):
    rel = name.replace("\\", "/")
    while rel.startswith("./"):
        rel = rel[2:]
    parts = [p for p in rel.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts):
        return None
    return "/".join(parts)


def write_stage(path, text):
    if not path:
        return
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text + "\n")


# Доля с конца файла. Свежие события лежат в хвосте.
TAIL_NUM = 1
TAIL_DEN = 10
SPAN = None
SPAN_WRITTEN = False
CONFIG_OUT = None
INITS = []
SEEN_INIT = set()


def event_ts(line):
    if len(line) >= 20 and line[4:5] == b"-" and line[7:8] == b"-" and line[10:11] == b"T":
        end = line.find(b"\t")
        if end < 10:
            end = min(len(line), 30)
        return line[:end].decode("ascii", "ignore")
    # ClickHouse: 2026.09.01 07:29:10.245809
    if len(line) >= 19 and line[4:5] == b"." and line[7:8] == b"." and line[:4].isdigit():
        day = line[:10].decode("ascii", "ignore").replace(".", "-")
        rest = line[11:30].split(b" ", 1)[0].decode("ascii", "ignore")
        if rest:
            return day + "T" + rest
    return None


def note_span(ts):
    global SPAN
    if ts and (SPAN is None or ts < SPAN):
        SPAN = ts


def emit_span(out):
    global SPAN_WRITTEN
    if SPAN_WRITTEN:
        return
    SPAN_WRITTEN = True
    out.write(("#KUMA-SPAN\t%s\n" % (SPAN or "")).encode("ascii", "ignore"))


def note_init_line(line):
    if not CONFIG_OUT or not line:
        return
    if b"\n" in line:
        for part in line.split(b"\n"):
            note_init_line(part)
        return
    key = b"\tinit\t"
    i = line.find(key)
    if i < 0:
        return
    raw = line[i + len(key):].strip()
    if not raw.startswith(b"{"):
        return
    text = raw.decode("utf-8", "replace")
    if text in SEEN_INIT:
        return
    SEEN_INIT.add(text)
    INITS.append(text)


def take_lines(buf):
    """Забирает целые строки. Возвращает неполный хвост. Первую дату запоминает."""
    nl = buf.rfind(b"\n")
    if nl < 0:
        if len(buf) > 4 * 1024 * 1024:
            return b""
        return buf
    need_scan = SPAN is None or CONFIG_OUT
    if need_scan:
        for line in buf[:nl].split(b"\n"):
            if SPAN is None:
                ts = event_ts(line)
                if ts:
                    note_span(ts)
            note_init_line(line)
    return buf[nl + 1:]


def copy_tail(f, size):
    """В awk уходит только последняя десятая файла. Начало читается, чтобы знать дату старта."""
    global FOUND
    FOUND += 1
    out = sys.stdout.buffer
    cut = (size * (TAIL_DEN - TAIL_NUM)) // TAIL_DEN
    pending = b""
    left = cut
    while left > 0:
        chunk = f.read(CHUNK if left > CHUNK else left)
        if not chunk:
            raise EOFError("усечённый файл в tar")
        add_read(len(chunk))
        pending = take_lines(pending + chunk)
        left -= len(chunk)
    consumed = cut
    # Обрезанная строка на границе 90% не событие: дочитываем её и выбрасываем.
    if pending:
        while b"\n" not in pending and consumed < size:
            n = min(CHUNK, size - consumed)
            chunk = f.read(n)
            if not chunk:
                break
            add_read(len(chunk))
            consumed += len(chunk)
            pending += chunk
        nl = pending.find(b"\n")
        if nl >= 0:
            note_init_line(pending[:nl])
            pending = pending[nl + 1:]
        else:
            note_init_line(pending)
            pending = b""
    emit_span(out)
    tail_pending = pending
    if pending:
        out.write(pending)
    left = size - consumed
    while left > 0:
        chunk = f.read(CHUNK if left > CHUNK else left)
        if not chunk:
            raise EOFError("усечённый файл в tar")
        add_read(len(chunk))
        out.write(chunk)
        if CONFIG_OUT:
            data = tail_pending + chunk
            nl = data.rfind(b"\n")
            if nl >= 0:
                for line in data[:nl].split(b"\n"):
                    note_init_line(line)
                tail_pending = data[nl + 1:]
            else:
                tail_pending = data if len(data) < 4 * 1024 * 1024 else b""
        left -= len(chunk)
    if CONFIG_OUT and tail_pending:
        note_init_line(tail_pending)
    out.flush()
    pad = padded(size) - size
    if pad:
        skip(f, pad)


def is_wanted(rel, needle):
    if not rel or not needle:
        return False
    return needle in ("/" + rel + "/")


def walk(stream, nested_outer, needle, stage, label):
    pending = None
    started = False
    announced = False
    while True:
        block = read_exact(stream, 512)
        if len(block) < 512 or block == b"\0" * 512:
            break
        size = parse_size(block[124:136])
        flag = block[156:157]
        pad = padded(size)
        if flag == b"L":
            raw = read_exact(stream, pad)
            pending = raw[:size].split(b"\0", 1)[0].decode("utf-8", "surrogateescape")
            continue
        if flag in (b"K", b"x", b"g"):
            skip(stream, pad)
            continue
        name = pending if pending is not None else header_name(block)
        pending = None
        if flag in (b"5", b"1", b"2", b"3", b"4", b"6"):
            if pad:
                skip(stream, pad)
            continue
        regular = flag in (b"0", b"\0")
        if nested_outer is not None and regular and nested_outer(name):
            walk(stream, None, needle, stage, label)
            return
        rel = safe_rel(name) if regular else None
        if regular and is_wanted(rel, needle):
            if not announced:
                announced = True
                write_stage(stage, "считаю %s" % label)
                sys.stderr.write("считаю %s\n" % label)
            copy_tail(stream, size)
            started = True
            continue
        # Файлы одной службы лежат подряд в её log/. Следующий чужой файл — конец.
        if started and regular:
            return
        if pad:
            skip(stream, pad)


def on_stop(signum, _frame):
    proc = GZIP
    if proc is not None and proc.poll() is None:
        proc.kill()
    raise SystemExit(130)


class GzipStream:
    def __init__(self, path):
        global GZIP
        self.proc = subprocess.Popen(
            ["gzip", "-dc", "--", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        GZIP = self.proc
        self.raw = self.proc.stdout

    def read(self, n):
        return self.raw.read(n)

    def close(self):
        try:
            if self.raw:
                self.raw.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()


def open_archive(path):
    raw = open(path, "rb")
    magic = raw.read(2)
    raw.close()
    if magic == b"\x1f\x8b":
        return GzipStream(path)
    return open(path, "rb")


def save_configs():
    if not CONFIG_OUT:
        return
    os.makedirs(CONFIG_OUT, exist_ok=True)
    index = []
    for n, text in enumerate(INITS, 1):
        name = "init %d" % n
        try:
            obj, _end = json.JSONDecoder().raw_decode(text.lstrip())
        except Exception:
            obj = None
        if isinstance(obj, dict):
            cfg = obj.get("config")
            if isinstance(cfg, dict):
                got = cfg.get("name") or cfg.get("id")
                if got:
                    name = str(got)
            pretty = json.dumps(obj, ensure_ascii=False, indent=2)
        else:
            pretty = text
        safe = []
        for ch in name:
            if ch.isalnum() or ch in "-_.":
                safe.append(ch)
            else:
                safe.append("_")
        fn = "%02d-%s.json" % (n, "".join(safe)[:40] or "init")
        path = os.path.join(CONFIG_OUT, fn)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(pretty)
            if not pretty.endswith("\n"):
                fh.write("\n")
        index.append("%s\t%s\n" % (name, fn))
    with open(os.path.join(CONFIG_OUT, "index.tsv"), "w", encoding="utf-8") as fh:
        fh.writelines(index)


def main(argv):
    archive = None
    outer = None
    needle = None
    stage = None
    label = None
    config_out = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        nxt = argv[i + 1] if i + 1 < len(argv) else ""
        if arg == "--archive":
            archive = nxt
            i += 2
        elif arg == "--outer":
            outer = nxt
            i += 2
        elif arg == "--needle":
            needle = nxt
            i += 2
        elif arg == "--stage":
            stage = nxt
            i += 2
        elif arg == "--label":
            label = nxt
            i += 2
        elif arg == "--config-out":
            config_out = nxt
            i += 2
        else:
            sys.stderr.write("неизвестный аргумент: %s\n" % arg)
            return 1
    if not archive or not needle:
        sys.stderr.write("нужны --archive и --needle\n")
        return 1
    if not label:
        label = needle
    if not needle.startswith("/"):
        needle = "/" + needle
    if not needle.endswith("/"):
        needle += "/"
    global CONFIG_OUT
    CONFIG_OUT = config_out
    write_stage(stage, "проматываю до %s" % label)
    signal.signal(signal.SIGTERM, on_stop)
    signal.signal(signal.SIGINT, on_stop)
    stream = open_archive(archive)
    try:
        if outer:
            walk(stream, lambda name: name.endswith(outer), needle, stage, label)
        else:
            walk(stream, None, needle, stage, label)
    finally:
        close = getattr(stream, "close", None)
        if close:
            close()
        try:
            sys.stdout.buffer.flush()
        except OSError:
            pass
        sys.stderr.write("extract bytes=%d found=%d inits=%d\n" % (READ, FOUND, len(INITS)))
    save_configs()
    if FOUND == 0:
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except OSError:
            pass
        sys.exit(0)
    except Exception as exc:
        sys.stderr.write("extract error: %s\n" % exc)
        sys.exit(1)
