#!/usr/bin/env python3
"""tsan-classify.py <tsan log file> [<tsan log file> ...]

Splits each ThreadSanitizer log (TSAN_OPTIONS log_path=<prefix> writes one
file per pid, <prefix>.<pid>) into individual "data race" reports and buckets
each one, in this order (first match wins):

  libc-tz       glibc localtime/tzset/gmtime races -- reported, never gates
                red/green (these fire on any concurrent time formatting,
                unrelated to #184).
  ps-pair       RestHandler::handle_ps racing on RestHandler::ensure_model_loaded
                -- the #184 race this harness exists to catch.
  model-state   some other RestHandler/AutoModel state race.
  failed-restore  TSan could not symbolize/unwind one side of the race.
  other         anything else.

Classification looks only at the two ACCESS stacks of each report (the
"Write/Read of size N ..." block and the "Previous write/read of size N ..."
block that races with it), plus the "Location is ..." allocation stack. A
function name appearing elsewhere in the report -- e.g. in a thread-creation
backtrace or an unrelated "as if synchronized via sleep" hint -- is not
enough to classify a report: only frames that are actually part of the two
racing accesses count.

Prints a one-line dedup summary per report, a count per bucket, and a final
machine-readable line:
  "BUCKETS ps-pair=N model-state=N failed-restore=N libc-tz=N other=N".
Always exits 0 -- callers (race.sh) apply the red/green oracle themselves.

--self-test runs the classifier against synthetic reports covering a genuine
ps-pair, a tz race that happens to mention handle_ps/ensure_model_loaded
outside the access stacks, and a non-tz race where ensure_model_loaded only
appears in a thread-creation stack (must NOT be model-state).
"""
import re
import sys

WARNING_RE = re.compile(r"WARNING: ThreadSanitizer: data race")
DELIM_RE = re.compile(r"^=+$")

# Stack 1: the primary access ("Write of size 8 ... by thread T3:" or
# "Atomic read of size 4 ... by main thread:").
STACK1_HEADER_RE = re.compile(
    r"^\s*(?:Atomic )?(?:Read|Write) of size \d+ at 0x[0-9a-fA-F]+ "
    r"by (?:thread T\d+|main thread)\b.*:\s*$"
)
# Stack 2: the racing access ("Previous read ..." / "Previous atomic write ...").
STACK2_HEADER_RE = re.compile(
    r"^\s*Previous (?:atomic )?(?:read|write) of size \d+ at 0x[0-9a-fA-F]+ "
    r"by (?:thread T\d+|main thread)\b.*:\s*$"
)
LOCATION_HEAP_RE = re.compile(r"Location is heap block")
FRAME_RE = re.compile(r"^\s*#\d+\s+(.*)$")

TZ_MARKERS = ("tzset", "__tz", "localtime", "gmtime", "strftime")

MODEL_STATE_ALLOC_MARKERS = (
    "std::make_shared<RestHandler",
    "RestHandler::RestHandler",
)
NOISE_PREFIXES = (
    "std::",
    "__gnu_cxx::",
    "operator new",
    "operator delete",
)
NOISE_SUBSTRINGS = (
    "__tsan",
    "__interceptor",
    "__libc_",
    "__clone",
    "start_thread",
)


def frame_func(line):
    m = FRAME_RE.match(line)
    if not m:
        return None
    rest = m.group(1)
    # drop trailing "(flm+0xoffset)" / "(BuildId: ...)" groups (there can be two)
    for _ in range(2):
        rest = re.sub(r"\s*\([^()]*\)\s*$", "", rest)
    # drop trailing "file.cpp:NN[:NN]" or "<null>"
    rest = re.sub(r"\s+\S+:\d+(:\d+)?$", "", rest)
    rest = re.sub(r"\s+<null>$", "", rest)
    return rest.strip()


def is_noise(func):
    if not func:
        return True
    if func.startswith(NOISE_PREFIXES):
        return True
    return any(p in func for p in NOISE_SUBSTRINGS)


def top_frames(lines, n=3):
    out = []
    for line in lines:
        func = frame_func(line)
        if func is None or is_noise(func):
            continue
        out.append(func)
        if len(out) >= n:
            break
    return out


def split_reports(text):
    """Yield the text of each data-race report in a TSan log."""
    lines = text.splitlines()
    chunks = []
    current = []
    for line in lines:
        if DELIM_RE.match(line):
            if current:
                chunks.append(current)
            current = []
        else:
            current.append(line)
    if current:
        chunks.append(current)
    for chunk in chunks:
        if any(WARNING_RE.search(line) for line in chunk):
            yield "\n".join(chunk)


def parse_report(report):
    """Return (stack1, stack2, heap_alloc_text) for one report.

    stack1/stack2 are (header, [frame lines]) for the primary and "Previous
    ..." access blocks, or None if the report doesn't have that block (e.g.
    "[failed to restore the stack]"-only reports still produce a header with
    one frame line). heap_alloc_text is the "Location is heap block ...
    allocated by thread" stack text, or None. Anything else in the report
    (thread-creation stacks, "as if synchronized via sleep" hints, mutex
    creation stacks) is intentionally ignored -- it must never influence
    classification.
    """
    lines = report.splitlines()
    stack1 = None
    stack2 = None
    heap_alloc_lines = None
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if stack1 is None and STACK1_HEADER_RE.match(line):
            header = line.strip()
            frames = []
            i += 1
            while i < n and lines[i].strip() != "":
                frames.append(lines[i])
                i += 1
            stack1 = (header, frames)
            continue
        if stack2 is None and STACK2_HEADER_RE.match(line):
            header = line.strip()
            frames = []
            i += 1
            while i < n and lines[i].strip() != "":
                frames.append(lines[i])
                i += 1
            stack2 = (header, frames)
            continue
        if LOCATION_HEAP_RE.search(line):
            frames = []
            i += 1
            while i < n and lines[i].strip() != "":
                frames.append(lines[i])
                i += 1
            heap_alloc_lines = "\n".join(frames)
            continue
        i += 1
    return stack1, stack2, heap_alloc_lines


def frames_of(stack):
    return stack[1] if stack else []


def frames_have(frames, substr):
    return any(substr in line for line in frames)


def frames_have_any(frames, substrs):
    return any(s in line for s in substrs for line in frames)


def is_failed_restore(frames):
    return any("[failed to restore the stack]" in line for line in frames)


def classify(report):
    stack1, stack2, heap_alloc = parse_report(report)
    stacks = [s for s in (stack1, stack2) if s is not None]

    f1 = frames_of(stack1)
    f2 = frames_of(stack2)

    if frames_have_any(f1[:4], TZ_MARKERS) or frames_have_any(f2[:4], TZ_MARKERS):
        return "libc-tz", stacks

    has_ps_1 = frames_have(f1, "RestHandler::handle_ps")
    has_ps_2 = frames_have(f2, "RestHandler::handle_ps")
    has_ensure_1 = frames_have(f1, "RestHandler::ensure_model_loaded")
    has_ensure_2 = frames_have(f2, "RestHandler::ensure_model_loaded")

    if (has_ps_1 and has_ensure_2) or (has_ps_2 and has_ensure_1):
        return "ps-pair", stacks

    has_rh_frame = frames_have(f1, "RestHandler::") or frames_have(f2, "RestHandler::")
    has_automodel = frames_have(f1, "AutoModel::") or frames_have(f2, "AutoModel::")
    alloc_is_resthandler = bool(heap_alloc) and any(
        m in heap_alloc for m in MODEL_STATE_ALLOC_MARKERS
    )
    alloc_is_webserver = bool(heap_alloc) and "make_unique<WebServer" in heap_alloc

    if (
        has_ensure_1
        or has_ensure_2
        or has_automodel
        or (has_rh_frame and alloc_is_resthandler and not alloc_is_webserver)
    ):
        return "model-state", stacks

    if is_failed_restore(f1) or is_failed_restore(f2):
        return "failed-restore", stacks

    return "other", stacks


def summarize(bucket, access_stacks):
    parts = []
    for header, frames in access_stacks:
        tag = "W" if "write" in header.lower() else "R"
        funcs = top_frames(frames)
        parts.append(f"[{tag}]{','.join(funcs) if funcs else '?'}")
    return f"{bucket}: " + " ; ".join(parts) if parts else f"{bucket}: (no access stacks)"


def classify_text(text):
    """Classify every report in one log's text. Returns list of (bucket, access_stacks)."""
    return [classify(r) for r in split_reports(text)]


BUCKET_ORDER = ("ps-pair", "model-state", "failed-restore", "libc-tz", "other")


def run(paths):
    counts = {b: 0 for b in BUCKET_ORDER}
    for path in paths:
        try:
            with open(path, "r", errors="replace") as f:
                text = f.read()
        except OSError as e:
            print(f"skip {path}: {e}", file=sys.stderr)
            continue
        results = classify_text(text)
        for bucket, access_stacks in results:
            counts[bucket] += 1
            print(f"{path}: {summarize(bucket, access_stacks)}")
    print()
    for bucket in BUCKET_ORDER:
        print(f"{bucket}: {counts[bucket]}")
    print("BUCKETS " + " ".join(f"{b}={counts[b]}" for b in BUCKET_ORDER))
    return 0


PS_PAIR_REPORT = """==================
WARNING: ThreadSanitizer: data race (pid=12345)
  Write of size 8 at 0x7b0400000100 by thread T3:
    #0 RestHandler::ensure_model_loaded(std::string const&, bool) rest_handler.cpp:560:5 (flm+0x1111)
    #1 RestHandler::handle_chat(nlohmann::json const&, ...) rest_handler.cpp:900:9 (flm+0x2222)

  Previous read of size 8 at 0x7b0400000100 by thread T5:
    #0 RestHandler::handle_ps(nlohmann::json const&, ...) rest_handler.cpp:1360:30 (flm+0x3333)
    #1 WebServer::dispatch(...) server.cpp:400:5 (flm+0x4444)

  Location is heap block of size 96 at 0x7b0400000100 allocated by thread T1:
    #0 operator new(unsigned long) <null> (flm+0x5555)
    #1 std::make_shared<RestHandler, model_list&, ModelDownloader&, program_args_t&>(...) <null> (flm+0x6666)
    #2 create_lm_server(model_list&, ModelDownloader&, program_args_t&) server.cpp:948:25 (flm+0x7777)

  Thread T3 'flm-worker' (tid=100, running) created by main thread at:
    #0 pthread_create <null> (flm+0x8888)

SUMMARY: ThreadSanitizer: data race in RestHandler::ensure_model_loaded(std::string const&, bool)
==================
"""

# A tz race where handle_ps and ensure_model_loaded both appear in the report
# text, but ensure_model_loaded is only in a thread-creation stack, not in
# either access stack. Under the old whole-report substring match this would
# have been misclassified ps-pair; per-stack matching must call it libc-tz.
TZ_WITH_HANDLE_PS_REPORT = """==================
WARNING: ThreadSanitizer: data race (pid=12345)
  Write of size 4 at 0x7b0400000200 by thread T2:
    #0 tzset_internal <null> (flm+0x9999)
    #1 RestHandler::handle_ps(nlohmann::json const&, ...) rest_handler.cpp:1332:25 (flm+0xaaaa)

  Previous write of size 4 at 0x7b0400000200 by thread T4:
    #0 gmtime <null> (flm+0xbbbb)
    #1 WebServer::dispatch(...) server.cpp:400:5 (flm+0xcccc)

  Location is global 'localtime_buf' of size 56 at 0x7b0400000200 (flm+0x000000abcdef)

  Thread T2 'flm-worker' (tid=200, running) created by main thread at:
    #0 pthread_create <null> (flm+0xdddd)
    #1 RestHandler::ensure_model_loaded(std::string const&, bool) rest_handler.cpp:560:5 (flm+0xeeee)

SUMMARY: ThreadSanitizer: data race in tzset_internal
==================
"""

# ensure_model_loaded appears only in a thread-creation stack, the access
# stacks are unrelated and not tz -- must NOT be classified model-state (nor
# ps-pair, since handle_ps is absent entirely).
NON_ACCESS_ENSURE_LOADED_REPORT = """==================
WARNING: ThreadSanitizer: data race (pid=12345)
  Write of size 4 at 0x7b0400000300 by thread T6:
    #0 SomeUnrelated::method() foo.cpp:10:5 (flm+0xf000)

  Previous write of size 4 at 0x7b0400000300 by thread T7:
    #0 SomeUnrelated::other() foo.cpp:20:5 (flm+0xf111)

  Location is heap block of size 16 at 0x7b0400000300 allocated by thread T1:
    #0 operator new(unsigned long) <null> (flm+0xf222)
    #1 std::make_shared<Foo>(...) <null> (flm+0xf333)

  Thread T6 'flm-worker' (tid=300, running) created by main thread at:
    #0 pthread_create <null> (flm+0xf444)
    #1 RestHandler::ensure_model_loaded(std::string const&, bool) rest_handler.cpp:560:5 (flm+0xf555)

SUMMARY: ThreadSanitizer: data race in SomeUnrelated::method
==================
"""


def self_test():
    reports = list(split_reports(PS_PAIR_REPORT))
    assert len(reports) == 1, f"expected 1 report, got {len(reports)}"
    bucket, _ = classify(reports[0])
    assert bucket == "ps-pair", f"expected ps-pair, got {bucket}"

    reports = list(split_reports(TZ_WITH_HANDLE_PS_REPORT))
    assert len(reports) == 1, f"expected 1 report, got {len(reports)}"
    bucket, _ = classify(reports[0])
    assert bucket == "libc-tz", f"expected libc-tz, got {bucket}"

    reports = list(split_reports(NON_ACCESS_ENSURE_LOADED_REPORT))
    assert len(reports) == 1, f"expected 1 report, got {len(reports)}"
    bucket, _ = classify(reports[0])
    assert bucket != "model-state", f"expected NOT model-state, got {bucket}"
    assert bucket == "other", f"expected other, got {bucket}"

    print("self-test OK")
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    paths = argv[1:]
    return run(paths)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
