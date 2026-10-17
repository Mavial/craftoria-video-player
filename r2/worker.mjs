const PREFIX = "videos/";
const THUMBNAIL_BYTES = 256 * 1024;

function thumbnailURL(object, origin) {
  const url = new URL("/" + object.key.split("/").map(encodeURIComponent).join("/"), origin);
  url.searchParams.set("thumbnail", "1");
  url.searchParams.set("v", object.etag || object.httpEtag);
  return url.href;
}

function displayTitle(object) {
  if (typeof object.customMetadata?.title === "string" && object.customMetadata.title.trim()) {
    return object.customMetadata.title.trim();
  }
  const disposition = object.httpMetadata?.contentDisposition;
  if (typeof disposition === "string") {
    const encoded = disposition.match(/filename\*=UTF-8''([^;]+)/i);
    const quoted = disposition.match(/filename="((?:[^"\\]|\\.)*)"/i);
    try {
      const filename = encoded ? decodeURIComponent(encoded[1].trim()) : quoted?.[1].replace(/\\(.)/g, "$1");
      if (filename?.toLowerCase().endsWith(".32vid")) {
        const title = filename.slice(0, -6).trim();
        if (title && !/[\x00-\x1f\x7f]/.test(title)) return title;
      }
    } catch { /* Invalid metadata falls back to the legacy filename title. */ }
  }
  return object.key.slice(PREFIX.length, -6).replace(/[-_]/g, " ").replace(/\b[a-z]/g, c => c.toUpperCase());
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!["GET", "HEAD"].includes(request.method)) {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    if (url.pathname === "/videos.json") {
      const cursor = url.searchParams.get("cursor") || undefined;
      const page = await env.VIDEOS.list({ prefix: PREFIX, limit: 100, cursor, include: ["customMetadata", "httpMetadata"] });
      const videos = page.objects.filter(object => object.key.toLowerCase().endsWith(".32vid")).map(object => ({
        title: displayTitle(object),
        url: new URL("/" + object.key.split("/").map(encodeURIComponent).join("/"), url.origin).href,
        size: object.size,
        release: "R2",
        thumbnail: thumbnailURL(object, url.origin),
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
    // A distinct URL keeps background thumbnail events separate from playback.
    // Existing recordings need no sidecar objects or re-upload.
    const thumbnail = url.searchParams.get("thumbnail") === "1";
    const object = request.method === "HEAD" ? await env.VIDEOS.head(key)
      : thumbnail ? await env.VIDEOS.get(key, { range: { offset: 0, length: THUMBNAIL_BYTES } })
      : await env.VIDEOS.get(key);
    if (!object) return new Response("Not found", { status: 404 });
    if (thumbnail) {
      const length = Math.min(object.size, THUMBNAIL_BYTES);
      if (!length) return new Response("No thumbnail data", { status: 422 });
      return new Response(request.method === "HEAD" ? null : object.body, {
        status: 206,
        headers: { "Content-Type": "application/octet-stream", "Content-Length": String(length),
          "Content-Range": `bytes 0-${length - 1}/${object.size}`, "Accept-Ranges": "bytes",
          "ETag": object.httpEtag, "Cache-Control": "no-store" },
      });
    }
    return new Response(request.method === "HEAD" ? null : object.body, {
      headers: { "Content-Type": "application/octet-stream", "Content-Length": String(object.size),
        "ETag": object.httpEtag, "Cache-Control": "no-store" },
    });
  },
};
