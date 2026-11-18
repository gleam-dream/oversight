import asyncio, pathlib
import os
# SITE points the check at another build, for example the Lustre site's dist/index.html.
SITE = os.environ.get('SITE') or (pathlib.Path(__file__).resolve().parent.parent / 'site' / 'index.html').as_uri()
OUT = pathlib.Path(__file__).resolve().parent / 'out'
OUT.mkdir(exist_ok=True)
import sys
from playwright.async_api import async_playwright
R=['start','beam','otp','gleam','principles','atlas','foundations','outside-world','durable-work','agents','compose','field-guide']
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        for (w,h) in [(1366,768),(1440,900)]:
            pg = await b.new_page(viewport={'width':w,'height':h})
            await pg.goto(SITE); await pg.wait_for_timeout(300)
            out=[]
            for r in R:
                await pg.evaluate(f"location.hash='{r}'"); await pg.wait_for_timeout(350)
                zs = await pg.evaluate("Array.from(document.querySelectorAll('#view .lab.touring')).map(l=>{const t=l.querySelector('h2');return (t?t.textContent.slice(0,16):'?')+'='+(l.getAttribute('data-rt-z')||'100')+'|'+Math.round(l.getBoundingClientRect().height)})")
                out.append(r+': '+', '.join(zs))
            print(w,h); print('\n'.join(out)); await pg.close()
        await b.close()
asyncio.run(main())
