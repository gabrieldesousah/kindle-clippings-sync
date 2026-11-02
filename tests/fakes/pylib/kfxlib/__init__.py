"""kfxlib FALSO, so para os testes (o de verdade e GPL e instalado a parte).

O "livro" e um JSON: {"title", "authors", "chunks": [[pid, eid, offset, len, texto]],
"locs": [pid...], "toc": [[rotulo, eid, offset]]}. Arquivo que comeca com
"DRMION" simula livro protegido.
"""
import json


class _Chunk(object):
    def __init__(self, pid, eid, off, length, text):
        self.pid, self.eid, self.eid_offset, self.length, self.text = pid, eid, off, length, text


class _Loc(object):
    def __init__(self, pid):
        self.pid = pid


class _Frag(object):
    def __init__(self, value):
        self.value = value


class _Frags(object):
    def __init__(self, toc):
        entries = [{"$241": {"$244": lab}, "$246": {"$155": eid, "$143": off}} for lab, eid, off in toc]
        self._nav = [_Frag([{"$392": [{"$235": "$212", "$247": entries}]}])]

    def get_all(self, ftype):
        return self._nav if ftype == "$389" else []


class _Meta(object):
    def __init__(self, d):
        self.title = d.get("title", "")
        self.authors = d.get("authors", [])


class YJ_Book(object):
    def __init__(self, path):
        with open(path, "rb") as f:
            raw = f.read()
        if raw.startswith(b"DRMION"):
            raise Exception("Book is DRM-protected")
        self.d = json.loads(raw.decode("utf-8"))
        self.fragments = _Frags(self.d.get("toc", []))

    def decode_book(self):
        return None

    def collect_content_position_info(self):
        return [_Chunk(*c) for c in self.d["chunks"]]

    def collect_position_map_info(self):
        return None

    def collect_location_map_info(self, _pos):
        return [_Loc(p) for p in self.d.get("locs", [])]

    def get_metadata(self):
        return _Meta(self.d)
