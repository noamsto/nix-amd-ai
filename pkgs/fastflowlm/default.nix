{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  boost,
  curl,
  fftw,
  fftwFloat,
  fftwLongDouble,
  ffmpeg,
  readline,
  libuuid,
  libdrm,
  cargo,
  rustc,
  rustPlatform,
  autoPatchelfHook,
  xrt,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "fastflowlm";
  version = "1.0.6";

  src = fetchFromGitHub {
    owner = "ROCm";
    repo = "FastFlowLM";
    rev = "v${finalAttrs.version}";
    hash = "sha256-5w2mZApaudZEVP9sQujt/nf+u/P0mu2/tiMK3cq6FH4=";
    fetchSubmodules = true;
  };

  # flm serve's request handling has bugs, found by running OpenFlowLM-Next's
  # server-api conformance suite against it (#164, #171, #173), by review
  # (#175, #187), and by the conformance runs' startup probe (#178):
  #   - server-error-handling.patch: a malformed request body could throw
  #     twice while the server built its own error response, escaping every
  #     catch before the NPU lock was released and wedging it permanently
  #     (fixed with an RAII guard); and error.code was mapped to an HTTP
  #     status only for an object with a numeric code, so a bare-string
  #     error (or an object with a string code, from
  #     request-validation.patch) stayed HTTP 200 -- supersedes #157, whose
  #     numeric-code mapping this keeps, plus a 400 default for other shapes.
  #   - request-validation.patch: rest_handler.cpp read required fields with
  #     `request["field"]` on a const json&, undefined behavior for a missing
  #     key (JSON_ASSERT is compiled out in release builds) that segfaults or
  #     returns garbage instead of throwing. Checks presence and type first.
  #   - model-identity.patch (#173): a request naming a model tag the build
  #     does not know evicted the served model, loaded llama3.2:1b in its
  #     place, and answered under the requested tag; /v1/embeddings likewise
  #     labelled the loaded model's vectors with whatever name was asked for.
  #     The tag is now resolved before anything is unloaded: unknown, empty,
  #     "model-faker" and non-chat tags get 400 model_not_found, and a known
  #     model that fails to load gets 500 (a "server_error" type now maps to
  #     500 in the status mapping above). An omitted `model` is still served
  #     by the loaded chat model; /v1/embeddings still requires `model`
  #     (#171) and refuses any tag but the loaded one. A model_list.json entry
  #     with a missing or non-string `details.family` now fails the load as
  #     500 model_load_failed, not a 400 (#181).
  #   - no-exception-text.patch (#175): handlers built client error bodies
  #     from a caught exception's e.what(), which for nlohmann errors
  #     reflects request bytes and library internals. Bodies now carry a
  #     fixed message and e.what() goes to the server log: a json::exception,
  #     or any exception from a catch around prompt processing (where a chat
  #     template rejects the conversation), gets 400 invalid_request_error
  #     "Invalid request", as those catches did before; anything else gets
  #     500 server_error "Internal error". A malformed max_prefill_len or
  #     model path entry in model_list.json now fails the model load (500
  #     model_load_failed) rather than reaching the handler as a JSON error.
  #   - embed-task-prompt.patch (#174): handle_embeddings ignored the
  #     request's prompt_name/task_type and always embedded with task_query,
  #     so a document index was built as if every text were a query and
  #     nothing downstream could tell -- the vector is correctly shaped and
  #     normed either way. The REST names are now mapped onto the model's
  #     task enum (OpenFlowLM-Next's task_names/resolve_task/task_policy),
  #     and an unknown or non-string task is refused 400 invalid_value. A
  #     model that declares no prompt names (embed-gemma: hardcoded prefixes)
  #     keeps task_query when the request names none; a model that declares
  #     prompt names would require one (missing_required_parameter).
  #   - ps-loaded-models.patch (#178): GET /api/ps built its entry from
  #     current_model_tag unconditionally, so with no chat model loaded (flm
  #     serve with no tag, a non-chat startup tag such as embed-gemma:300m,
  #     or after a failed load) it looked up the "model-faker" sentinel -- a
  #     missing-key read on a const json, undefined behavior that answered
  #     400 -- and since GET /api/ps isn't serialized by the NPU lock, the
  #     same UB was reachable mid-load, when the new engine is set before
  #     current_model_tag. It now lists the chat model only when a chat
  #     engine is loaded under a real tag ({"models": []} otherwise), and
  #     like Ollama also lists a loaded --embed model. Whisper (--asr) is
  #     not listed.
  #   - chat-decode-fault.patch (#180): non-streaming /api/chat ran
  #     generate_with_prompt() -- prefill then decode -- inside a catch that
  #     answered any exception 400 invalid_request_error, so a decode-time
  #     NPU/runtime fault was reported as a non-retryable client error. The
  #     catch now answers 400 only while meta_info.prompt_tokens is still 0
  #     (template/prefill) and 500 server_error after. The insert()+generate()
  #     split the other handlers use was not taken because it would change
  #     the answer for Qwen3.5 and Qwen3.6-MoE (their generate() forces think
  #     tokens) and GPT-OSS (generate_with_prompt adds the
  #     <|start|>assistant...<|end|> wrapper).
  #   - stream-chat-generate.patch (#187): streaming /api/chat ran insert()
  #     twice and never generate(). The second insert() found the whole
  #     prompt already in the token history, prefilled nothing and sampled
  #     an empty logits buffer, so every streaming /api/chat request
  #     segfaulted flm serve. The streaming branch now runs insert() then
  #     generate(), as streaming /api/generate and /v1/chat/completions do,
  #     so for Qwen3.5, Qwen3.6-MoE and GPT-OSS it can answer differently
  #     from non-streaming /api/chat, for the reasons above.
  #   - ps-serving-snapshot.patch (#184): GET /api/ps is not serialised by
  #     the NPU lock, and read auto_chat_engine and current_model_tag while an
  #     NPU route's ensure_model_loaded reset and reassigned them -- a data
  #     race, undefined behavior. It now reads a tag ensure_model_loaded
  #     publishes under its own mutex, held only for the assignment (never
  #     across a load), so /api/ps does not wait on a load. The tag is
  #     cleared before the old engine is torn down and set once the new one
  #     has loaded, so during a swap /api/ps answers [] rather than the
  #     outgoing model. POST /v1/completions and /api/embeddings ran without
  #     the NPU lock (the first even swapped models) and now take it; and the
  #     lock is released when the handler returns, not when it sends its
  #     response, because handlers still call clear_context() on the engine
  #     after sending.
  #   - connection-slot-release.patch (#194): flm serve caps concurrent
  #     connections at 10, but a streaming client that disconnected mid-stream
  #     never gave its slot back. send_chunk_data's write-error branch had its
  #     active_connections_.fetch_sub(1) commented out, and it returns before
  #     the is_final branch, which was the only other streaming release. Ten
  #     such clients left the counter at the cap and every new connection was
  #     refused ("Connection limit reached (10)") until restart. The decrement
  #     cannot simply be uncommented: after the first failed write, every later
  #     chunk for that dead session re-enters the branch (the stream keeps
  #     producing, and ostream.finalize() sends a final chunk too), so a plain
  #     decrement per chunk underflows the counter and makes
  #     load() >= max_connections_ true forever. Every decrement site now goes
  #     through HttpSession::release_slot(), which exchanges an atomic
  #     once-per-session flag before fetch_sub, so a connection gives its slot
  #     back exactly once however it ends. Included are close_connection() (no
  #     caller in this tree), read_request's read-error path, write_response's
  #     async_write completion, the OPTIONS async_write error and the streaming
  #     header-write error (both leaked before), and handle_request's
  #     non-deferred abandoned-stream case, where generate() threw after chunks
  #     were sent and send_response() does nothing for a non-deferred session.
  #     The disconnect monitor needs no release of its own: it only cancels the
  #     token, and generation still reaches finalize() (or send_response() on
  #     the deferred path).
  #   - accept-loop-rearm.patch (#202): a client that reset its connection
  #     while it sat in the accept queue made the HttpSession constructor
  #     throw: accept() still returns the socket, and remote_endpoint() on it
  #     fails with ENOTCONN. The throw escaped do_accept's handler after the
  #     slot was counted and before do_accept() re-armed, so the slot leaked,
  #     that I/O thread ended, and flm serve never accepted another connection
  #     until restart. The constructor now uses the error_code overloads (the
  #     session then ends through read_request's error path, which releases
  #     the slot), and do_accept catches a throw from session setup, gives the
  #     slot back itself -- no session owns it yet -- and still re-arms.
  #   - cancel-client-disconnect.patch (#191): /api/generate, streaming
  #     /api/chat and /v1/completions never passed the request's
  #     cancellation predicate to insert()/generate(), so a client that
  #     disconnected left flm serve decoding to its token limit. They now
  #     pass the predicate, as /v1/chat/completions does, and like it reset
  #     the token only on the streaming branches (cancel-keep-early.patch
  #     drops those resets again): on a non-streaming one a reset erases the
  #     cancel of a client that left while queued, and nothing else would
  #     notice. Non-streaming /api/chat was left out, as generate_with_prompt()
  #     took no predicate; cancel-chat-nonstream.patch covers it.
  #   - model-list-download-check.patch (#181): ensure_model_loaded's pre-evict
  #     download check, downloader.is_model_downloaded(), reads the
  #     model_list.json entry's `name` and `flm_min_version` (and parses the
  #     model's local config.json) outside any try, so an entry missing either
  #     reached the handler as a JSON error and was answered 400
  #     invalid_request_error -- including an entry missing `name` that
  #     no-exception-text.patch meant to fail the load for, since this check
  #     runs before that one. The check now fails the load as 500
  #     model_load_failed, still before anything is unloaded.
  #   - cancel-chat-nonstream.patch (#200): non-streaming /api/chat runs
  #     generate_with_prompt(), which took no cancellation predicate in any
  #     model class, so a client that left kept it decoding to num_predict
  #     with the NPU held. The predicate is now a defaulted trailing
  #     parameter of generate_with_prompt in AutoModel and every override,
  #     forwarded to the insert()/generate() each already calls (Nanbeige's
  #     inlined decode loop gets the same check its generate() has);
  #     insert()+generate() was not an option (#180). A cancelled request
  #     answers like non-streaming /api/generate: {} when
  #     generate_with_prompt() returned nothing and no token was generated
  #     (a cancelled prefill, or a decode cancelled before any visible
  #     token), else 200 with the partial reply and done_reason "cancel".
  #     GPT-OSS always wraps its reply in <|start|>assistant...<|end|>, so a
  #     cancelled decode there gets the wrapper, not {}. No reset(), and a
  #     cancel never throws, so #180's 400/500 split is unaffected.
  #   - cancel-keep-early.patch (#201): the streaming handlers called
  #     cancellation_token->reset() before insert(), so a cancel that landed
  #     before the handler -- a client that left while queued behind a busy
  #     NPU (the disconnect monitor fires as soon as the request is
  #     dequeued), during a model load, or a POST /api/cancel (which only
  #     reaches the target since cancel-request-id.patch) -- was erased and
  #     the whole prefill ran. Upstream added reset() in v0.9.24/v0.9.25,
  #     when the token was already created fresh per request and only
  #     /api/cancel or a failed chunk write could set it; the disconnect
  #     monitor came in April 2026 (4ffe631). On a fresh token it can only
  #     erase a real cancel, so the resets are dropped (moving them before
  #     the monitor is armed would be the same no-op). The reset did mask one
  #     monitor false positive, by thread race: a client that half-closes its
  #     socket (shutdown(SHUT_WR)) after sending reads as EOF, and a streaming
  #     request from one now is always cancelled (9 of 10 survived before),
  #     as on every non-streaming branch already. Read-side EOF cannot tell a
  #     half-close from a close; lemond (libcurl), curl, requests and httpx
  #     were checked and do not half-close.
  #   - qwen3-5-omni-prefill-cancel.patch (#209): Qwen3_5_Omni::insert checks
  #     the cancellation predicate between prefill chunks and, on a cancel,
  #     sets stop_reason = CANCEL_DETECTED and breaks -- but still sampled
  #     from last_thinker_result (only assigned on the last chunk, so stale on
  #     an early cancel), bumped total_tokens, checkpointed and returned true.
  #     The caller then ran generate(), whose forced  thinking block does four
  #     NPU forwards and samples a token before its first cancel check, so a
  #     request cancelled mid-prefill decoded one token from a truncated
  #     prompt. It now returns false right after meta_info.prompt_tokens, as
  #     AutoModel::_shared_insert and Qwen3VL_Flash::insert do: before
  #     total_tokens, sampling and checkpoint, so no KV/checkpoint state is
  #     left half-updated. No model_list.json entry selects this class, so
  #     the fix is build-verified only (#209).
  #   - accept-error-backoff.patch (#207): do_accept re-armed unconditionally
  #     after its handler ran, including when async_accept had failed. A
  #     persistent accept error such as EMFILE/ENFILE -- once the process is
  #     out of file descriptors -- fails again the instant the next accept is
  #     armed, so the I/O thread spun on it and never let a descriptor free
  #     up. The error branch now waits 100 ms on a steady_timer before
  #     re-arming; the success path (including the connection-cap reject) is
  #     unchanged, and the pending connection stays in the backlog, so it is
  #     accepted once a descriptor is available. Measured on halo under
  #     descriptor exhaustion: the process burned ~3 cores before and stayed
  #     idle after, and it accepts again once the limit is restored.
  #   - model-list-entry-validation.patch (#204, #205): two more malformed
  #     model_list.json paths in ensure_model_loaded broke the #181 contract.
  #     A bare tag (no ":size") whose size map is an empty object made
  #     rectify_model_tag() read end().key() (undefined behavior), and a
  #     non-object size map threw invalid_iterator answered 400; it now
  #     throws std::runtime_error for a missing, non-object or empty size
  #     map, caught before anything is unloaded and answered 500
  #     model_load_failed (#205). And an entry with a missing or non-array
  #     `files` had get_missing_files() swallow the type_error and report
  #     nothing missing, so a model not on disk reached
  #     LM_Config::_load_json's exit(1) and killed the process; the selected
  #     chat entry's `files` is now validated up front (a non-empty array of
  #     strings that lists config.json), so the same malformed entry is
  #     refused 500 model_load_failed without unloading (#204).
  #   - cancel-request-id.patch (#210): every route, POST /api/cancel
  #     included, registered its own cancellation token under the body's
  #     request_id. A cancel therefore overwrote its target's registry slot,
  #     cancelled itself, answered {"cancelled": true} and erased the slot:
  #     it never stopped any request, and left the target uncancellable.
  #     /api/cancel's request_id is now only the target. Fixing that alone
  #     would have made a request without a request_id cancellable by anyone
  #     guessing its id, "req_" + a global counter that every route, even a
  #     readiness poll, advanced; default ids are now 128 random bits from
  #     getrandom(2), hex, req_ prefix kept. They are never returned to the
  #     client, so such a request is cancellable only by client disconnect.
  #     A caller-supplied request_id is still used verbatim, and anyone who
  #     knows it can cancel it: /api/cancel has no ownership check.
  # None of the patches carries attribution: require_field, safe_dump, the
  # model-identity checks and the embedding task-prompt mapping are ported
  # from OpenFlowLM-Next (Vegard Berget) -- the Co-authored-by trailer for
  # that is on the branch commit per this repo's CLAUDE.md, not here.
  # Still unfixed on ROCm/FastFlowLM main as of v1.0.6; drop once upstream
  # fixes request validation, the NPU-lock leak, the status mapping, model
  # substitution, leaking exception text, ignoring the task prompt, reporting
  # the no-model sentinel in /api/ps, classifying /api/chat decode faults as
  # client errors, streaming /api/chat's double insert, the unsynchronised
  # /api/ps reads, the unlocked /v1/completions and /api/embeddings, and
  # releasing the NPU lock before a handler is done with the engine (the last
  # four still on main at 39ff855632), leaking a connection slot when a
  # streaming client disconnects (also still on main; see also
  # ROCm/FastFlowLM#680), a pre-accept reset killing the accept loop (on main
  # at 39ff855632), ignoring a client disconnect outside
  # /v1/chat/completions, answering a malformed model_list.json entry as a
  # client error, ignoring a prefill cancel in Qwen3_5_Omni::insert,
  # ignoring a disconnect on non-streaming /api/chat,
  # erasing a cancel that lands before a streaming handler starts (the last
  # two on main at ef60a5f, the latter in /v1/chat/completions), exiting on a
  # model_list.json entry with no `files` and reading end().key() for a bare
  # tag with no size variants, and /api/cancel cancelling itself instead of
  # its target. A bump that breaks any patch fails the build rather than
  # silently losing it.
  patches = [
    ./patches/server-error-handling.patch
    ./patches/request-validation.patch
    ./patches/model-identity.patch
    ./patches/no-exception-text.patch
    ./patches/embed-task-prompt.patch
    ./patches/ps-loaded-models.patch
    ./patches/chat-decode-fault.patch
    ./patches/stream-chat-generate.patch
    ./patches/ps-serving-snapshot.patch
    ./patches/connection-slot-release.patch
    ./patches/accept-loop-rearm.patch
    ./patches/cancel-client-disconnect.patch
    ./patches/model-list-download-check.patch
    ./patches/cancel-chat-nonstream.patch
    ./patches/cancel-keep-early.patch
    ./patches/qwen3-5-omni-prefill-cancel.patch
    ./patches/accept-error-backoff.patch
    ./patches/model-list-entry-validation.patch
    ./patches/cancel-request-id.patch
  ];

  cargoDeps = rustPlatform.importCargoLock {
    lockFile = ./Cargo.lock;
  };

  cargoRoot = "third_party/tokenizers-cpp/rust";

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    cargo
    rustc
    rustPlatform.cargoSetupHook
    autoPatchelfHook
  ];

  buildInputs = [
    boost
    curl
    fftw
    fftwFloat
    fftwLongDouble
    ffmpeg
    readline
    libuuid
    libdrm
    stdenv.cc.cc.lib
    xrt
  ];

  postPatch = ''
    # Cargo.lock is not committed upstream; inject our copy
    cp ${./Cargo.lock} third_party/tokenizers-cpp/rust/Cargo.lock
  '';

  dontUseCmakeConfigure = true;

  configurePhase = ''
    runHook preConfigure
    cmake -S src -B src/build \
      -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DFLM_VERSION="${finalAttrs.version}" \
      -DNPU_VERSION="32.0.203.304" \
      "-DXRT_INCLUDE_DIR=${xrt}/opt/xilinx/xrt/include" \
      "-DXRT_LIB_DIR=${xrt}/opt/xilinx/xrt/lib" \
      -DCMAKE_INSTALL_PREFIX=$out \
      -DCMAKE_XCLBIN_PREFIX=$out/share/flm
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ninja -C src/build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    ninja -C src/build install
    runHook postInstall
  '';

  meta = {
    description = "NPU-optimized LLM runtime for AMD Ryzen AI";
    homepage = "https://github.com/ROCm/FastFlowLM";
    # Source is MIT; the NPU kernels in share/flm are proprietary (see TERMS.md).
    license = [lib.licenses.mit lib.licenses.unfree];
    platforms = ["x86_64-linux"];
    mainProgram = "flm";
  };
})
