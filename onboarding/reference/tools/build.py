#!/usr/bin/env python3
"""Wrap a module fragment (src/<name>.html + src/<name>.js + src/<name>.json meta) into project/<name>.dc.html."""
import json, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONTS = "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&amp;family=JetBrains+Mono:wght@400;600&amp;family=Space+Grotesk:wght@500;600;700&amp;display=swap"

CSS = r"""
body{margin:0;background:#FAF8F4}
a{color:#B0186E}a:hover{color:#7E0F4E}
.pg{font-family:Inter,system-ui,sans-serif;color:#17162B;background:#FAF8F4;line-height:1.55;font-size:17px}
.wrap{max-width:1120px;margin:0 auto;padding:0 24px}
h1,h2,h3,h4{font-family:'Space Grotesk',Inter,sans-serif;margin:0;line-height:1.15;letter-spacing:-0.01em}
p{margin:0}
.top{border-bottom:1px solid #E4E0D8;background:#FAF8F4}
.topin{display:flex;flex-wrap:wrap;gap:12px 24px;align-items:center;justify-content:space-between;padding:16px 0}
.brand{font:600 15px 'JetBrains Mono',monospace;color:#17162B;text-decoration:none}
.meta{font:500 13px 'JetBrains Mono',monospace;color:#5B5970}
.k{font:600 12px 'JetBrains Mono',monospace;letter-spacing:.08em;text-transform:uppercase;color:#B0186E}
.mono{font-family:'JetBrains Mono',monospace}
.muted{color:#5B5970}
.sec{padding-bottom:72px}
.h2{font-size:34px;margin:10px 0 12px}
.lead{font-size:18px;color:#5B5970;max-width:760px}
.card{background:#fff;border:1px solid #E4E0D8;border-radius:16px;padding:24px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px;margin-top:28px}
.cards h3{font-size:20px;margin:12px 0 6px}
.cards p{font-size:15px;color:#5B5970}
.ico{width:40px;height:40px;border-radius:12px;display:flex;align-items:center;justify-content:center}
.lab{background:#fff;border:1px solid #E4E0D8;border-radius:24px;padding:32px;margin-top:28px;box-shadow:0 1px 0 #E4E0D8}
.labh{display:flex;flex-wrap:wrap;justify-content:space-between;gap:12px;align-items:flex-start;margin-bottom:20px}
.tag{display:inline-block;font:600 11px 'JetBrains Mono',monospace;letter-spacing:.08em;text-transform:uppercase;padding:5px 10px;border-radius:999px;background:#FCE7F3;color:#8A1056}
.chip{display:inline-block;font:600 12px 'JetBrains Mono',monospace;padding:4px 10px;border-radius:999px}
.btn{font:600 14px Inter,sans-serif;min-height:44px;padding:0 18px;border-radius:999px;border:1px solid #17162B;background:#fff;color:#17162B;cursor:pointer;display:inline-flex;align-items:center;gap:8px}
.btn:hover{background:#F1EEE8}
.btn.pri{background:#17162B;color:#fff}.btn.pri:hover{background:#2E2C4F}
.btn.on{background:#17162B;color:#fff}
.btn.sm{min-height:36px;padding:0 12px;font-size:13px}
.btn.warn{border-color:#B42318;color:#B42318}.btn.warn:hover{background:#FDECEA}
.btn:disabled{opacity:.4;cursor:not-allowed}
.row{display:flex;flex-wrap:wrap;gap:10px;align-items:center}
.seg{display:inline-flex;flex-wrap:wrap;gap:6px;padding:4px;border-radius:999px;background:#F1EEE8}
.seg button{font:600 13px Inter,sans-serif;min-height:40px;padding:0 14px;border-radius:999px;border:0;background:transparent;color:#17162B;cursor:pointer}
.seg button.on{background:#17162B;color:#fff}
.log{background:#17162B;color:#E8E6F5;border-radius:14px;padding:16px 18px;font:13px/1.6 'JetBrains Mono',monospace;min-height:120px}
.log .l{padding:2px 0;border-bottom:1px solid #2E2C4F}
.key{background:#17162B;color:#fff;border-radius:20px;padding:32px 36px;margin-top:28px}
.key .k{color:#F9A8D4}
.key p{font:600 22px/1.4 'Space Grotesk',sans-serif;margin-top:10px;max-width:880px}
.note{background:#F1EEE8;border-radius:14px;padding:16px 20px;font-size:15px}
.split{display:flex;flex-wrap:wrap;gap:24px}
.split>*{flex:1 1 360px;min-width:0}
.pill{display:inline-flex;align-items:center;gap:6px;font:600 12px 'JetBrains Mono',monospace;padding:6px 10px;border-radius:8px;background:#F1EEE8}
.q{background:#fff;border:1px solid #E4E0D8;border-radius:16px;padding:24px;margin-top:16px}
.q h4{font-size:19px;margin-bottom:14px}
.opts{display:flex;flex-direction:column;gap:8px}
.opt{text-align:left;font:500 15px Inter,sans-serif;min-height:48px;padding:10px 16px;border-radius:12px;border:1px solid #E4E0D8;background:#FAF8F4;color:#17162B;cursor:pointer}
.opt:hover{border-color:#17162B}
.opt.right{background:#E2F4E7;border-color:#15803D;color:#0E4D25;font-weight:600}
.opt.wrong{background:#FDECEA;border-color:#B42318;color:#7A1A12}
.opt.dim{opacity:.55}
.fb{margin-top:14px;font-size:15px;padding:12px 16px;border-radius:12px;background:#F1EEE8}
.foot{border-top:1px solid #E4E0D8;padding:40px 0 64px}
.navc{display:flex;flex-direction:column;gap:4px;text-decoration:none;color:#17162B;background:#fff;border:1px solid #E4E0D8;border-radius:16px;padding:20px 24px;flex:1 1 300px}
.navc:hover{border-color:#17162B;color:#17162B}
.box{border-radius:14px;padding:14px 16px;border:1px solid #E4E0D8;background:#fff}
.arrow{font:600 18px 'JetBrains Mono',monospace;color:#8A8698;display:flex;align-items:center;justify-content:center}
"""

QUIZ = """
<section class="wrap sec" aria-labelledby="check">
<div class="k">Check · about 3 minutes</div>
<h2 class="h2" id="check">Did it land?</h2>
<p class="lead">Pick an answer to see why it's right or wrong. Take a guess, then read the explanation.</p>
<sc-for list="{{quiz}}" as="q" hint-placeholder-count="3">
<div class="q">
<h4>{{q.n}}. {{q.q}}</h4>
<div class="opts">
<sc-for list="{{q.opts}}" as="o" hint-placeholder-count="3">
<button type="button" class="{{o.cls}}" onClick="{{o.pick}}">{{o.label}}</button>
</sc-for>
</div>
<sc-if value="{{q.answered}}" hint-placeholder-val="{{false}}"><div class="fb">{{q.feedback}}</div></sc-if>
</div>
</sc-for>
<div class="row" style="margin-top:16px"><span class="meta">{{quizScore}}</span></div>
</section>
"""

HELPERS = """
  quizVals(qs) {
    const a = this.state.answers || {};
    let right = 0, done = 0;
    const quiz = qs.map((q, qi) => {
      const got = a[qi];
      if (got !== undefined) { done++; if (got === q.c) right++; }
      return { n: qi + 1, q: q.q, answered: got !== undefined,
        feedback: got === undefined ? '' : (got === q.c ? 'Right. ' : 'Not quite. ') + q.e,
        opts: q.o.map((o, oi) => ({ label: o,
          cls: 'opt' + (got === undefined ? '' : (oi === q.c ? ' right' : (got === oi ? ' wrong' : ' dim'))),
          pick: () => this.setState({ answers: Object.assign({}, this.state.answers || {}, { [qi]: oi }) }) })) };
    });
    const quizScore = done === 0 ? qs.length + ' questions' : right + ' of ' + qs.length + ' right' + (done < qs.length ? ' so far' : (right === qs.length ? ', nicely done' : ', reread the hints above and try the next module'));
    return { quiz, quizScore };
  }
"""

def build(name):
    meta = json.loads((ROOT / 'src' / f'{name}.json').read_text())
    body = (ROOT / 'src' / f'{name}.html').read_text()
    js = (ROOT / 'src' / f'{name}.js').read_text()
    body = body.replace('<!--QUIZ-->', QUIZ)
    js = js.replace('/*HELPERS*/', HELPERS)
    prev = f'<a class="navc" href="{meta["prev"]}"><span class="meta">← Previous</span><span style="font:600 19px \'Space Grotesk\',sans-serif">{meta["prevTitle"]}</span></a>' if meta.get('prev') else ''
    nxt = f'<a class="navc" href="{meta["next"]}" style="text-align:right"><span class="meta">Next →</span><span style="font:600 19px \'Space Grotesk\',sans-serif">{meta["nextTitle"]}</span></a>' if meta.get('next') else ''
    nextTop = f'<a href="{meta["next"]}" style="font-weight:600">Next: {meta["nextTitle"]} →</a>' if meta.get('next') else '<a href="Main.dc.html" style="font-weight:600">Back to the map</a>'
    props = json.dumps({"$preview": {"width": 1440, "height": meta['h']}})
    html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{meta["title"]}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="stylesheet" href="{FONTS}">
<style>{CSS}</style>
</helmet>
<div class="pg">
<nav class="top" aria-label="Course">
<div class="wrap topin">
<a class="brand" href="Main.dc.html">gleam-dream / onboarding</a>
<span class="meta">Module {meta["n"]} of 11 · about {meta["min"]} min</span>
{nextTop}
</div>
</nav>
{body}
<footer class="wrap foot">
<div class="row" style="gap:16px;align-items:stretch">{prev}{nxt}</div>
<p class="meta" style="margin-top:24px"><a href="Main.dc.html">Course map</a> · Sources: the gleam-dream repositories on GitHub</p>
</footer>
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{props}'>
{js}
</script>
</body>
</html>
'''
    out = ROOT / 'project' / f'{name}.dc.html'
    out.write_text(html)
    print('wrote', out, len(html))

if __name__ == '__main__':
    for n in sys.argv[1:]:
        build(n)
