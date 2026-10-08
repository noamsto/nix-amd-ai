# Strata's pack, MTP runtime and mmproj are built outside the store (the pack derives from ~100 GiB of runtime GGUF
# shards; the MTP source is a 4.9 GiB range-read download). This is the oneshot `strata-prepare` unit's payload: it
# runs the pinned Strata's own tools against `strata.model` when the outputs are missing or stale, builds into a
# staging dir and swaps, and writes a stamp last. Two stamps, so a model change rebuilds only the pack and a Strata
# or ggml revision bump rebuilds both.
{
  writeShellApplication,
  coreutils,
  strataPkg,
  strataRev,
  ggmlRev,
}:
writeShellApplication {
  name = "strata-prepare";
  runtimeInputs = [coreutils];
  meta.description = "Build Strata's pack and MTP runtime from strata.model (no GPU)";

  text = ''
    python=${strataPkg.passthru.python}/bin/python3
    tools=${strataPkg}/share/strata/tools
    data=${strataPkg}/share/strata/data

    state=''${STRATA_STATE_DIR:-/var/lib/strata}
    model=''${STRATA_MODEL:?STRATA_MODEL is required}
    engine_rev=''${STRATA_ENGINE_REV:-${strataRev}}
    ggml_rev=''${STRATA_GGML_REV:-${ggmlRev}}

    pack_dir=$state/pack
    mtp_dir=$state/mtp/rt
    pack_stamp=$state/pack.stamp
    mtp_stamp=$state/mtp.stamp

    export STRATA_GGUF_PY=${strataPkg.passthru.ggml}/gguf-py

    tmp_pack=
    tmp_mtp=
    cleanup() {
      [ -n "$tmp_pack" ] && rm -rf "$tmp_pack"
      [ -n "$tmp_mtp" ] && rm -rf "$tmp_mtp"
      return 0
    }
    trap cleanup EXIT

    # Every shard beside the first, so a new GGUF snapshot at a different path or with different shard sizes
    # rebuilds. Lexicographic order keeps the stamp deterministic.
    shard_lines() {
      local dir base prefix f found
      dir=$(dirname "$model")
      base=$(basename "$model")
      prefix=''${base%-00001-of-*.gguf}
      if [ "$prefix" = "$base" ]; then
        printf 'shard:%s=%s\n' "$base" "$(stat -c %s "$model")"
        return
      fi
      found=0
      for f in "$dir/$prefix"-*-of-*.gguf; do
        [ -e "$f" ] || continue
        found=1
        printf 'shard:%s=%s\n' "$(basename "$f")" "$(stat -c %s "$f")"
      done
      if [ "$found" = 0 ]; then
        printf 'shard:%s=%s\n' "$base" "$(stat -c %s "$model")"
      fi
    }

    want_pack=$(printf 'engine=%s\nggml=%s\nmodel=%s\n' "$engine_rev" "$ggml_rev" "$model"; shard_lines)
    want_mtp=$(printf 'engine=%s\nggml=%s\n' "$engine_rev" "$ggml_rev")

    mkdir -p "$state"

    if [ -d "$pack_dir" ] && [ -f "$pack_stamp" ] && [ "$(cat "$pack_stamp")" = "$want_pack" ]; then
      echo "strata-prepare: pack up to date"
    else
      echo "strata-prepare: building pack from $model"
      tmp_pack=$state/.prepare-pack.$$
      rm -rf "$tmp_pack"
      mkdir -p "$tmp_pack"
      "$python" "$tools/iq_pack.py" --gguf "$model" --out "$tmp_pack/pack" --compat-bf16
      rm -rf "$pack_dir"
      mv "$tmp_pack/pack" "$pack_dir"
      rm -rf "$tmp_pack"
      tmp_pack=
      printf '%s\n' "$want_pack" > "$pack_stamp.tmp"
      mv "$pack_stamp.tmp" "$pack_stamp"
    fi

    if [ -d "$mtp_dir" ] && [ -f "$mtp_stamp" ] && [ "$(cat "$mtp_stamp")" = "$want_mtp" ]; then
      echo "strata-prepare: MTP runtime up to date"
    else
      echo "strata-prepare: building MTP runtime"
      tmp_mtp=$state/.prepare-mtp.$$
      rm -rf "$tmp_mtp"
      mkdir -p "$tmp_mtp"
      "$python" "$tools/mtp_fetch.py" fetch --out "$tmp_mtp/mtp"
      "$python" "$tools/mtp_pack.py" --src "$tmp_mtp/mtp" --experts q2_0 --out "$tmp_mtp/mtp/mtp-q2_0.gguf"
      "$python" "$tools/mtp_rt.py" --gguf "$tmp_mtp/mtp/mtp-q2_0.gguf" --out "$tmp_mtp/mtp/rt"
      cp "$data/draft_vocab.bin" "$tmp_mtp/mtp/rt/draft_vocab.bin"
      # The raw BF16 tensors and the intermediate GGUF are only inputs to the runtime dir.
      rm -rf "$tmp_mtp/mtp/tensors" "$tmp_mtp/mtp/mtp-q2_0.gguf" "$tmp_mtp/mtp/mtp-manifest.json"
      rm -rf "$state/mtp"
      mv "$tmp_mtp/mtp" "$state/mtp"
      rm -rf "$tmp_mtp"
      tmp_mtp=
      printf '%s\n' "$want_mtp" > "$mtp_stamp.tmp"
      mv "$mtp_stamp.tmp" "$mtp_stamp"
    fi
  '';
}
