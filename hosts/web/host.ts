// renders a web module to a PNG: serves the repo root over http, loads the module page in
// headless Chrome with window.WP = { width, height, seed, params }, waits for window.WP_DONE, screenshots.
import puppeteer from "puppeteer-core";
import { resolve, join, normalize } from "node:path";

function parse(argv: string[]) {
  const flags: Record<string, string> = {};
  const params: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--param") {
      const [k, ...v] = argv[++i].split("=");
      params[k] = v.join("=");
    } else if (a.startsWith("--")) {
      flags[a.slice(2)] = argv[++i];
    }
  }
  return { flags, params };
}

const { flags, params } = parse(Bun.argv.slice(2));
const root = resolve(flags.root ?? ".");
const width = Number(flags.width), height = Number(flags.height), seed = Number(flags.seed ?? 0);
const timeout = Number(flags.timeout ?? 20000);
const chrome = flags.chrome ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

if (!flags.page || !flags.out || !width || !height) {
  console.error("usage: bun host.ts --root R --page modules/x/index.html --width W --height H --seed S --out out.png [--param k=v] [--timeout ms]");
  process.exit(2);
}

const server = Bun.serve({
  port: 0,
  async fetch(req) {
    const rel = normalize(decodeURIComponent(new URL(req.url).pathname));
    if (rel === "/favicon.ico") return new Response(null, { status: 204 });
    const path = join(root, rel);
    if (!path.startsWith(root)) return new Response("forbidden", { status: 403 });
    const file = Bun.file(path);
    if (!(await file.exists())) return new Response(`not found: ${rel}`, { status: 404 });
    return new Response(file);
  },
});

const browser = await puppeteer.launch({
  executablePath: chrome,
  headless: true,
  args: [`--window-size=${width},${height}`, "--hide-scrollbars", "--ignore-gpu-blocklist", "--no-first-run"],
  defaultViewport: { width, height, deviceScaleFactor: 1 },
});

try {
  const page = await browser.newPage();
  page.on("console", (m) => console.error(`[page] ${m.text()}`));
  page.on("pageerror", (e) => console.error(`[page error] ${e.message}`));
  await page.evaluateOnNewDocument((wp) => { (window as any).WP = wp; }, { width, height, seed, params });

  const t0 = Date.now();
  await page.goto(`http://localhost:${server.port}/${flags.page}`, { waitUntil: "load" });
  await page
    .waitForFunction(() => (window as any).WP_DONE === true, { timeout })
    .catch(() => console.error(`[host] no WP_DONE after ${timeout}ms, screenshotting anyway`));
  console.error(`[host] page ready in ${Date.now() - t0}ms`);
  await page.screenshot({ path: flags.out, type: "png" });
} finally {
  await browser.close();
  server.stop(true);
}
