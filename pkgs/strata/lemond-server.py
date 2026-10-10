import os
import sys

sys.path.insert(0, os.getcwd())
from serve import server  # noqa: E402

assert hasattr(server.Vision, "load")
assert hasattr(server.Vision, "download")
_load = server.Vision.load


# lemond forwards client bodies unchanged, so Strata's local-file and URL image
# loading would read files and make requests as the service user. Strata also
# calls download() directly, bypassing load().
def load(source):
    if not isinstance(source, str) or not source.startswith("data:"):
        raise ValueError("images must be sent as data: URLs; file paths and http(s) URLs are not read behind lemond")
    return _load(source)


def download(url):
    raise ValueError("image URLs are not fetched behind lemond; send images as data: URLs")


server.Vision.load = staticmethod(load)
server.Vision.download = staticmethod(download)

# Strata counts the tokens written while thinking and reports them on the Responses API, but openai_chunks' usage
# leaves them out, so chat clients see no reasoning tokens. openai_collect returns the final chunk's usage, so this
# covers streaming and non-streaming alike. With MCP rounds, Strata keeps only the last round's count.
_openai_chunks = server.openai_chunks


def openai_chunks(svc, req, ids, thinking, tools, max_new, cancel, run=None, force=None):
    reasoning = [0]
    source = run if run is not None else svc.run(ids, thinking, tools, max_new, req, cancel, force=force)

    def tap():
        for kind, x in source:
            if kind == "done":
                reasoning[0] = x.get("reasoning_tokens") or 0
            yield kind, x

    for c in _openai_chunks(svc, req, ids, thinking, tools, max_new, cancel, run=tap(), force=force):
        if c and c.get("usage") and reasoning[0]:
            c["usage"]["completion_tokens_details"] = {"reasoning_tokens": reasoning[0]}
        yield c


server.openai_chunks = openai_chunks
sys.exit(server.main())
