# -*- coding: utf-8 -*-
"""Reading and normalizing the karte risk-map sheet (KARTE_SHEET) (rule version norm/v1).

Phase 0 acceptance is "load the existing xlsx -> DB -> the re-exported xlsx matches the input".
Matching cannot be judged by binary comparison (creation time, XML ordering and styles always differ).
What counts as a match is fixed as rules, and the rules themselves are under test.
The full rules are in phase0/NORMALIZATION.md; this is their implementation.
"""
from __future__ import annotations

import hashlib
import json
import re
import unicodedata

import openpyxl

NORM_VERSION = 'norm/v1'
KARTE_SHEET = 'カルテ_リスクマップ'
MASTER_SHEET = 'リスクマップマスタ'
AUTO_SHEETS = ('リスクマップ_AUTO', 'ヒートマップ_AUTO')

# Canonical column names follow the input spec of build_risk_map.py (an existing asset, reused unmodified).
CANONICAL = ['RiskItem', 'Big', 'Mid', 'Frame', 'Summary',
             'ProbBefore', 'ImpactBefore', 'Action', 'ProbAfter', 'ImpactAfter']

# The real template's column names differ from the builder's. Absorb them via aliases.
# Two columns mapping to the same canonical name, unknown columns, or missing required columns are all errors.
ALIASES = {
    'RiskItem': 'RiskItem',
    'Big': 'Big', 'BigCategory': 'Big',
    'Mid': 'Mid', 'MidCategory': 'Mid',
    'Frame': 'Frame', 'SmallFrame': 'Frame',
    'Summary': 'Summary',
    'ProbBefore': 'ProbBefore',
    'ImpactBefore': 'ImpactBefore',
    'Action': 'Action', 'ActionPlan': 'Action',
    'ProbAfter': 'ProbAfter',
    'ImpactAfter': 'ImpactAfter',
}

INT_COLS = ('ProbBefore', 'ImpactBefore', 'ProbAfter', 'ImpactAfter')
TEXT_COLS = ('RiskItem', 'Big', 'Mid', 'Frame', 'Summary', 'Action')
# Business key. Corresponds to (domain, theme, measure, frame, summary) on the DB side.
BUSINESS_KEY = ('RiskItem', 'Big', 'Mid', 'Frame', 'Summary')
FRAMES = ('管理可能性', '精度', 'スピード')

_WS_RUN = re.compile(r'[ \t]+')
_EXCEL_ERRORS = ('#REF!', '#VALUE!', '#DIV/0!', '#NAME?', '#N/A', '#NULL!', '#NUM!')


class KarteError(Exception):
    """The input violates the normalization rules. Always raised; never silently dropped."""


def norm_text(v, where):
    """String normalization. NFC -> unify whitespace -> strip ends -> collapse internal runs of whitespace to one.

    **NFKC is not used.** NFKC folds full-width parentheses 「（）」 and full-width
    alphanumerics to half-width, rewriting the register values themselves (e.g.
    'Sample Dept A（Phase1）' becomes 'Sample Dept A(Phase1)'). The round trip would still
    agree, but a DB value differing from the original is alteration, not normalization,
    so it is rejected. Use NFC, which only folds composed/decomposed variation (dakuten etc.),
    and handle whitespace explicitly below.

    Case is not converted (mis-conversion is costly in a mostly-Japanese register).
    NULL and the empty string are treated alike and return ''.
    """
    if v is None:
        return ''
    if isinstance(v, bool):
        raise KarteError(f'{where}: 真偽値は想定していない')
    if isinstance(v, (int, float)):
        # A text field stored in a numeric cell. Treated as a string even if written as a number.
        v = format_number(v, where)
    if not isinstance(v, str):
        raise KarteError(f'{where}: 想定外の型 {type(v).__name__}')
    if v in _EXCEL_ERRORS:
        raise KarteError(f'{where}: Excel のエラー値 {v}')
    s = unicodedata.normalize('NFC', v)
    s = s.replace(' ', ' ').replace('　', ' ')   # NBSP / full-width space
    s = s.replace('\r\n', '\n').replace('\r', '\n')       # newlines to LF
    s = '\n'.join(_WS_RUN.sub(' ', line).strip() for line in s.split('\n'))
    return s.strip()


def format_number(v, where):
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    if isinstance(v, int):
        return str(v)
    raise KarteError(f'{where}: 非整数 {v!r} を文字列項目に使えない')


def norm_int_1_5(v, where):
    """An integer 1-5. No truncation. Non-integer, out-of-range or empty is an error."""
    if v is None or (isinstance(v, str) and v.strip() == ''):
        raise KarteError(f'{where}: 必須の数値が空')
    if isinstance(v, bool):
        raise KarteError(f'{where}: 真偽値は想定していない')
    if isinstance(v, str):
        s = unicodedata.normalize('NFKC', v).strip()
        if s in _EXCEL_ERRORS:
            raise KarteError(f'{where}: Excel のエラー値 {s}')
        try:
            v = float(s)
        except ValueError:
            raise KarteError(f'{where}: 数値として読めない {v!r}')
    if isinstance(v, float):
        if not v.is_integer():
            raise KarteError(f'{where}: 非整数 {v!r}（切り捨てない）')
        v = int(v)
    if not isinstance(v, int):
        raise KarteError(f'{where}: 想定外の型 {type(v).__name__}')
    if not 1 <= v <= 5:
        raise KarteError(f'{where}: 1〜5 の範囲外 {v}')
    return v


def resolve_headers(raw_headers):
    """Map the header row to canonical names. Unknown, missing, colliding or duplicate columns are all errors."""
    mapping = {}          # column index -> canonical name
    seen = {}             # canonical name -> original column name
    # The rule is "ignore only fully empty trailing columns". Skipping empty headers regardless
    # of position would silently drop a whole column when one in the middle has an empty header.
    last_named = -1
    for idx, h in enumerate(raw_headers):
        if h is not None and str(h).strip() != '':
            last_named = idx
    for idx, h in enumerate(raw_headers):
        if h is None or str(h).strip() == '':
            if idx < last_named:
                raise KarteError(f'{idx + 1} 列目のヘッダが空（末尾以外の空ヘッダは許さない）')
            continue      # ignore only trailing empty columns
        name = unicodedata.normalize('NFKC', str(h)).strip()
        if name not in ALIASES:
            raise KarteError(f'未知の列: {name!r}')
        canon = ALIASES[name]
        if canon in seen:
            raise KarteError(f'列の衝突: {seen[canon]!r} と {name!r} が同じ {canon!r} に写る')
        seen[canon] = name
        mapping[idx] = canon
    missing = [c for c in CANONICAL if c not in seen]
    if missing:
        raise KarteError('必須の列が無い: ' + ', '.join(missing))
    return mapping


def read_karte(path):
    """Return the karte risk-map sheet (KARTE_SHEET) as a list of normalized rows."""
    wb = openpyxl.load_workbook(path, data_only=True)
    if KARTE_SHEET not in wb.sheetnames:
        raise KarteError(f'シートが無い: {KARTE_SHEET}')
    ws = wb[KARTE_SHEET]

    rows_iter = ws.iter_rows(values_only=True)
    try:
        header = next(rows_iter)
    except StopIteration:
        raise KarteError('カルテシートが空')
    mapping = resolve_headers(header)

    # Formula cells are rejected. data_only=True only reads the cached value and
    # cannot detect a stale cache (= silently passes old values).
    formula_wb = openpyxl.load_workbook(path, data_only=False)
    fws = formula_wb[KARTE_SHEET]
    for row in fws.iter_rows():
        for cell in row:
            if isinstance(cell.value, str) and cell.value.startswith('='):
                raise KarteError(f'{cell.coordinate}: 数式セルは扱わない')

    out = []
    for rno, raw in enumerate(rows_iter, start=2):
        if raw is None or all(c is None or str(c).strip() == '' for c in raw):
            continue      # rows with every column empty are not counted as rows
        rec = {}
        for idx, canon in mapping.items():
            v = raw[idx] if idx < len(raw) else None
            where = f'行{rno} {canon}'
            rec[canon] = norm_int_1_5(v, where) if canon in INT_COLS else norm_text(v, where)
        for k in BUSINESS_KEY:
            if rec[k] == '':
                raise KarteError(f'行{rno}: 業務キー {k} が空')
        if rec['Frame'] not in FRAMES:
            raise KarteError(f'行{rno}: Frame は {"/".join(FRAMES)} のいずれか（{rec["Frame"]!r}）')
        out.append(rec)
    if not out:
        raise KarteError('カルテシートにデータ行が無い')

    keys = [tuple(r[k] for k in BUSINESS_KEY) for r in out]
    dup = {k for k in keys if keys.count(k) > 1}
    if dup:
        raise KarteError(f'業務キーの重複が {len(dup)} 件（台帳として誤り）')
    return out


def sort_key(rec):
    """Sort by code point to avoid locale differences."""
    return tuple(rec[k] for k in BUSINESS_KEY)


def serialize(rows):
    """Serialize normalized data. JSON Lines, fixed key order, non-ASCII kept as-is."""
    lines = []
    for rec in sorted(rows, key=sort_key):
        ordered = {k: rec[k] for k in CANONICAL}
        lines.append(json.dumps(ordered, ensure_ascii=False, sort_keys=True,
                                separators=(',', ':')))
    return '\n'.join(lines) + '\n'


def digest(rows):
    """SHA-256 (lowercase hex) of the serialized UTF-8 bytes."""
    return hashlib.sha256(serialize(rows).encode('utf-8')).hexdigest()


def compare(left_rows, right_rows):
    """Return the list of differences. An empty list means "0 differences"."""
    li = {sort_key(r): r for r in left_rows}
    ri = {sort_key(r): r for r in right_rows}
    diffs = []
    for k in sorted(set(li) - set(ri)):
        diffs.append(('入力にのみ存在', k, None, None))
    for k in sorted(set(ri) - set(li)):
        diffs.append(('出力にのみ存在', k, None, None))
    for k in sorted(set(li) & set(ri)):
        for col in CANONICAL:
            if li[k][col] != ri[k][col]:
                diffs.append((f'{col} が不一致', k, li[k][col], ri[k][col]))
    return diffs
