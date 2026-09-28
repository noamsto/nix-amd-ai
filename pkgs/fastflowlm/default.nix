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
  # (#175), and by the conformance runs' startup probe (#178):
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
  #     (#171) and refuses any tag but the loaded one.
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
  # None of the patches carries attribution: require_field, safe_dump, the
  # model-identity checks and the embedding task-prompt mapping are ported
  # from OpenFlowLM-Next (Vegard Berget) -- the Co-authored-by trailer for
  # that is on the branch commit per this repo's CLAUDE.md, not here. Still
  # unfixed on ROCm/FastFlowLM main as of v1.0.6; drop once upstream fixes
  # request validation, the NPU-lock leak, the status mapping, model
  # substitution, leaking exception text, ignoring the task prompt, and
  # reporting the no-model sentinel in /api/ps. A bump that breaks any patch
  # fails the build rather than silently losing it.
  patches = [
    ./patches/server-error-handling.patch
    ./patches/request-validation.patch
    ./patches/model-identity.patch
    ./patches/no-exception-text.patch
    ./patches/embed-task-prompt.patch
    ./patches/ps-loaded-models.patch
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
