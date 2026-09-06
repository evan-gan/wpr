// the gallery server: serves ui.html, thumbnails, and proxies every action through `wp` itself
import { join, basename, resolve } from "node:path";
import { homedir } from "node:os";

const flags: Record<string, string> = {};
for (let i = 2; i < Bun.argv.length; i++) if (Bun.argv[i].startsWith("--")) flags[Bun.argv[i].slice(2)] = Bun.argv[++i];
const port = Number(flags.port ?? 4747);
const wp = flags.wp ?? "wp";
const root = process.env.WP_ROOT ?? resolve(import.meta.dir, "../..");
const thumbsDir = join(homedir(), "Library/Application Support/wp/thumbs");
const page = Bun.file(join(import.meta.dir, "ui.html"));

const chromeNoise = /CVDisplayLink|allocator multiple|task_policy_set|GL_INVALID_OPERATION/;

async function run(...args: string[]) {
  const p = Bun.spawn([wp, ...args], { env: { ...process.env, WP_ROOT: root }, stdout: "pipe", stderr: "pipe" });
  const [out, errRaw] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
  const code = await p.exited;
  const err = errRaw.split("\n").filter((l) => l && !chromeNoise.test(l)).join("\n");
  return { code, out, err };
}

let knownFiles = new Set<string>();

async function state() {
  const r = await run("state");
  if (r.code !== 0) throw new Error(r.err || r.out);
  const s = JSON.parse(r.out);
  knownFiles = new Set([...s.candidates.map((c: any) => c.path), ...s.displays.map((d: any) => d.wallpaper).filter(Boolean)]);
  return s;
}

Bun.serve({
  port,
  hostname: "127.0.0.1",
  async fetch(req) {
    const url = new URL(req.url);
    try {
      if (url.pathname === "/") return new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } });
      if (url.pathname === "/favicon.ico") return new Response(null, { status: 204 });
      if (url.pathname === "/api/state") return Response.json(await state());
      if (url.pathname.startsWith("/thumbs/")) {
        const f = Bun.file(join(thumbsDir, basename(url.pathname)));
        return (await f.exists()) ? new Response(f, { headers: { "cache-control": "max-age=86400" } }) : new Response("no thumb", { status: 404 });
      }
      if (url.pathname === "/file") {
        const p = url.searchParams.get("path") ?? "";
        if (!knownFiles.has(p)) return new Response("not an indexed file", { status: 403 });
        return new Response(Bun.file(p));
      }
      if (req.method === "POST") {
        const b = await req.json();
        const disp = b.display ? ["--display", String(b.display)] : [];
        let r;
        switch (url.pathname) {
          case "/api/set": r = await run("set", b.path, ...disp); break;
          case "/api/next": r = await run("next", ...disp, ...(b.source ? ["--source", b.source] : [])); break;
          case "/api/gen": r = await run("gen", b.module, ...disp, ...(b.set ? [] : ["--no-set"])); break;
          case "/api/source": r = await run(b.enabled ? "enable" : "disable", b.name); break;
          case "/api/rm": r = await run("rm", b.path); break;
          case "/api/tick": r = await run("tick", ...(b.forceGenerate ? ["--force-generate"] : [])); break;
          default: return new Response("not found", { status: 404 });
        }
        return Response.json({ ok: r.code === 0, out: r.out.trim(), err: r.err.trim() }, { status: r.code === 0 ? 200 : 500 });
      }
      return new Response("not found", { status: 404 });
    } catch (e: any) {
      return Response.json({ ok: false, err: String(e?.message ?? e) }, { status: 500 });
    }
  },
});

console.log(`wp gallery on http://localhost:${port}`);
