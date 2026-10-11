const PREFIX = "videos/";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!["GET", "HEAD"].includes(request.method)) {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    if (url.pathname === "/videos.json") {
      const cursor = url.searchParams.get("cursor") || undefined;
      const page = await env.VIDEOS.list({ prefix: PREFIX, limit: 100, cursor, include: ["customMetadata"] });
      const videos = page.objects.filter(object => object.key.toLowerCase().endsWith(".32vid")).map(object => ({
        title: object.customMetadata?.title || object.key.slice(PREFIX.length, -6).replace(/[-_]/g, " ").replace(/\b[a-z]/g, c => c.toUpperCase()),
        url: new URL("/" + object.key.split("/").map(encodeURIComponent).join("/"), url.origin).href,
        size: object.size,
        release: "R2",
      }));
      const headers = new Headers({ "Content-Type": "application/json", "Cache-Control": "no-store" });
      if (page.truncated) {
        const next = new URL("/videos.json", url.origin);
        next.searchParams.set("cursor", page.cursor);
        headers.set("Link", `<${next.href}>; rel="next"`);
      }
      return new Response(request.method === "HEAD" ? null : JSON.stringify(videos), { headers });
    }
    let key;
    try { key = decodeURIComponent(url.pathname.slice(1)); }
    catch { return new Response("Invalid path", { status: 400 }); }
    if (!key.startsWith(PREFIX) || !key.toLowerCase().endsWith(".32vid")
        || key.split("/").some(part => part === "." || part === "..") || /[\x00-\x1f\x7f]/.test(key)) {
      return new Response("Not found", { status: 404 });
    }
    const object = request.method === "HEAD" ? await env.VIDEOS.head(key) : await env.VIDEOS.get(key);
    if (!object) return new Response("Not found", { status: 404 });
    return new Response(request.method === "HEAD" ? null : object.body, {
      headers: { "Content-Type": "application/octet-stream", "Content-Length": String(object.size),
        "ETag": object.httpEtag, "Cache-Control": "no-store" },
    });
  },
};
