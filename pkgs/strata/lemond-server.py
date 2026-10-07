import os
import sys

sys.path.insert(0, os.getcwd())
from serve import server  # noqa: E402

assert hasattr(server.Vision, "load")
_load = server.Vision.load


# lemond forwards client bodies unchanged, so Strata's local-file and URL image
# loading would read files and make requests as the service user.
def load(source):
    if not isinstance(source, str) or not source.startswith("data:"):
        raise ValueError("images must be sent as data: URLs; file paths and http(s) URLs are not read behind lemond")
    return _load(source)


server.Vision.load = staticmethod(load)
sys.exit(server.main())
