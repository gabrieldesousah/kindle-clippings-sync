#!/usr/bin/env python3
"""Monta um Kindle falso para os testes de destaques: banco ksdk, livros e arvore.

Uso: make-kindle-hl.py <dir-do-aparelho> <arquivo-arvore> [variante]
Variantes: base | edit (muda um destaque) | delete (apaga o primeiro) | newbook (livro mudou)
"""
import base64
import json
import os
import sqlite3
import sys

dev, tree_path = sys.argv[1], sys.argv[2]
variant = sys.argv[3] if len(sys.argv) > 3 else "base"
A, D, M = "A" * 32, "D" * 32, "M" * 32
ACCT = "/system/ksdk/.annotations/amzn1.account.TESTE/ksdk_annotation_v1.db"
ANON = "/system/ksdk/.annotations/anonymous/ksdk_annotation_v1.db"
BOOK_A = "/documents/Downloads/Items01/Livro Teste (Autora Fulana)_%s.kfx" % A
BOOK_D = "/documents/Downloads/Items01/Livro Protegido (Beltrano)_%s.kfx" % D
SDR_A = "/documents/Downloads/Items01/Livro Teste (Autora Fulana)_%s.sdr/x.yjr" % A


def lp(eid, off):
    return base64.b64encode(bytes([1]) + eid.to_bytes(4, "little") + off.to_bytes(4, "little")).decode()


def put(path, data):
    p = dev + path
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(data)


book = {"title": "Livro Teste (Autora Fulana)", "authors": ["Autora Fulana"],
        "chunks": [[0, 10, 0, 2, None],
                   [2, 11, 0, 40, "Primeiro par\u00e1grafo \u201ccom\u201d \u2014 nota.17"[:40].ljust(40)],
                   [42, 12, 0, 30, "Segundo cap\u00edtulo come\u00e7a aqui."[:30].ljust(30)],
                   [72, 13, 0, 1, None]],
        "locs": [0, 20, 42, 60], "toc": [["Cap\u00edtulo 1", 11, 0], ["Cap\u00edtulo 2", 12, 0]]}
if variant == "newbook":
    book["title"] = "Livro Teste (Autora Fulana)"
    book["chunks"][2][4] = "Segundo cap\u00edtulo REVISADO aqui"[:30].ljust(30)
put(BOOK_A, json.dumps(book).encode("utf-8"))
put(BOOK_D, b"DRMION" + b"\0" * 50)
put(SDR_A, b"KRDS")

T0 = 1793000000000


def ann(asin, aid, kind, a, b, created, modified, la=None, lb=None, note=None):
    pl = {"book_data": {"asin": asin, "contentType": "PDOC"}, "created_time": created, "last_modified": modified,
          "start_position": {"longPosition": la or "", "shortPosition": a},
          "end_position": {"longPosition": lb or "", "shortPosition": b},
          "json_metadata": json.dumps({"note_text": note}) if note else "{}", "type": kind.upper()}
    return (1 if kind == "highlight" else 3, "%s-PDOC-CR!X-1" % asin, aid, json.dumps(pl), created, modified)


rows = [
    ann(A, "kindle.highlight-2", "highlight", 2, 41, T0, T0, lp(11, 0), lp(11, 39)),
    ann(A, "kindle.highlight-42", "highlight", 42, 50, T0 + 60000, T0 + 60000),
    ann(A, "kindle.note-45", "note", 45, 46, T0 + 120000, T0 + 120000, note="minha \u201cnota\u201d"),
    ann(A, "kindle.highlight-72", "highlight", 72, 72, T0 + 180000, T0 + 180000),
    ann(D, "kindle.highlight-5", "highlight", 5, 9, T0, T0),
    ann(M, "kindle.highlight-7", "highlight", 7, 9, T0, T0),
]
if variant in ("edit", "newbook"):
    rows[1] = ann(A, "kindle.highlight-42", "highlight", 42, 70, T0 + 60000, T0 + 999000)
if variant == "delete":
    rows = rows[1:]
for path, rr in ((ACCT, rows), (ANON, [ann(A, "kindle.highlight-99", "highlight", 2, 5, T0, T0)])):
    p = dev + path
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if os.path.exists(p):
        os.unlink(p)
    con = sqlite3.connect(p)
    con.execute("create table server_view (dataset integer, dataset_id text, annotation_id text, "
                "serialized_payload text, created_time integer, modified_time integer)")
    con.executemany("insert into server_view values (?,?,?,?,?,?)", rr)
    con.commit()
    con.close()

with open(tree_path, "w", encoding="utf-8") as t:
    i = 100
    for root, _dirs, files in os.walk(dev):
        for fn in sorted(files):
            full = os.path.join(root, fn)
            rel = full[len(dev):]
            st = os.stat(full)
            mt = 1790000000 + (5 if variant == "newbook" and rel == BOOK_A else 0)
            t.write("f\t%d\t1\t65537\t%d\t%d\t%s\n" % (i, st.st_size, mt, rel))
            i += 1
