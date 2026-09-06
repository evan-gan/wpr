// dev helper: screenshot a URL with the installed Chrome. bun hosts/web/shot.ts <url> <out.png> [w] [h]
import puppeteer from "puppeteer-core";

const [url, out, w = "1600", h = "1200"] = Bun.argv.slice(2);
if (!url || !out) {
  console.error("usage: bun hosts/web/shot.ts <url> <out.png> [width] [height]");
  process.exit(2);
}
const browser = await puppeteer.launch({
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
  defaultViewport: { width: Number(w), height: Number(h), deviceScaleFactor: 1 },
});
try {
  const page = await browser.newPage();
  page.on("console", (m) => console.error(`[page] ${m.text()}`));
  page.on("pageerror", (e) => console.error(`[page error] ${e.message}`));
  await page.goto(url, { waitUntil: "networkidle0", timeout: 60000 });
  await new Promise((r) => setTimeout(r, 800));
  await page.screenshot({ path: out, type: "png" });
  console.log("wrote", out);
} finally {
  await browser.close();
}
