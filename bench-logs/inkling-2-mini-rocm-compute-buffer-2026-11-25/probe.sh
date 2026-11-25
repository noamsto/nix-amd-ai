#!/usr/bin/env bash
# Inkling-2-Mini compute-buffer probe: for each row backend:ctx:ub:fa[:mm][:fiton], start llama-server just far enough
# to log its buffer sizes, print one TSV line of the parsed sizes, and kill it. Rows of one series (same backend, fa,
# ub, mm/fiton) must ascend in ctx so the extrapolated compute buffer can stop the series before a near-full
# allocation wedges the GPU. A series skips when its predicted total compute buffer (device + host) exceeds GUARD_MIB;
# with no prior row to extrapolate from, a series must start at ctx <= 8192 unless a ub-512 row of the same backend,
# fa and ctx ran earlier in the same invocation (then its total scaled by min(ub, 2048)/512 is the prediction; llama.cpp
# clamps -ub to -b, default 2048). Meant to run as the child of the gated harness, never against the GPU directly:
#
#   LEMOND_MODEL=<resident lemond model> EXEC_DEV=gpu TARGET=<gguf> NEED_GIB=28 OUT=row.json EXEC_LOG=probe.log \
#     bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/run.sh exec -- \
#     env GGUF=<gguf> MMPROJ=<mmproj gguf> ROCM_BIN=<llama-cpp-rocm> VULKAN_BIN=<llama-cpp-vulkan> \
#     bench-logs/inkling-2-mini-rocm-compute-buffer-2026-11-25/probe.sh \
#     rocm:4096:512:on rocm:8192:512:on rocm:16384:512:on rocm:4096:2048:off:mm
#
# Logs at -lv 4 (buffer sizes need it). fa is on|off|auto (auto passes no -fa flag); fiton passes --fit on instead of --fit off.
# Output columns: backend ctx ub fa mm fiton n_ctx_train fa_enabled model_MiB kv_MiB compute_MiB host_compute_MiB status.
# GUARD_MIB (default 24576) caps the predicted and the measured total (device + host) compute buffer.
# DRY_RUN=1 prints the argv of every row and launches nothing; each would-run row counts as a 1 MiB result, so the dry
# run shows the series-start skips a live run would make but never the byte guard.
set -euo pipefail

guard=${GUARD_MIB:-24576}
port=${PORT:-18080}
dry=${DRY_RUN:-0}
gguf="${GGUF:-<gguf>}"
mmproj="${MMPROJ:-<mmproj>}"
declare -A bin=([rocm]="${ROCM_BIN:-<rocm-bin>}" [vulkan]="${VULKAN_BIN:-<vulkan-bin>}")

die() { echo "$*" >&2; exit 2; }

[ "$#" -gt 0 ] || die "usage: probe.sh backend:ctx:ub:fa[:mm][:fiton] ..."
[[ $guard =~ ^[0-9]+$ ]] || die "GUARD_MIB must be an integer: $guard"

declare -A last_ctx
r_backend=() r_ctx=() r_ub=() r_fa=() r_mm=() r_fiton=()
for row in "$@"; do
    IFS=: read -r backend ctx ub fa f5 f6 extra <<<"$row"
    [ -z "$extra" ] || die "bad row (too many fields): $row"
    mm=0 fiton=0
    for flag in "$f5" "$f6"; do
        case $flag in
            "") ;;
            mm) mm=1 ;;
            fiton) fiton=1 ;;
            *) die "bad row (unknown flag '$flag'): $row" ;;
        esac
    done
    case $backend in rocm | vulkan) ;; *) die "bad row (backend must be rocm|vulkan): $row" ;; esac
    case $fa in on | off | auto) ;; *) die "bad row (fa must be on|off|auto): $row" ;; esac
    [[ $ctx =~ ^[0-9]+$ && $ub =~ ^[0-9]+$ ]] || die "bad row (ctx and ub must be integers): $row"
    [ "$ctx" -ge 1024 ] || die "bad row (ctx < 1024): $row"
    [ "$ctx" -le 32768 ] || die "bad row (ctx > 32768): $row"
    [ "$ub" -ge 1 ] || die "bad row (ub must be positive): $row"
    key="$backend|$fa|$ub|$mm$fiton"
    if [ -n "${last_ctx[$key]:-}" ] && [ "$ctx" -le "${last_ctx[$key]}" ]; then
        die "rows of one series must ascend in ctx: $row follows ctx ${last_ctx[$key]}"
    fi
    last_ctx[$key]=$ctx
    r_backend+=("$backend") r_ctx+=("$ctx") r_ub+=("$ub") r_fa+=("$fa") r_mm+=("$mm") r_fiton+=("$fiton")
done

work=
srv=
if [ "$dry" != 1 ]; then
    : "${GGUF:?}"
    for i in "${!r_backend[@]}"; do
        [ "${r_mm[$i]}" = 0 ] || : "${MMPROJ:?}"
        case ${r_backend[$i]} in
            rocm) : "${ROCM_BIN:?}" ;;
            vulkan) : "${VULKAN_BIN:?}" ;;
        esac
    done
    work=$(mktemp -d)
fi

stop_server() {
    [ -n "$srv" ] || return 0
    kill "$srv" 2>/dev/null || true
    for _ in $(seq 1 60); do
        kill -0 "$srv" 2>/dev/null || break
        sleep 1 & wait $!
    done
    kill -KILL "$srv" 2>/dev/null || true
    wait "$srv" 2>/dev/null || true
    srv=
}
# shellcheck disable=SC2329 # invoked via trap
cleanup() {
    stop_server
    if [ -n "$work" ]; then rm -rf -- "$work"; fi
}
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 130' INT
trap cleanup EXIT

if [ "$dry" != 1 ]; then
    if curl -fsS --max-time 5 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
        echo "port $port already in use" >&2
        exit 1
    fi
    declare -A shown
    for backend in "${r_backend[@]}"; do
        [ -z "${shown[$backend]:-}" ] || continue
        shown[$backend]=1
        echo "# $backend: $("${bin[$backend]}/bin/llama-server" --version 2>&1 | grep -i '^version' || true)"
    done
    printf '# backend\tctx\tub\tfa\tmm\tfiton\tn_ctx_train\tfa_enabled\tmodel_MiB\tkv_MiB\tcompute_MiB\thost_compute_MiB\tstatus\n'
fi

# Prints one TSV line: n_ctx_train fa_enabled model kv compute host_compute (NA when absent). Only the last round of
# model/compute buffer lines counts so a --fit probe pass does not double the sums (a repeated model buffer also
# restarts the KV sums); KV lines are summed because a sliding-window cache logs a second line per device. Buffers logged after the multimodal projector starts belong to it.
parse_log() {
    awk '
    {
        l = tolower($0)
        if (nct == "" && match(l, /n_ctx_train[ \t]*=[ \t]*[0-9]+/)) { s = substr(l, RSTART, RLENGTH); sub(/.*=[ \t]*/, "", s); nct = s }
        if (nct == "" && match(l, /n_ctx_train \([0-9]+\)/)) { s = substr(l, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); nct = s }
        if (match(l, /flash attention was auto, set to [a-z0-9]+/)) { s = substr(l, RSTART, RLENGTH); n = split(s, w, " "); fa_set = w[n] }
        if (match(l, /flash attention (enabled|disabled)/)) { s = substr(l, RSTART, RLENGTH); n = split(s, w, " "); fa_set = w[n] }
        if (match(l, /flash_attn[ \t]*=[ \t]*[a-z0-9_]+/)) { s = substr(l, RSTART, RLENGTH); sub(/.*=[ \t]*/, "", s); fa_raw = s }
        if (l ~ /mtmd_context|mtmd_backends|alloc_compute_meta/) stop = 1
        if (stop) next
        if (match($0, /[^ \t]+[ \t]+(model|KV|compute) buffer size[ \t]*=[ \t]*[0-9.]+[ \t]*MiB/)) {
            s = substr($0, RSTART, RLENGTH)
            sub(/=/, " = ", s)
            sub(/MiB/, " MiB", s)
            n = split(s, a, /[ \t]+/)
            dev = a[1]; kind = a[2]; val = a[n - 1] + 0
            host = (dev ~ /Host/ || dev == "CPU" || dev ~ /^CPU_/)
            if (kind != "KV" && ((kind SUBSEP dev) in seen)) {
                for (k in seen) { split(k, p, SUBSEP); if (p[1] == kind) delete seen[k] }
                sum[kind] = 0; hsum[kind] = 0; gseen[kind] = 0; hseen[kind] = 0
                if (kind == "model") { sum["KV"] = 0; hsum["KV"] = 0; gseen["KV"] = 0; hseen["KV"] = 0 }
            }
            seen[kind, dev] = 1
            if (host) { hsum[kind] += val; hseen[kind] = 1 } else { sum[kind] += val; gseen[kind] = 1 }
        }
    }
    END {
        v = (fa_set != "") ? fa_set : fa_raw
        if (v == "") v = "NA"
        else if (v ~ /^(enabled|on|1|true)$/) v = "on"
        else if (v ~ /^(disabled|off|0|false)$/) v = "off"
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", (nct == "" ? "NA" : nct), v, \
            (gseen["model"] ? sprintf("%.2f", sum["model"]) : "NA"), \
            (gseen["KV"] ? sprintf("%.2f", sum["KV"]) : "NA"), \
            (gseen["compute"] ? sprintf("%.2f", sum["compute"]) : "NA"), \
            (hseen["compute"] ? sprintf("%.2f", hsum["compute"]) : "NA")
    }' "$1"
}

# True once a GPU compute buffer line is logged; --fit rows wait for /health because the probe pass logs the same lines.
ready() { # fiton log
    if [ "$1" = 1 ]; then
        curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1
    else
        awk '/compute buffer size/ && !/Host|CPU/ { f = 1 } /listening on/ { f = 1 } END { exit !f }' "$2"
    fi
}

declare -A n_ok px py lx ly ref512 dead
pred=
predict() { # key backend fa ctx ub
    local key=$1 n=${n_ok[$1]:-0} t1=0 t2=0
    pred=
    if [ "$n" -ge 2 ]; then
        pred=$(awk -v x1="${px[$key]}" -v y1="${py[$key]}" -v x2="${lx[$key]}" -v y2="${ly[$key]}" -v x="$4" \
            'BEGIN { printf "%d", y2 + (y2 - y1) / (x2 - x1) * (x - x2) + 0.5 }')
        return
    fi
    if [ "$5" != 512 ]; then t1=${ref512[$2|$3|$4]:-0}; fi
    if [ "$n" = 1 ]; then t2=$(awk -v y="${ly[$key]}" -v x="$4" -v x1="${lx[$key]}" 'BEGIN { print y * x / x1 }'); fi
    pred=$(awk -v a="$t1" -v b="$t2" -v ub="$5" \
        'BEGIN { s = (ub < 2048 ? ub : 2048) / 512; p = (a * s > b) ? a * s : b; if (p > 0) printf "%d", p + 0.5 }')
}

record_ok() { # total MiB of a finished (or, in a dry run, nominal) row of the current key
    if [ "${n_ok[$key]:-0}" -ge 1 ]; then px[$key]=${lx[$key]} py[$key]=${ly[$key]}; fi
    lx[$key]=$ctx ly[$key]=$1
    n_ok[$key]=$(("${n_ok[$key]:-0}" + 1))
    if [ "$ub" = 512 ]; then ref512[$backend|$fa|$ctx]=$1; fi
}

emit() { # status
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$backend" "$ctx" "$ub" "$fa" "$mm" "$fiton" "$nct" "$fae" "$model" "$kv" "$comp" "$host" "$1"
}

over_guard() { awk -v a="$1" -v g="$guard" 'BEGIN { exit !(a > g) }'; }

for i in "${!r_backend[@]}"; do
    backend=${r_backend[$i]} ctx=${r_ctx[$i]} ub=${r_ub[$i]} fa=${r_fa[$i]} mm=${r_mm[$i]} fiton=${r_fiton[$i]}
    key="$backend|$fa|$ub|$mm$fiton"
    nct=NA fae=NA model=NA kv=NA comp=NA host=NA

    args=(-m "$gguf")
    if [ "$mm" = 1 ]; then args+=(--mmproj "$mmproj"); fi
    args+=(-ngl 99 -c "$ctx" -ub "$ub")
    if [ "$fa" != auto ]; then args+=(-fa "$fa"); fi
    if [ "$fiton" = 1 ]; then args+=(--fit on); else args+=(--fit off); fi
    args+=(--parallel 1 --no-webui --port "$port" --jinja -lv 4) # -lv 4: buffer sizes are not logged at the default level 3

    if [ -n "${dead[$key]:-}" ]; then
        emit "skipped(series stopped)"
        continue
    fi

    predict "$key" "$backend" "$fa" "$ctx" "$ub"
    if [ -n "$pred" ] && over_guard "$pred"; then
        dead[$key]=1
        emit "skipped(predicted $pred MiB)"
        continue
    fi
    if [ -z "$pred" ] && [ "${n_ok[$key]:-0}" = 0 ] && [ "$ctx" -gt 8192 ]; then
        dead[$key]=1
        emit "skipped(no prediction above ctx 8192)"
        continue
    fi

    if [ "$dry" = 1 ]; then
        echo "would run: setpriv --pdeathsig KILL -- ${bin[$backend]}/bin/llama-server ${args[*]}"
        record_ok 1
        continue
    fi

    log=$work/$i.log
    setpriv --pdeathsig KILL -- "${bin[$backend]}/bin/llama-server" "${args[@]}" >"$log" 2>&1 &
    srv=$!
    status=timeout
    for _ in $(seq 1 600); do
        alive=1
        kill -0 "$srv" 2>/dev/null || alive=0
        if ready "$fiton" "$log"; then
            if [ "$fiton" = 0 ]; then sleep 3 & wait $!; fi
            status=ok
            break
        elif [ "$alive" = 0 ]; then
            status=server_exited
            break
        fi
        sleep 1 & wait $!
    done
    stop_server
    # Debug aid for checking the parser against a real log; the dir is outside the repo and never committed.
    if [ -n "${KEEP_LOGS:-}" ]; then cp "$log" "$KEEP_LOGS/$i-$backend-$ctx-$ub-$fa.log"; fi

    IFS=$'\t' read -r nct fae model kv comp host < <(parse_log "$log")
    if [ "$status" = ok ] && [ "$comp" = NA ]; then status=no_compute_line; fi
    if [ "$status" = ok ]; then
        total=$(awk -v a="$comp" -v b="$host" 'BEGIN { printf "%.2f", a + (b == "NA" ? 0 : b) }')
        record_ok "$total"
        if over_guard "$total"; then dead[$key]=1; fi
    else
        dead[$key]=1
    fi
    emit "$status"
done
