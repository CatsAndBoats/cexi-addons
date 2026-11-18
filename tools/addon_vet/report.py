"""Puts a vet's pieces together: the scan, ClamAV's result and the AI's verdict, into one verdict.json and a
Markdown report (the workflow's job summary).

    python tools/addon_vet/report.py --dir _vet --source owner/repo@sha:path [--summary $GITHUB_STEP_SUMMARY]

Reads from --dir: scan.json, scan.md, clamav.txt + clamav.rc (optional), claude.json (optional, `claude -p
--output-format json`). Writes verdict.json and report.md there.
"""
import argparse
import json
import os
import re

OUTCOMES = {'allow', 'whitelist', 'prohibit', 'needs_staff'}


def read(path, default=None):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            return f.read()
    except OSError:
        return default


def ai_verdict(raw):
    """The JSON object in Claude's answer, checked; or (None, why not)."""
    if not raw:
        return None, 'not run'
    try:
        result = json.loads(raw).get('result') or ''
    except ValueError:
        return None, 'claude.json unreadable'
    m = re.search(r'\{.*\}', result, re.S)
    if not m:
        return None, 'no JSON in the answer'
    try:
        v = json.loads(m.group(0))
    except ValueError as e:
        return None, f'answer is not valid JSON ({e})'
    if v.get('tier') not in ('T0', 'T1', 'T2', 'T3', 'T4') or v.get('outcome') not in OUTCOMES:
        return None, 'answer has no valid tier or outcome'
    try:
        v['confidence'] = float(v.get('confidence', 0))
    except (TypeError, ValueError):
        v['confidence'] = 0.0
    return v, None


def final_outcome(v, clam_rc, scan):
    """The AI proposes; these rules can only make it more careful."""
    if clam_rc == 1:
        return 'prohibit', 'ClamAV found malware'
    if v is None:
        return 'needs_staff', 'no AI verdict'
    reasons = []
    if clam_rc not in (0, None):
        reasons.append('ClamAV did not finish')
    if v['confidence'] < 0.98:
        reasons.append(f"confidence {v['confidence']:.2f} is below 0.98")
    if v.get('red_flags'):
        reasons.append('red flags')
    if scan.get('counts', {}).get('addresses_reviewer'):
        reasons.append('text aimed at an AI reviewer')
    if scan.get('binaries'):
        reasons.append('binaries the scan cannot read')
    if reasons and v['outcome'] != 'needs_staff':
        return 'needs_staff', '; '.join(reasons)
    return v['outcome'], 'as the AI proposed'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', default='_vet')
    ap.add_argument('--source', default='')
    ap.add_argument('--summary')
    a = ap.parse_args()
    d = a.dir
    scan = json.loads(read(os.path.join(d, 'scan.json'), '{}'))
    rc_text = (read(os.path.join(d, 'clamav.rc')) or '').strip()
    clam_rc = int(rc_text) if rc_text.lstrip('-').isdigit() else None
    clam_out = (read(os.path.join(d, 'clamav.txt')) or '').strip()
    v, why_not = ai_verdict(read(os.path.join(d, 'claude.json')))
    outcome, outcome_why = final_outcome(v, clam_rc, scan)

    known = scan.get('known_match') or []
    doc = {
        'source': a.source,
        'addon': scan.get('name'),
        'known_listing': [f"{k['tier']} {k['status']} ({k['name']})" for k in known] or None,
        'clamav': {0: 'clean', 1: 'infected', None: 'not run'}.get(clam_rc, 'error'),
        'scan_leaning': scan.get('leaning'),
        'ai': v,
        'ai_missing': why_not,
        'outcome': outcome,
        'outcome_why': outcome_why,
    }
    with open(os.path.join(d, 'verdict.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)

    md = [f"# Addon vet: {scan.get('name', '?')}", '', f"`{a.source}`", '']
    md.append('| | |')
    md.append('|---|---|')
    md.append(f"| **Outcome** | **{outcome}** ({outcome_why}) |")
    if v:
        kind = f" ({v['t4_kind']})" if v.get('t4_kind') else ''
        md.append(f"| AI tier | {v['tier']}{kind}, confidence {v['confidence']:.2f} |")
    else:
        md.append(f"| AI tier | none: {why_not} |")
    md.append(f"| On the policy page | {', '.join(doc['known_listing']) if known else 'not listed'} |")
    md.append(f"| Scan leaning | {scan.get('leaning')} |")
    md.append(f"| ClamAV | {doc['clamav']} |")
    md.append('')
    if v:
        md += ['## What it does', '', v.get('summary', ''), '', '## Decision tree', '']
        for step in v.get('decision_tree', []):
            ev = ', '.join(f"`{e}`" for e in step.get('evidence', []))
            md.append(f"{step.get('q')}. **{step.get('answer')}**: {step.get('why', '')} {ev}".rstrip())
        md.append('')
        for title, key in (('Conditions', 'conditions'), ('Red flags', 'red_flags')):
            if v.get(key):
                md += [f'## {title}', ''] + [f'- {x}' for x in v[key]] + ['']
        if v.get('listing_text'):
            md += ['## Suggested listing', '', f"> {v['listing_text']}", '']
    if clam_rc == 1 and clam_out:
        md += ['## ClamAV', '', '```', clam_out[:4000], '```', '']
    scan_md = read(os.path.join(d, 'scan.md'), '')
    if scan_md:
        md += ['<details><summary>Static scan</summary>', '', scan_md, '', '</details>', '']
    text = '\n'.join(md)
    with open(os.path.join(d, 'report.md'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    if a.summary:
        with open(a.summary, 'a', encoding='utf-8') as f:
            f.write(text + '\n')
    print(f"{scan.get('name')}: {outcome} ({outcome_why})")


if __name__ == '__main__':
    main()
