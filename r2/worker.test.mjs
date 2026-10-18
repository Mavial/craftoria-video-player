import test from "node:test";
import assert from "node:assert/strict";
import worker from "./worker.mjs";

const origin = "https://video.example";
const object = (key, title) => ({ key, size: 4, httpEtag: '"abcd"', customMetadata: title ? {title} : {}, body: "32VD" });
const request = (path, method = "GET") => new Request(origin + path, {method});

test("catalogue lists videos, excludes other objects, and follows R2 cursors", async () => {
  const seen=[];
  const env={VIDEOS:{list:async options => {
    seen.push(options);
    return options.cursor ? {objects:[object("videos/new movie.32vid")],truncated:false}
      : {objects:[object("videos/movie.32vid","Movie"),object("videos/SHA256SUMS")],truncated:true,cursor:"next +/="};
  }}};
  const response=await worker.fetch(request("/videos.json"),env);
  assert.equal(response.headers.get("cache-control"),"no-store");
  const videos=await response.json();
  assert.deepEqual(videos,[{title:"Movie",url:origin+"/videos/movie.32vid",size:4,release:"R2"}]);
  const next=response.headers.get("link").match(/<([^>]+)>/)[1];
  const second=await worker.fetch(new Request(next),env);
  assert.equal((await second.json())[0].url,origin+"/videos/new%20movie.32vid");
  assert.equal(seen[1].cursor,"next +/=");
  assert.equal(seen[0].prefix,"videos/");
  assert.deepEqual(seen[0].include,["customMetadata","httpMetadata"]);
});

test("friendly title metadata preserves case and punctuation without changing recording URLs", async () => {
  const entries = [
    {...object("videos/crazy-frog-k85mrpqvmbe.32vid"), httpMetadata:{contentDisposition:"inline; filename*=UTF-8''Crazy%20Frog%20-%20Axel%20F.32vid"}},
    {...object("videos/mii-channel-eqtzpo7xskk.32vid"), httpMetadata:{contentDisposition:'inline; filename="Mii Channel - Plaza Theme.32vid"'}},
    {...object("videos/override.32vid","Manual Title"), httpMetadata:{contentDisposition:"inline; filename*=UTF-8''Other.32vid"}},
    {...object("videos/fallback-title.32vid"), httpMetadata:{contentDisposition:"inline; filename*=UTF-8''%GG.32vid"}},
    {...object("videos/control-fallback.32vid"), httpMetadata:{contentDisposition:"inline; filename*=UTF-8''Bad%0ATitle.32vid"}},
  ];
  const response=await worker.fetch(request("/videos.json"),{VIDEOS:{list:async()=>({objects:entries,truncated:false})}});
  const titles=await response.json();
  assert.deepEqual(titles.map(video=>video.title),["Crazy Frog - Axel F","Mii Channel - Plaza Theme","Manual Title","Fallback Title","Control Fallback"]);
  assert.equal(titles[0].url,origin+"/videos/crazy-frog-k85mrpqvmbe.32vid");
});

test("video GET streams exact bytes and HEAD returns only metadata", async () => {
  const seen=[];
  const env={VIDEOS:{get:async key => {seen.push(key);return object(key)},head:async key => {seen.push(key);return object(key)}}};
  const response=await worker.fetch(request("/videos/new%20movie.32vid"),env);
  assert.equal(await response.text(),"32VD");
  assert.equal(response.headers.get("content-length"),"4");
  assert.equal(response.headers.get("etag"),'"abcd"');
  const head=await worker.fetch(request("/videos/new%20movie.32vid","HEAD"),env);
  assert.equal(await head.text(),"");
  assert.deepEqual(seen,["videos/new movie.32vid","videos/new movie.32vid"]);
});

test("only video reads are exposed; writes and other bucket keys are unavailable", async () => {
  const env={VIDEOS:{get:async()=>{throw Error("Unexpected R2 access")}}};
  for (const path of ["/secret.txt","/videos/secret.txt","/secret.32vid","/videos/%2e%2e%2fsecret.32vid","/videos/%00bad.32vid"]) {
    assert.equal((await worker.fetch(request(path),env)).status,404);
  }
  assert.equal((await worker.fetch(request("/videos/%GG.32vid"),env)).status,400);
  for (const method of ["PUT","POST","DELETE"]) {
    assert.equal((await worker.fetch(request("/videos/movie.32vid",method),env)).status,405);
  }
  const missing=await worker.fetch(request("/videos/missing.32vid"),{VIDEOS:{get:async()=>null}});
  assert.equal(missing.status,404);
});
