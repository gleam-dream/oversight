import asyncio, pathlib
import os
# SITE points the check at another build, for example the Lustre site's dist/index.html.
SITE = os.environ.get('SITE') or (pathlib.Path(__file__).resolve().parent.parent / 'site' / 'index.html').as_uri()
OUT = pathlib.Path(__file__).resolve().parent / 'out'
OUT.mkdir(exist_ok=True)
from playwright.async_api import async_playwright
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(); errs = []
        ctx = await b.new_context(viewport={'width': 1366, 'height': 768}, reduced_motion='reduce')
        pg = await ctx.new_page(); pg.on('pageerror', lambda e: errs.append(str(e)))
        for r, i in [('otp', 1), ('foundations', 0)]:
            await pg.goto(SITE + '#' + r); await pg.wait_for_timeout(400)
            lab = pg.locator('#view .lab').nth(i)
            n0 = await lab.locator('[data-live] svg').count()
            await lab.locator('.tblink').click(); await pg.wait_for_timeout(100)
            adv = lab.locator('text=Advance 1 second')
            for _ in range(3): await adv.click(); await pg.wait_for_timeout(80)
            circles = await lab.locator('[data-live] circle').count()
            print(r, 'svg drawn:', n0, '| tokens after 3 s:', circles, '| play buttons:', await lab.locator('.tbi').count())
        print('errs', errs); await b.close()
asyncio.run(main())
