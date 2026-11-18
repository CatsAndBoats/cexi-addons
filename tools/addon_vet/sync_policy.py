"""Reads CatsEyeXI's addon policy page and writes its Known Addons table as JSON.

    python tools/addon_vet/sync_policy.py [--url URL] [--out tools/addon_vet/known_addons.json]

The page is the source of truth; known_addons.json is a copy kept in the repository so the scanner and the
addon-policy skill work offline. Run this after the page changes (the vetting workflow runs it on every vet).
"""
import argparse
import datetime
import html
import json
import re
import sys
import urllib.request

URL = 'https://catseyexi.com/addon-policy'
LABELS = {'T0': 'Cosmetic', 'T1': 'Sanctioned', 'T2': 'Information', 'T3': 'Botting', 'T4': 'Cheating'}


def page_text(raw):
    t = re.sub(r'(?s)<(script|style)[^>]*>.*?</\1>', '', raw)
    t = re.sub(r'<br\s*/?>|</(p|div|li|h[1-6]|tr|td|th|span)>', '\n', t)
    t = html.unescape(re.sub(r'<[^>]+>', '', t))
    return [ln.strip() for ln in t.splitlines() if ln.strip()]


def parse(lines):
    try:
        start = lines.index('AddonTierDescription') + 1
    except ValueError:
        start = 0
    out = []
    i = start
    while i < len(lines) - 2:
        name, status, third = lines[i], lines[i + 1], lines[i + 2]
        m = re.match(r'^(T[0-4]) (Cosmetic|Sanctioned|Information|Botting|Cheating)(.*)$', third)
        if status in ('Approved', 'Prohibited') and m:
            tier, desc, kind, step = m.group(1), m.group(3).strip(), None, 3
            if not desc and i + 3 < len(lines) and lines[i + 3] in ('Contextual', 'Categorical'):
                kind, desc, step = lines[i + 3], lines[i + 4] if i + 4 < len(lines) else '', 5
            entry = {'name': name, 'status': status.lower(), 'tier': tier, 'label': LABELS[tier], 'desc': desc}
            if kind:
                entry['t4_kind'] = kind.lower()
            out.append(entry)
            i += step
            continue
        if name.startswith('Adding a new addon'):
            break
        i += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--url', default=URL)
    ap.add_argument('--out', default='tools/addon_vet/known_addons.json')
    a = ap.parse_args()
    req = urllib.request.Request(a.url, headers={'User-Agent': 'cexi-addon-vet'})
    raw = urllib.request.urlopen(req, timeout=30).read().decode('utf-8', 'replace')
    addons = parse(page_text(raw))
    if len(addons) < 50:
        sys.exit(f'only {len(addons)} addons read from {a.url}: the page layout changed? {a.out} left as it was')
    doc = {
        'source': a.url,
        'fetched': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'count': len(addons),
        'addons': sorted(addons, key=lambda e: (e['tier'], e['name'].lower())),
    }
    with open(a.out, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write('\n')
    print(f'{len(addons)} addons -> {a.out}')


if __name__ == '__main__':
    main()
