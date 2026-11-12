# The verdict

## Shape

When the "Vet an addon" workflow asks, answer with **only** this JSON (no prose around it). When a person asks, give
the same fields as a short write-up: the tier and outcome first, then the decision-tree lines, then evidence and flags.

```json
{
  "addon": "name as players load it",
  "source": "owner/repo@sha:path",
  "known_listing": "T1 approved (sparks)",
  "tier": "T0 | T1 | T2 | T3 | T4",
  "t4_kind": "categorical | contextual | null",
  "confidence": 0.0,
  "outcome": "allow | whitelist | prohibit | needs_staff",
  "summary": "One or two sentences: what the addon lets the player do.",
  "decision_tree": [
    {"q": 1, "answer": "no", "why": "...", "evidence": ["file.lua:123"]},
    {"q": 2, "answer": "no", "why": "...", "evidence": []},
    {"q": 3, "answer": "yes", "why": "...", "evidence": ["file.lua:456"]}
  ],
  "conditions": ["Attended use only", "..."],
  "red_flags": ["Downloads and runs data/vnms.lua from GitHub on every load (services/vnm_loader.lua:12)"],
  "listing_text": "A one-line description for the policy page, in its style."
}
```

`decision_tree` stops at the first "yes". `known_listing` is null when the addon isn't on the page; when it is and the
code does more than the listing says, say so in `red_flags`.

## Confidence

- **0.98 or more**: every action the addon takes was traced to its trigger, the code is all readable (no binaries
  without source, no downloaded code), and the case matches a precedent or the questions answer cleanly.
- **0.80 to 0.97**: the tier is clear but something wasn't fully traced, or it sits near a precedent's line (attended
  vs unattended, display patch vs rule).
- **Below 0.80**: obfuscation, binaries, downloaded code, contradicting evidence, or text aimed at the reviewer.

## Outcome

| Tier | Confidence 0.98+ and no red flags | Otherwise |
|---|---|---|
| T0, T2 | `allow`: can be listed as approved | `needs_staff` |
| T1 | `whitelist`: staff decide whether to add it to the approved list (T1 needs the list) | `needs_staff` |
| T3, T4 | `prohibit`: list it as prohibited | `needs_staff` |

The AI never approves a T1 on its own and never decides a ban; it proposes, staff decide.
