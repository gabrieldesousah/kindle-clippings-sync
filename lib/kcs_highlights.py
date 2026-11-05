#!/usr/bin/env python3
"""kcs_highlights: destaques do Kindle a partir do banco de anotacoes do aparelho.

Desde o firmware 5.19.6 o Kindle deixou de acrescentar destaques novos ao
"My Clippings.txt". Eles continuam no aparelho, em
/system/ksdk/.annotations/<conta>/ksdk_annotation_v1.db (SQLite), mas so como
posicoes no livro, sem o texto. Este programa:

  select  roda DENTRO da sessao MTP (chamado pelo kcs-mtp-pull --then): le os
          bancos ja baixados e a arvore do aparelho e imprime "GET<TAB>caminho<TAB>
          destino" para os livros (.kfx) com destaques que ainda nao estao no cache
          ou mudaram (tamanho/data).
  render  roda depois da sessao: promove os livros baixados para o cache, junta os
          destaques ao estado (dedup por id + data de modificacao), recupera o texto
          com o kfxlib (instalado a parte, GPL v3, NAO faz parte deste repositorio) e
          escreve uma nota por livro. Sem kfxlib, sem o livro ou com livro protegido
          por DRM, a nota sai so com as posicoes.

Nunca escreve no Kindle. Compativel com Python 3.9+. Licenca MIT (como o projeto).
"""
import argparse
import base64
import bisect
import datetime
import hashlib
import json
import logging
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import unicodedata

KINDS = {1: "highlight", 3: "note"}  # datasets do ksdk: 1 destaque, 3 nota
BOOK_EXTS = (".kfx",)
ASIN_RE = re.compile(r"_([A-Z0-9]{10,40})\.(kfx|azw3|azw|mobi|pdf)$", re.I)


# --- utilidades ---------------------------------------------------------------
def die(msg):
    sys.stderr.write("kcs_highlights: %s\n" % msg)
    sys.exit(1)


def read_tree(path):
    """Linhas do kcs-mtp-pull --list: T id pai storage bytes mtime caminho."""
    items = []
    if not path or not os.path.isfile(path):
        return items
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 7:
                continue
            items.append({"type": parts[0], "id": parts[1], "size": int(parts[4] or 0),
                          "mtime": int(parts[5] or 0), "path": "\t".join(parts[6:])})
    return items


def find_dbs(db_dir):
    out = []
    for root, _dirs, files in os.walk(db_dir or ""):
        for fn in files:
            if fn == "ksdk_annotation_v1.db" and "/anonymous" not in root.replace(os.sep, "/"):
                out.append(os.path.join(root, fn))
    return sorted(out)


def open_ro(db):
    # Copia para um temporario: o arquivo baixado pode vir sem o -wal e nunca
    # queremos criar arquivos ao lado dele.
    tmp = tempfile.NamedTemporaryFile(prefix="kcs-db-", suffix=".db", delete=False)
    tmp.close()
    shutil.copyfile(db, tmp.name)
    con = sqlite3.connect("file:%s?mode=ro" % tmp.name, uri=True)
    return con, tmp.name


def book_id(dataset_id):
    return dataset_id.split("-", 1)[0]


def db_annotations(db):
    """{asin: [registro]} com destaques e notas atuais do banco."""
    out = {}
    con, tmp = open_ro(db)
    try:
        rows = con.execute(
            "select dataset, dataset_id, annotation_id, serialized_payload, modified_time "
            "from server_view where dataset in (1, 3)").fetchall()
        try:
            rows += con.execute(
                "select dataset, dataset_id, annotation_id, serialized_payload, modified_time "
                "from local_edit where dataset in (1, 3) and action != 3").fetchall()
        except sqlite3.Error:
            pass
    finally:
        con.close()
        os.unlink(tmp)
    seen = {}
    for ds, dsid, aid, payload, mtime in rows:
        try:
            d = json.loads(payload)
        except ValueError:
            continue
        asin = book_id(dsid)
        rec = {
            "id": aid,
            "kind": KINDS.get(ds, "highlight"),
            "start": int(d.get("start_position", {}).get("shortPosition", 0)),
            "end": int(d.get("end_position", {}).get("shortPosition", 0)),
            "start_long": d.get("start_position", {}).get("longPosition") or "",
            "end_long": d.get("end_position", {}).get("longPosition") or "",
            "created": int(d.get("created_time") or mtime or 0),
            "modified": int(d.get("last_modified") or mtime or 0),
            "content_type": (d.get("book_data") or {}).get("contentType", ""),
        }
        try:
            meta = json.loads(d.get("json_metadata") or "{}")
        except ValueError:
            meta = {}
        if meta.get("note_text"):
            rec["note_text"] = meta["note_text"]
        key = (asin, aid)
        if key not in seen or rec["modified"] >= seen[key]["modified"]:
            seen[key] = rec
    for (asin, _aid), rec in seen.items():
        out.setdefault(asin, []).append(rec)
    return out


def books_on_device(tree):
    """{asin: item da arvore} para os livros fora das pastas .sdr."""
    out = {}
    for it in tree:
        if it["type"] != "f" or ".sdr/" in it["path"] or not it["path"].startswith("/documents/"):
            continue
        m = ASIN_RE.search(it["path"])
        if not m:
            continue
        asin = m.group(1).upper()
        if it["path"].lower().endswith(BOOK_EXTS) or asin not in out:
            out[asin] = it
    return out


def cache_meta(cache, asin):
    try:
        with open(os.path.join(cache, "books", asin + ".meta"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# --- select (dentro da sessao MTP) -------------------------------------------
def cmd_select(a):
    tree = read_tree(a.tree or os.environ.get("KCS_TREE"))
    wanted = set()
    for db in find_dbs(a.db_dir):
        try:
            wanted.update(db_annotations(db).keys())
        except sqlite3.Error as e:
            sys.stderr.write("kcs_highlights: banco ilegivel %s: %s\n" % (db, e))
    dev = books_on_device(tree)
    n = 0
    for asin in sorted(wanted):
        it = dev.get(asin)
        if it is None or not it["path"].lower().endswith(BOOK_EXTS):
            continue
        meta = cache_meta(a.cache, asin)
        if meta and meta.get("size") == it["size"] and meta.get("mtime") == it["mtime"] and \
                os.path.isfile(os.path.join(a.cache, "books", asin + ".kfx")):
            continue
        dest = os.path.join(a.cache, "books", asin + ".kfx.new")
        sys.stdout.write("GET\t%s\t%s\n" % (it["path"], dest))
        n += 1
    sys.stdout.flush()
    sys.stderr.write("kcs_highlights: select: %d livro(s) com destaques, %d para baixar\n" % (len(wanted), n))
    return 0


# --- texto via kfxlib ------------------------------------------------------------
class KfxBook(object):
    def __init__(self, path, kfxlib_path):
        if kfxlib_path and kfxlib_path not in sys.path:
            sys.path.insert(0, kfxlib_path)
        logging.disable(logging.WARNING)
        from kfxlib import YJ_Book  # noqa: E402 (import tardio de proposito)
        b = YJ_Book(path)
        b.decode_book()
        def plain(v):
            return v if v is None or isinstance(v, int) else str(v)
        ch = []
        for c in b.collect_content_position_info():
            ch.append((int(c.pid), plain(c.eid), int(c.eid_offset), int(c.length),
                       None if c.text is None else str(c.text)))
        if not ch:
            raise ValueError("livro sem conteudo de texto")
        ch.sort(key=lambda c: c[0])
        self.chunks = ch
        self.starts = [c[0] for c in ch]
        try:
            self.locs = sorted(int(l.pid) for l in b.collect_location_map_info(b.collect_position_map_info()))
        except Exception:  # sem mapa de posicoes: sem numero de posicao
            self.locs = []
        self.total = ch[-1][0] + ch[-1][3]
        self.toc = []
        try:
            self.toc = self._toc(b)
        except Exception:
            self.toc = []
        self.title, self.authors = "", []
        try:
            md = YJ_Book(path).get_metadata()  # num objeto novo: no decodificado falha
            self.title = str(getattr(md, "title", "") or "")
            self.authors = [str(x) for x in (getattr(md, "authors", None) or [])]
        except Exception:
            pass

    def _toc(self, b):
        base = {}
        for eid, pid, off in ((c[1], c[0], c[2]) for c in self.chunks):
            base.setdefault(eid, set()).add(pid - off)
        out = []
        def walk(entries, depth):
            for e in entries or []:
                lab = e.get("$241")
                label = str(lab.get("$244")) if lab is not None and lab.get("$244") is not None else ""
                t = e.get("$246")
                if t is not None and label:
                    eid = t.get("$155")
                    eid = eid if isinstance(eid, int) else str(eid)
                    pids = base.get(eid)
                    if pids:
                        out.append((min(pids) + int(t.get("$143", 0) or 0), depth, label))
                walk(e.get("$247", []), depth + 1)
        for frag in b.fragments.get_all("$389"):
            for nav in frag.value:
                for cont in nav.get("$392", []):
                    if not hasattr(cont, "get"):
                        cont = b.fragments.get("$391", fid=cont).value
                    if str(cont.get("$235")) == "$212":
                        walk(cont.get("$247", []), 0)
        return sorted(out)

    def at(self, pid):
        i = bisect.bisect_right(self.starts, pid) - 1
        if i < 0:
            return None
        c = self.chunks[i]
        return (c[1], c[2] + pid - c[0]) if c[0] <= pid < c[0] + max(c[3], 1) else None

    def text(self, a, b):
        out, prev = [], None
        i = max(bisect.bisect_right(self.starts, a) - 1, 0)
        while i < len(self.chunks) and self.chunks[i][0] <= b:
            pid, eid, _off, ln, txt = self.chunks[i]
            if txt:
                s = max(a, pid) - pid
                e = min(b, pid + ln - 1) - pid + 1
                if e > s:
                    if prev is not None and eid != prev:
                        out.append("\n")
                    out.append(txt[s:e])
                    prev = eid
            i += 1
        return "".join(out)

    def location(self, pid):
        return bisect.bisect_right(self.locs, pid) if self.locs else 0

    def chapter(self, pid):
        best = ""
        for p, _d, label in self.toc:
            if p <= pid:
                best = label
            else:
                break
        return best


def long_pos(s):
    try:
        r = base64.b64decode(s)
        if len(r) >= 9 and r[0] == 1:
            return (int.from_bytes(r[1:5], "little"), int.from_bytes(r[5:9], "little"))
    except Exception:
        pass
    return None


# --- texto para o cofre (regras do CLAUDE.md: sem travessao, setas, aspas curvas) ---
_REPL = (("\u201c", '"'), ("\u201d", '"'), ("\u201e", '"'), ("\u2018", "'"), ("\u2019", "'"),
         ("\u2014", "-"), ("\u2013", "-"), ("\u2026", "..."), ("\u2192", "->"), ("\u2190", "<-"),
         ("\u2022", "-"), ("\u25cf", "-"), ("\u00a0", " "), ("\u00ad", ""), ("\u2248", "~"))


def clean(s):
    s = unicodedata.normalize("NFC", s or "")
    for x, y in _REPL:
        s = s.replace(x, y)
    # chamadas de nota de rodape logo apos pontuacao: "pensamentos.17", "vulnerabilidade.***"
    s = re.sub(r'(?<=[.,;:!?"\)])(\d{1,3}|\*{1,3})(?=\s|$)', "", s)
    s = re.sub(r"[ \t]+", " ", s)
    return "\n".join(l.strip() for l in s.split("\n")).strip()


def fmt_dt(ms):
    d = datetime.datetime.fromtimestamp(ms / 1000.0)
    return d.strftime("%d/%m/%Y às %H:%M")


def iso_dt(ms):
    return datetime.datetime.fromtimestamp(ms / 1000.0).strftime("%Y-%m-%dT%H:%M:%S")


def safe_name(title):
    t = clean(title)
    t = re.sub(r'[\\/:*?"<>|#^\[\]]', " ", t)
    t = re.sub(r"\s+", " ", t).strip(" .")
    return (t or "Sem título")[:150]


def split_title(raw, authors):
    """Titulos de documentos pessoais vem como "Titulo (Autor)"."""
    t = (raw or "").strip()
    m = re.match(r"^(.*\S)\s*\(([^()]*)\)$", t)
    if m:
        t, who = m.group(1), m.group(2).strip()
        if not authors:
            authors = [x.strip() for x in who.split(",") if x.strip()]
    return t, authors


# --- render (depois da sessao) -----------------------------------------------------
def promote(cache, tree_books):
    """Livros baixados como .kfx.new viram cache se o tamanho bater com o aparelho."""
    d = os.path.join(cache, "books")
    if not os.path.isdir(d):
        return
    for fn in os.listdir(d):
        if not fn.endswith(".kfx.new"):
            continue
        asin = fn[:-len(".kfx.new")]
        new = os.path.join(d, fn)
        it = tree_books.get(asin)
        if it is None or os.path.getsize(new) != it["size"]:
            os.unlink(new)
            continue
        os.replace(new, os.path.join(d, asin + ".kfx"))
        with open(os.path.join(d, asin + ".meta"), "w", encoding="utf-8") as f:
            json.dump({"size": it["size"], "mtime": it["mtime"], "path": it["path"]}, f)


def load_state(state_dir, asin):
    try:
        with open(os.path.join(state_dir, asin + ".json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"items": {}}


def save_state(state_dir, asin, st):
    os.makedirs(state_dir, exist_ok=True)
    p = os.path.join(state_dir, asin + ".json")
    with open(p + ".tmp", "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=1, sort_keys=True)
    os.replace(p + ".tmp", p)


def merge(st, recs):
    """Dedup por id + data de modificacao. Devolve (novos, alterados, ids_novos, ids_alterados)."""
    items = st.setdefault("items", {})
    new = changed = 0
    new_ids, changed_ids = [], []
    current = set()
    for r in recs:
        current.add(r["id"])
        old = items.get(r["id"])
        if old is None:
            items[r["id"]] = dict(r, removed=False)
            new += 1
            new_ids.append(r["id"])
        elif old.get("modified") != r["modified"] or old.get("removed"):
            items[r["id"]] = dict(r, removed=False)
            changed += 1
            changed_ids.append(r["id"])
    for aid, it in items.items():
        if aid not in current and not it.get("removed"):
            it["removed"] = True
            changed += 1
            changed_ids.append(aid)
    return new, changed, new_ids, changed_ids


def trim_text(t, n=300):
    t = (t or "").replace("\r\n", "\n").replace("\r", "\n").strip()
    if len(t) <= n:
        return t
    return t[: max(0, n - 1)].rstrip() + "..."


def build_note(asin, title, authors, items, book, reason, origin):
    hl = [i for i in items if i["kind"] == "highlight" and not i.get("removed")]
    notes = [i for i in items if i["kind"] == "note" and not i.get("removed")]
    removed = [i for i in items if i.get("removed")]
    verified = book is not None and all(i.get("check") != "MISMATCH" for i in items) and \
        all(i.get("text") or i.get("image") or i["kind"] == "note" for i in hl)
    last_mod = max([i["modified"] for i in items] or [0])
    author = " e ".join(clean(a) for a in authors) if authors else ""
    L = ["---", "tags:", "  - kindle", "  - leituras", "  - kindle-destaques",
         'titulo: "%s"' % clean(title).replace('"', "'"),
         'autor: "%s"' % author.replace('"', "'"),
         "kindle_id: %s" % asin,
         "destaques: %d" % len(hl), "notas: %d" % len(notes),
         "removidos_no_kindle: %d" % len(removed),
         "texto_verificado: %s" % ("true" if verified else "false"),
         "ultima_alteracao: %s" % (iso_dt(last_mod) if last_mod else ""),
         'origem: "%s"' % origin.replace('"', "'"),
         "---", "", "# %s" % clean(title), "",
         "Nota gerada automaticamente pelo kindle-clippings-sync a partir do banco de anotações do Kindle. "
         "Ela é reescrita quando os destaques mudam, então não vale a pena editá-la à mão.", ""]
    if author:
        L.append("- Autor: %s" % author)
    L.append("- Total: %d destaque%s e %d nota%s" % (len(hl), "" if len(hl) == 1 else "s",
                                                   len(notes), "" if len(notes) == 1 else "s"))
    if removed:
        L.append("- Removidos no Kindle (mantidos aqui, marcados): %d" % len(removed))
    if book is not None:
        L.append("- Texto: recuperado do próprio livro no Kindle (.kfx)%s" %
                 ("" if verified else "; algumas posições não conferiram, veja as marcações"))
    else:
        L.append("- Texto: indisponível (%s); só as posições no livro" % reason)
    L += ["- Origem: `%s`" % origin, "", "## Destaques", ""]
    cur = None
    by_pos = sorted(items, key=lambda i: (i["start"], 0 if i["kind"] == "highlight" else 1, i["id"]))
    attached = set()
    for n in notes:
        for h in hl:
            if h["start"] <= n["start"] <= h["end"]:
                h.setdefault("_notes", []).append(n)
                attached.add(n["id"])
                break
    for i in by_pos:
        if i["kind"] == "note" and i["id"] in attached:
            continue
        ch = clean(i.get("chapter") or "")
        if ch and ch != cur:
            L += ["### %s" % ch, ""]
            cur = ch
        if i["kind"] == "note":
            L.append("**Nota no Kindle:** %s" % clean(i.get("note_text", "")))
        else:
            t = clean(i.get("text") or "")
            if t:
                L += ["> " + p for p in t.split("\n")]
            elif i.get("image"):
                L.append("> _(destaque sobre uma imagem do livro, sem texto)_")
            else:
                L.append("> _(texto indisponível; posição no livro %d-%d)_" % (i["start"], i["end"]))
        loc = i.get("location") or ""
        meta = []
        meta.append(("Posição %s" % loc) if loc else ("Posição KFX %d" % i["start"]))
        meta.append(fmt_dt(i["created"]))
        if i.get("check") == "MISMATCH":
            meta.append("texto não conferido")
        if i.get("removed"):
            meta.append("removido no Kindle")
        if i["kind"] == "highlight":
            L += [">", "> <small>%s</small>" % " | ".join(meta)]
        else:
            L.append("<small>%s</small>" % " | ".join(meta))
        for n in i.get("_notes", []):
            L += ["", "**Nota no Kindle:** %s" % clean(n.get("note_text", ""))]
        L.append("")
    return "\n".join(L).rstrip("\n") + "\n"


def enrich(items, book):
    for i in items:
        i.pop("_notes", None)
        if book is None:
            continue
        a, b = i["start"], i["end"]
        if i["kind"] == "highlight":
            raw = book.text(a, b)
            i["text"] = raw
            i["image"] = not raw.strip()
        la, lb = book.location(a), book.location(b)
        i["location"] = "" if not la else (str(la) if la == lb else "%d-%d" % (la, lb))
        i["chapter"] = book.chapter(a)
        checks = []
        for key, pid in (("start_long", a), ("end_long", b)):
            lp = long_pos(i.get(key) or "")
            if lp:
                checks.append(book.at(pid) == lp)
        i["check"] = ("ok" if all(checks) else "MISMATCH") if checks else "n/a"


def backup_dbs(dbs, backups, state_dir, keep):
    if not backups:
        return 0
    n = 0
    for db in dbs:
        acct = os.path.basename(os.path.dirname(db))
        h = hashlib.sha256(open(db, "rb").read()).hexdigest()
        mark = os.path.join(state_dir, "db-%s.sha256" % acct)
        try:
            last = open(mark).read().strip()
        except OSError:
            last = ""
        if h == last:
            continue
        os.makedirs(backups, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H%M%S")
        dest = os.path.join(backups, "ksdk_annotation_v1 %s.db" % stamp)
        k = 2
        while os.path.exists(dest):
            dest = os.path.join(backups, "ksdk_annotation_v1 %s (%d).db" % (stamp, k))
            k += 1
        shutil.copyfile(db, dest)
        os.makedirs(state_dir, exist_ok=True)
        with open(mark, "w") as f:
            f.write(h + "\n")
        n += 1
    if keep and keep > 0:
        old = sorted(f for f in os.listdir(backups) if f.startswith("ksdk_annotation_v1 ") and f.endswith(".db"))
        for f in old[:-keep]:
            os.unlink(os.path.join(backups, f))
    return n


def write_summary(path, books, new_highlights, totals):
    if not path:
        return
    payload = {"books": books, "totals": totals, "new_highlights": new_highlights}
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    os.replace(path + ".tmp", path)


def cmd_render(a):
    tree = read_tree(a.tree)
    tree_books = books_on_device(tree)
    promote(a.cache, tree_books)
    dbs = find_dbs(a.db_dir)
    empty_totals = {"books": 0, "annotations": 0, "new": 0, "changed": 0}
    if not dbs:
        sys.stderr.write("kcs_highlights: nenhum banco de anotações baixado\n")
        print("DESTAQUES 0 0 0 0")
        write_summary(a.summary, [], [], empty_totals)
        return 0
    per_book = {}
    for db in dbs:
        for asin, recs in db_annotations(db).items():
            per_book.setdefault(asin, []).extend(recs)
    state_dir = os.path.join(a.state, "highlights")
    os.makedirs(a.out, exist_ok=True)
    nbooks = ntotal = nnew = nchanged = nwritten = 0
    books_out = []
    new_highlights = []
    note_rel = (a.note_rel or "").rstrip("/")
    for asin, recs in sorted(per_book.items()):
        st = load_state(state_dir, asin)
        new, changed, new_ids, _changed_ids = merge(st, recs)
        items = list(st["items"].values())
        by_id = {i["id"]: i for i in items}
        kfx = os.path.join(a.cache, "books", asin + ".kfx")
        book, reason = None, ""
        dev = tree_books.get(asin)
        if os.path.isfile(kfx):
            try:
                book = KfxBook(kfx, a.kfxlib)
            except ImportError:
                reason = "kfxlib não instalado"
            except Exception as e:  # DRM, formato desconhecido...
                reason = "livro protegido ou ilegível (%s)" % (str(e).split("\n")[0][:80] or type(e).__name__)
        elif dev is not None and not dev["path"].lower().endswith(BOOK_EXTS):
            reason = "formato %s não suportado" % os.path.splitext(dev["path"])[1]
        elif dev is not None:
            reason = "livro ainda não baixado do Kindle"
        else:
            reason = "livro não encontrado no Kindle"
        enrich(items, book)
        raw_title = (book.title if book is not None and book.title else "") or \
            (re.sub(ASIN_RE, "", os.path.basename(dev["path"])) if dev else "") or st.get("title") or asin
        title, authors = split_title(raw_title, book.authors if book is not None else [])
        if not authors and st.get("authors"):
            authors = st["authors"]
        st["title"], st["authors"] = title, authors
        content = build_note(asin, title, authors, items, book, reason, a.origin)
        name = st.get("note") or (safe_name(title) + ".md")
        path = os.path.join(a.out, name)
        old = None
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                old = f.read()
        if old != content:
            with open(path + ".tmp", "w", encoding="utf-8") as f:
                f.write(content)
            os.replace(path + ".tmp", path)
            nwritten += 1
        st["note"] = name
        save_state(state_dir, asin, st)
        hl = [i for i in items if i["kind"] == "highlight" and not i.get("removed")]
        notes = [i for i in items if i["kind"] == "note" and not i.get("removed")]
        note_file = "%s/%s" % (note_rel, name) if note_rel else name
        books_out.append({
            "title": clean(title),
            "note_file": note_file,
            "total_highlights": len(hl),
            "total_notes": len(notes),
            "new": new,
            "changed": changed,
        })
        for aid in new_ids:
            if len(new_highlights) >= 50:
                break
            it = by_id.get(aid)
            if not it or it.get("removed") or it.get("kind") != "highlight":
                continue
            text = it.get("text") or it.get("note_text") or ""
            if it.get("image") and not text:
                text = "(destaque sobre uma imagem do livro, sem texto)"
            new_highlights.append({
                "title": clean(title),
                "chapter": clean(it.get("chapter") or "") or None,
                "location": it.get("location") or None,
                "text": trim_text(clean(text), 300),
            })
        nbooks += 1
        ntotal += sum(1 for i in items if not i.get("removed"))
        nnew += new
        nchanged += changed
        sys.stderr.write("kcs_highlights: %s: %d anotações (%d novas, %d alteradas), texto: %s\n" %
                         (name, len(items), new, changed, "ok" if book is not None else reason))
    nb = backup_dbs(dbs, a.backups, a.state, a.max_backups)
    print("DESTAQUES %d %d %d %d %d" % (nbooks, ntotal, nnew, nwritten, nb))
    write_summary(a.summary, books_out, new_highlights,
                  {"books": nbooks, "annotations": ntotal, "new": nnew, "changed": nchanged})
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="kcs_highlights")
    sub = p.add_subparsers(dest="cmd")
    s = sub.add_parser("select")
    s.add_argument("--tree")
    s.add_argument("--db-dir", required=True)
    s.add_argument("--cache", required=True)
    r = sub.add_parser("render")
    r.add_argument("--tree")
    r.add_argument("--db-dir", required=True)
    r.add_argument("--cache", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--backups")
    r.add_argument("--state", required=True)
    r.add_argument("--kfxlib", default=os.environ.get("KCS_KFXLIB_PATH", ""))
    r.add_argument("--origin", default="Kindle: ksdk_annotation_v1.db")
    r.add_argument("--max-backups", type=int, default=0)
    r.add_argument("--summary", default="", help="grava um JSON com o resumo dos destaques (para o webhook)")
    r.add_argument("--note-rel", default="", help="prefixo relativo da nota dentro do cofre")
    a = p.parse_args(argv)
    if a.cmd == "select":
        return cmd_select(a)
    if a.cmd == "render":
        return cmd_render(a)
    p.print_help()
    return 64


if __name__ == "__main__":
    sys.exit(main())
