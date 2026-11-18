import asyncio, pathlib
import os
# The built site; SITE points the check at another build or an HTTP URL.
SITE = os.environ.get('SITE') or (pathlib.Path(__file__).resolve().parent.parent / 'dist' / 'index.html').as_uri()
OUT = pathlib.Path(__file__).resolve().parent / 'out'
OUT.mkdir(exist_ok=True)
from playwright.async_api import async_playwright
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(); errs=[]
        pg = await b.new_page(viewport={'width':390,'height':844}); pg.on('pageerror', lambda e: errs.append(str(e)))
        await pg.goto(SITE + '#beam'); await pg.wait_for_timeout(300)
        lab = pg.locator('#view .lab').first
        await lab.locator('.tourbar .tbn').first.click(); await pg.wait_for_timeout(200)
        await pg.evaluate("document.querySelector('.appbar').style.position='static'")
        await lab.scroll_into_view_if_needed()
        await pg.screenshot(path=str(OUT / 'mob.png'), clip={'x':0,'y':0,'width':390,'height':844})
        await lab.screenshot(path=str(OUT / 'mob_lab.png'))
        print(errs); await b.close()
asyncio.run(main())
